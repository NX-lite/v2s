import Foundation

actor NativeRealtimeSessionDriver: RealtimeSessionDriving {
    private static let maximumAudioChunkBytes = 32_000
    private static let maximumAudioMailboxBytes = 512_000
    private static let maximumAudioMailboxChunks = 128
    private static let maximumCorrectionTextLength = 8_192

    private enum State {
        case stopped
        case connecting
        case awaitingAcknowledgement
        case ready
        case awaitingCommitAcknowledgement
        case awaitingResponse
        case failed
        case expired
    }

    private enum SetupDecision {
        case acknowledged
        case failed(RealtimeFailureCode)
        case expired
        case ignored
    }

    private struct PendingUtterance {
        let sourceAlias: String
        let generation: Int
        let captionID: UUID
        let utteranceID: String
        let startMonotonicNanoseconds: UInt64
        let endMonotonicNanoseconds: UInt64
        var responseID: String?
        var commitBoundarySendStarted = false
        var commitBoundaryFlushed = false
        var didReceiveCommitAcknowledgement = false
        var didReceiveResponseCreated = false
        var text = ""
        var textWasTruncated = false

        mutating func appendText(_ delta: String, limit: Int) {
            guard !textWasTruncated else { return }
            let remaining = limit - text.count
            if delta.count <= remaining {
                text += delta
            } else {
                text += delta.prefix(remaining)
                textWasTruncated = true
            }
        }
    }

    private let settings: NativeRealtimeSettings
    private let credential: String?
    private let sourceRole: RealtimeAudioSourceRole
    private let connector: any RealtimeWebSocketConnecting
    private let videoEnabled: Bool
    private let setupTimeout: Duration
    private let providerEvents: AsyncStream<RealtimeProviderEvent>
    private let providerEventContinuation: AsyncStream<RealtimeProviderEvent>.Continuation

    private var state: State = .stopped
    private var operationID: UInt64 = 0
    private var sourceAlias: String?
    private var sourceGeneration: Int?
    private var connection: (any RealtimeWebSocketConnection)?
    private var setupContinuation: CheckedContinuation<Void, any Error>?
    private var connectionTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var setupTimeoutTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var audioMailbox: [RealtimeAudioChunk] = []
    private var audioMailboxBytes = 0
    private var pendingUtterance: PendingUtterance?
    private var expiredGeneration: Int?
    private var recentResponseIDs: [String] = []

    init(
        settings: NativeRealtimeSettings,
        credential: String?,
        sourceRole: RealtimeAudioSourceRole,
        connector: any RealtimeWebSocketConnecting = URLSessionRealtimeWebSocketConnector(),
        videoEnabled: Bool = false,
        setupTimeout: Duration = .seconds(5)
    ) {
        self.settings = settings
        self.credential = credential
        self.sourceRole = sourceRole
        self.connector = connector
        self.videoEnabled = videoEnabled
        self.setupTimeout = setupTimeout
        let pair = AsyncStream<RealtimeProviderEvent>.makeStream()
        providerEvents = pair.stream
        providerEventContinuation = pair.continuation
    }

    func start(sourceAlias: String, generation: Int) async throws {
        guard canBeginSetup else { throw RealtimeFailureCode.connectionFailed }

        operationID &+= 1
        let operation = operationID
        self.sourceAlias = Self.validAlias(sourceAlias) ? sourceAlias : nil
        sourceGeneration = generation

        guard Self.validAlias(sourceAlias), generation >= 0,
              settings.isEnabled, setupTimeout > .zero,
              let credential, !credential.isEmpty,
              expiredGeneration.map({ generation > $0 }) ?? true else {
            state = .failed
            emitFailure(.invalidConfiguration, alias: self.sourceAlias, generation: sourceGeneration)
            throw RealtimeFailureCode.invalidConfiguration
        }

        clearMailbox()
        pendingUtterance = nil
        recentResponseIDs.removeAll(keepingCapacity: false)
        state = .connecting

        let request: URLRequest
        do {
            request = try RealtimeEndpointResolver.request(settings: settings, credential: credential)
        } catch {
            state = .failed
            emitFailure(.invalidConfiguration, alias: self.sourceAlias, generation: sourceGeneration)
            throw RealtimeFailureCode.invalidConfiguration
        }

        let setupMessage: RealtimeSocketMessage
        do {
            setupMessage = try Self.setupMessage(
                for: settings.profile,
                sourceAlias: sourceAlias,
                sourceRole: sourceRole
            )
        } catch {
            await fail(.invalidConfiguration, operation: operation)
            throw RealtimeFailureCode.invalidConfiguration
        }

        let timeout = setupTimeout
        let connector = self.connector
        try await withCheckedThrowingContinuation { continuation in
            setupContinuation = continuation
            setupTimeoutTask = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.setupTimedOut(operation: operation)
            }
            connectionTask = Task.detached { [weak self, connector] in
                let newConnection: any RealtimeWebSocketConnection
                do {
                    newConnection = try await connector.connect(request: request)
                } catch {
                    await self?.connectionFailed(operation: operation)
                    return
                }
                guard let self else {
                    await newConnection.close()
                    return
                }
                await self.connectionEstablished(
                    newConnection,
                    setupMessage: setupMessage,
                    operation: operation
                )
            }
        }
    }

    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws {
        switch state {
        case .ready, .awaitingCommitAcknowledgement, .awaitingResponse:
            break
        case .stopped, .connecting, .awaitingAcknowledgement, .failed, .expired:
            throw RealtimeFailureCode.capabilityRejected
        }

        guard let alias = sourceAlias, let generation = sourceGeneration,
              chunk.sourceAlias == alias, chunk.generation == generation else {
            throw RealtimeFailureCode.invalidConfiguration
        }
        guard chunk.sampleRate == 16_000,
              !chunk.pcm16LEData.isEmpty,
              chunk.pcm16LEData.count.isMultiple(of: 2),
              chunk.pcm16LEData.count <= Self.maximumAudioChunkBytes else {
            throw RealtimeFailureCode.capabilityRejected
        }

        let wouldExceedBytes = audioMailboxBytes + chunk.pcm16LEData.count > Self.maximumAudioMailboxBytes
        let wouldExceedChunks = audioMailbox.count >= Self.maximumAudioMailboxChunks
        guard !wouldExceedBytes, !wouldExceedChunks else {
            clearMailbox()
            emitFailure(.backpressure, alias: alias, generation: generation)
            throw RealtimeFailureCode.backpressure
        }

        audioMailbox.append(chunk)
        audioMailboxBytes += chunk.pcm16LEData.count
    }

    func commit(_ utterance: RealtimeUtterance) async throws {
        guard state == .ready else { throw RealtimeFailureCode.capabilityRejected }
        guard let alias = sourceAlias, let generation = sourceGeneration,
              utterance.sourceAlias == alias, utterance.generation == generation,
              !utterance.utteranceID.isEmpty,
              utterance.endMonotonicNanoseconds >= utterance.startMonotonicNanoseconds else {
            throw RealtimeFailureCode.invalidConfiguration
        }

        var committed: [RealtimeAudioChunk] = []
        var remainder: [RealtimeAudioChunk] = []
        var remainderBytes = 0
        for chunk in audioMailbox {
            if chunk.capturedAtMonotonicNanoseconds > utterance.endMonotonicNanoseconds {
                remainder.append(chunk)
                remainderBytes += chunk.pcm16LEData.count
            } else if chunk.capturedAtMonotonicNanoseconds >= utterance.startMonotonicNanoseconds {
                committed.append(chunk)
            }
            // Chunks earlier than the utterance window are stale and dropped.
        }
        guard !committed.isEmpty else { throw RealtimeFailureCode.invalidConfiguration }

        let operation = operationID
        let boundary: RealtimeSocketMessage
        var audioMessages: [RealtimeSocketMessage] = []
        do {
            if settings.profile.provider == .gemini {
                audioMessages.append(try GeminiRealtimeCodec.activityStart())
            }
            for chunk in committed {
                audioMessages.append(try audioMessage(for: chunk, alias: alias, generation: generation))
            }
            boundary = try commitMessage(for: utterance)
        } catch let error as RealtimeCodecError {
            throw mapCommitCodecError(error)
        }

        audioMailbox = remainder
        audioMailboxBytes = remainderBytes
        pendingUtterance = PendingUtterance(
            sourceAlias: alias,
            generation: generation,
            captionID: utterance.captionID,
            utteranceID: utterance.utteranceID,
            startMonotonicNanoseconds: utterance.startMonotonicNanoseconds,
            endMonotonicNanoseconds: utterance.endMonotonicNanoseconds
        )
        state = .awaitingCommitAcknowledgement

        let expectsCommitAcknowledgement = settings.profile.provider != .gemini
        drainTask = Task.detached { [weak self] in
            await self?.drainCommittedAudio(
                audioMessages,
                boundary: boundary,
                expectsCommitAcknowledgement: expectsCommitAcknowledgement,
                operation: operation
            )
        }
    }

    func sendVideoFrame(_ frame: RealtimeVideoFrame) async throws {
        _ = frame
        _ = videoEnabled
        throw RealtimeFailureCode.capabilityRejected
    }

    func events() async -> AsyncStream<RealtimeProviderEvent> {
        providerEvents
    }

    func stop() async {
        let wasStarting = state == .connecting || state == .awaitingAcknowledgement
        let pendingContinuation = setupContinuation
        setupContinuation = nil

        operationID &+= 1
        state = .stopped
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        drainTask?.cancel()
        drainTask = nil
        clearMailbox()
        pendingUtterance = nil
        let oldConnection = connection
        connection = nil

        if wasStarting || pendingContinuation != nil {
            emitFailure(.connectionFailed, alias: sourceAlias, generation: sourceGeneration)
        }
        sourceAlias = nil
        sourceGeneration = nil

        if let oldConnection { await oldConnection.close() }
        pendingContinuation?.resume(throwing: RealtimeFailureCode.connectionFailed)
    }

    private var canBeginSetup: Bool {
        switch state {
        case .stopped, .failed, .expired: true
        case .connecting, .awaitingAcknowledgement, .ready,
             .awaitingCommitAcknowledgement, .awaitingResponse: false
        }
    }

    private func receiveMessages(
        operation: UInt64,
        connection: any RealtimeWebSocketConnection
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await connection.receive()
                await receive(message, operation: operation)
            } catch {
                await receiveEnded(operation: operation)
                return
            }
        }
    }

    private func connectionEstablished(
        _ newConnection: any RealtimeWebSocketConnection,
        setupMessage: RealtimeSocketMessage,
        operation: UInt64
    ) async {
        guard isCurrent(operation, in: .connecting) else {
            await newConnection.close()
            return
        }
        connection = newConnection

        do {
            try await newConnection.send(setupMessage)
        } catch {
            await fail(.connectionFailed, operation: operation)
            return
        }

        guard isCurrent(operation, in: .connecting) else {
            await newConnection.close()
            return
        }
        connectionTask = nil
        state = .awaitingAcknowledgement
        receiveTask = Task.detached { [weak self] in
            await self?.receiveMessages(operation: operation, connection: newConnection)
        }
    }

    private func connectionFailed(operation: UInt64) async {
        await fail(.connectionFailed, operation: operation)
    }

    private func receive(_ message: RealtimeSocketMessage, operation: UInt64) async {
        guard operationID == operation else { return }
        if state == .awaitingCommitAcknowledgement {
            await receiveDuringCommit(message, operation: operation)
            return
        }
        if state == .awaitingResponse {
            await receiveDuringResponse(message, operation: operation)
            return
        }
        do {
            switch try setupDecision(for: message) {
            case .acknowledged:
                guard state == .awaitingAcknowledgement else { return }
                state = .ready
                setupTimeoutTask?.cancel()
                setupTimeoutTask = nil
                let continuation = setupContinuation
                setupContinuation = nil
                continuation?.resume()
            case .failed(let code):
                await fail(code, operation: operation)
            case .expired:
                await expire(operation: operation)
            case .ignored:
                break
            }
        } catch {
            await fail(.malformedResponse, operation: operation)
        }
    }

    private func setupDecision(for message: RealtimeSocketMessage) throws -> SetupDecision {
        switch settings.profile.provider {
        case .openAI, .xAI:
            let event = try OpenAIXAIRealtimeCodec.parse(message)
            switch event {
            case .sessionUpdated: return .acknowledged
            case .failure(let code): return .failed(code)
            default: return .ignored
            }
        case .qwen:
            let events = try QwenRealtimeCodec.parse(message)
            if events.contains(where: {
                if case .sessionUpdated = $0 { return true }
                return false
            }) {
                return .acknowledged
            }
            if events.contains(where: {
                if case .providerError = $0 { return true }
                return false
            }) {
                return .failed(.connectionFailed)
            }
            return .ignored
        case .gemini:
            let events = try GeminiRealtimeCodec.parse(message)
            if events.contains(where: {
                if case .sessionExpiring = $0 { return true }
                return false
            }) {
                return .expired
            }
            if events.contains(where: {
                if case .setupComplete = $0 { return true }
                return false
            }) {
                return .acknowledged
            }
            if events.contains(where: {
                if case .providerError = $0 { return true }
                return false
            }) {
                return .failed(.connectionFailed)
            }
            return .ignored
        }
    }

    private func setupTimedOut(operation: UInt64) async {
        guard operationID == operation else { return }
        switch state {
        case .connecting, .awaitingAcknowledgement:
            break
        case .stopped, .ready, .awaitingCommitAcknowledgement, .awaitingResponse,
             .failed, .expired:
            return
        }
        await fail(.connectionFailed, operation: operation)
    }

    private func receiveEnded(operation: UInt64) async {
        guard operationID == operation else { return }
        switch state {
        case .connecting, .awaitingAcknowledgement, .ready,
             .awaitingCommitAcknowledgement, .awaitingResponse:
            await fail(.connectionFailed, operation: operation)
        case .stopped, .failed, .expired:
            break
        }
    }

    private func fail(_ code: RealtimeFailureCode, operation: UInt64) async {
        guard operationID == operation else { return }
        switch state {
        case .connecting, .awaitingAcknowledgement, .ready,
             .awaitingCommitAcknowledgement, .awaitingResponse:
            break
        case .stopped, .failed, .expired:
            return
        }

        state = .failed
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        drainTask?.cancel()
        drainTask = nil
        clearMailbox()
        pendingUtterance = nil
        let oldConnection = connection
        connection = nil
        let continuation = setupContinuation
        setupContinuation = nil
        emitFailure(code, alias: sourceAlias, generation: sourceGeneration)

        if let oldConnection { await oldConnection.close() }
        continuation?.resume(throwing: code)
    }

    private func emitFailure(
        _ code: RealtimeFailureCode,
        alias: String?,
        generation: Int?
    ) {
        guard let alias, Self.validAlias(alias), let generation else { return }
        providerEventContinuation.yield(.failure(
            sourceAlias: alias,
            generation: generation,
            code
        ))
    }

    private func clearMailbox() {
        audioMailbox.removeAll(keepingCapacity: false)
        audioMailboxBytes = 0
    }

    private func drainCommittedAudio(
        _ audioMessages: [RealtimeSocketMessage],
        boundary: RealtimeSocketMessage,
        expectsCommitAcknowledgement: Bool,
        operation: UInt64
    ) async {
        for message in audioMessages {
            guard operationID == operation,
                  state == .awaitingCommitAcknowledgement,
                  let connection else { return }
            do {
                try await connection.send(message)
            } catch {
                await fail(.connectionFailed, operation: operation)
                return
            }
        }
        guard operationID == operation,
              state == .awaitingCommitAcknowledgement,
              let connection,
              var pending = pendingUtterance else { return }
        pending.commitBoundarySendStarted = true
        pendingUtterance = pending
        do {
            try await connection.send(boundary)
        } catch {
            await fail(.connectionFailed, operation: operation)
            return
        }
        guard operationID == operation,
              state == .awaitingCommitAcknowledgement else { return }
        guard var pending = pendingUtterance else { return }
        pending.commitBoundaryFlushed = true
        pendingUtterance = pending
        drainTask = nil
        if !expectsCommitAcknowledgement {
            // Gemini has no commit acknowledgement; activityEnd starts its response turn.
            state = .awaitingResponse
        } else if pending.didReceiveCommitAcknowledgement {
            await sendResponseForCommitAcknowledgement(operation: operation)
        }
    }

    private func receiveDuringCommit(
        _ message: RealtimeSocketMessage,
        operation: UInt64
    ) async {
        do {
            let committed: Bool
            switch settings.profile.provider {
            case .openAI, .xAI:
                switch try OpenAIXAIRealtimeCodec.parse(message) {
                case .audioCommitted:
                    committed = true
                case .failure(let code):
                    await fail(code, operation: operation)
                    return
                default:
                    committed = false
                }
            case .qwen:
                let events = try QwenRealtimeCodec.parse(message)
                if events.contains(where: { $0 == .providerError }) {
                    await fail(.connectionFailed, operation: operation)
                    return
                }
                committed = events.contains(where: { $0 == .audioCommitted })
            case .gemini:
                let events = try GeminiRealtimeCodec.parse(message)
                if events.contains(where: {
                    if case .sessionExpiring = $0 { return true }
                    return false
                }) {
                    await expire(operation: operation)
                    return
                }
                if events.contains(where: { $0 == .providerError }) {
                    await fail(.connectionFailed, operation: operation)
                    return
                }
                committed = false
            }
            if committed, state == .awaitingCommitAcknowledgement,
               var pending = pendingUtterance,
               pending.commitBoundarySendStarted,
               !pending.didReceiveCommitAcknowledgement {
                pending.didReceiveCommitAcknowledgement = true
                pendingUtterance = pending
                if pending.commitBoundaryFlushed {
                    await sendResponseForCommitAcknowledgement(operation: operation)
                }
            }
        } catch {
            await fail(.malformedResponse, operation: operation)
        }
    }

    private func sendResponseForCommitAcknowledgement(operation: UInt64) async {
        guard operationID == operation,
              state == .awaitingCommitAcknowledgement,
              let pending = pendingUtterance,
              pending.commitBoundaryFlushed,
              pending.didReceiveCommitAcknowledgement else { return }
        do {
            let responseRequest: RealtimeSocketMessage
            switch settings.profile.provider {
            case .openAI, .xAI:
                responseRequest = try OpenAIXAIRealtimeCodec.responseCreate(profile: settings.profile)
            case .qwen:
                responseRequest = try QwenRealtimeCodec.responseCreate()
            case .gemini:
                return
            }
            guard let connection else {
                await fail(.connectionFailed, operation: operation)
                return
            }
            state = .awaitingResponse
            try await connection.send(responseRequest)
        } catch {
            await fail(.connectionFailed, operation: operation)
        }
    }

    private func receiveDuringResponse(
        _ message: RealtimeSocketMessage,
        operation: UInt64
    ) async {
        guard var pending = pendingUtterance,
              pending.sourceAlias == sourceAlias,
              pending.generation == sourceGeneration else {
            return
        }
        do {
            switch settings.profile.provider {
            case .openAI, .xAI:
                switch try OpenAIXAIRealtimeCodec.parse(message) {
                case .responseCreated(let responseID):
                    if pending.didReceiveResponseCreated { return }
                    if let responseID, recentResponseIDs.contains(responseID) { return }
                    pending.didReceiveResponseCreated = true
                    pending.responseID = responseID
                    pendingUtterance = pending
                case .textDelta(let responseID, let text):
                    guard pending.didReceiveResponseCreated,
                          responseMatches(responseID, pending: pending) else { return }
                    pending.appendText(text, limit: Self.maximumCorrectionTextLength)
                    pendingUtterance = pending
                case .textDone(let responseID, let text):
                    guard pending.didReceiveResponseCreated,
                          responseMatches(responseID, pending: pending) else { return }
                    if let text {
                        pending.text = String(text.prefix(Self.maximumCorrectionTextLength))
                        pending.textWasTruncated = text.count > Self.maximumCorrectionTextLength
                    }
                    pendingUtterance = pending
                case .responseDone(let responseID):
                    guard pending.didReceiveResponseCreated,
                          responseMatches(responseID, pending: pending) else { return }
                    finishCorrection(pending, operation: operation)
                case .audioOutputDetected:
                    await fail(.capabilityRejected, operation: operation)
                case .failure(let code):
                    await fail(code, operation: operation)
                case .sessionCreated, .sessionUpdated, .audioCommitted, .ignored:
                    break
                }
            case .qwen:
                let events = try QwenRealtimeCodec.parse(message)
                for event in events {
                    switch event {
                    case .responseCreated(let responseID):
                        if pending.didReceiveResponseCreated { return }
                        if let responseID, recentResponseIDs.contains(responseID) { return }
                        pending.didReceiveResponseCreated = true
                        pending.responseID = responseID
                        pendingUtterance = pending
                    case .textDelta(let responseID, let text):
                        guard pending.didReceiveResponseCreated,
                              responseMatches(responseID, pending: pending) else { return }
                        pending.appendText(text, limit: Self.maximumCorrectionTextLength)
                        pendingUtterance = pending
                    case .textComplete(let responseID, let text):
                        guard pending.didReceiveResponseCreated,
                              responseMatches(responseID, pending: pending) else { return }
                        pending.text = String(text.prefix(Self.maximumCorrectionTextLength))
                        pending.textWasTruncated = text.count > Self.maximumCorrectionTextLength
                        pendingUtterance = pending
                    case .responseComplete(let responseID):
                        guard pending.didReceiveResponseCreated,
                              responseMatches(responseID, pending: pending) else { return }
                        finishCorrection(pending, operation: operation)
                    case .audioOutputDetected:
                        await fail(.capabilityRejected, operation: operation)
                        return
                    case .providerError:
                        await fail(.capabilityRejected, operation: operation)
                        return
                    case .sessionCreated, .sessionUpdated, .audioCommitted:
                        break
                    }
                }
            case .gemini:
                let events = try GeminiRealtimeCodec.parse(message)
                if events.contains(where: {
                    if case .sessionExpiring = $0 { return true }
                    return false
                }) {
                    await expire(operation: operation)
                    return
                }
                if events.contains(where: { $0 == .providerError }) {
                    await fail(.connectionFailed, operation: operation)
                    return
                }
                if events.contains(where: { $0 == .interrupted }) {
                    pendingUtterance = nil
                    state = .ready
                    return
                }
                for event in events {
                    if case .outputTranscription(let text) = event {
                        pending.appendText(text, limit: Self.maximumCorrectionTextLength)
                    }
                }
                pendingUtterance = pending
                if events.contains(where: { $0 == .turnComplete }) {
                    finishCorrection(pending, operation: operation)
                }
            }
        } catch {
            await fail(.malformedResponse, operation: operation)
        }
    }

    private func responseMatches(_ responseID: String?, pending: PendingUtterance) -> Bool {
        guard let expected = pending.responseID else { return responseID == nil }
        return responseID == expected
    }

    private func finishCorrection(_ pending: PendingUtterance, operation: UInt64) {
        guard operationID == operation, state == .awaitingResponse,
              pendingUtterance?.captionID == pending.captionID else {
            return
        }
        if let responseID = pending.responseID {
            recentResponseIDs.append(responseID)
            if recentResponseIDs.count > 16 {
                recentResponseIDs.removeFirst(recentResponseIDs.count - 16)
            }
        }
        guard !pending.textWasTruncated else {
            pendingUtterance = nil
            state = .ready
            return
        }
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.isConversationalAnswer(text) else {
            pendingUtterance = nil
            state = .ready
            return
        }
        providerEventContinuation.yield(.correctedText(
            sourceAlias: pending.sourceAlias,
            generation: pending.generation,
            captionID: pending.captionID,
            utteranceID: pending.utteranceID,
            text: text
        ))
        pendingUtterance = nil
        state = .ready
    }

    private func expire(operation: UInt64) async {
        guard operationID == operation else { return }
        state = .expired
        if let sourceGeneration {
            expiredGeneration = max(expiredGeneration ?? sourceGeneration, sourceGeneration)
        }
        pendingUtterance = nil
        clearMailbox()
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        drainTask?.cancel()
        drainTask = nil
        let oldConnection = connection
        connection = nil
        let continuation = setupContinuation
        setupContinuation = nil
        if let sourceAlias, let sourceGeneration {
            providerEventContinuation.yield(.expired(sourceAlias: sourceAlias, generation: sourceGeneration))
        }
        if let oldConnection { await oldConnection.close() }
        continuation?.resume(throwing: RealtimeFailureCode.sessionExpired)
    }

    private static func isConversationalAnswer(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let prefixes = [
            "sure,", "sure.", "here is", "here's", "the corrected transcript is",
            "the transcript is", "i corrected", "i have corrected", "as an ai",
            "can i help", "can i assist", "i can help", "i can assist",
            "i'd be happy to", "i would be happy to", "how can i help",
            "how can i assist", "let me know if you need", "let me know if i can",
        ]
        let embeddedConversationalPhrases = [
            "how can i help", "how can i assist", "can i help", "can i assist",
            "i can help", "i can assist", "i'd be happy to", "i would be happy to",
            "let me know if you need", "let me know if i can",
        ]
        let transcriptMetacommentaryPhrases = [
            "corrected transcript", "corrected transcription",
            "transcript is", "transcription is", "transcript would be", "transcription would be",
            "provide a transcript", "provide the transcript", "provide a transcription",
            "offer a transcript", "offer the transcript", "offer a transcription",
        ]
        let transcriptMention = normalized.contains("transcript") || normalized.contains("transcription")
        let assistantPreamble = ["certainly", "absolutely", "of course"]
            .contains(where: normalized.hasPrefix)
        return prefixes.contains(where: normalized.hasPrefix) ||
            embeddedConversationalPhrases.contains(where: normalized.contains) ||
            transcriptMetacommentaryPhrases.contains(where: normalized.contains) ||
            (assistantPreamble && transcriptMention) ||
            normalized.contains("\n")
    }

    private func audioMessage(
        for chunk: RealtimeAudioChunk,
        alias: String,
        generation: Int
    ) throws -> RealtimeSocketMessage {
        switch settings.profile.provider {
        case .openAI, .xAI:
            try OpenAIXAIRealtimeCodec.audioAppend(chunk, sourceAlias: alias, generation: generation)
        case .qwen:
            try QwenRealtimeCodec.audio(chunk, sourceAlias: alias, generation: generation)
        case .gemini:
            try GeminiRealtimeCodec.audio(chunk, sourceAlias: alias, generation: generation)
        }
    }

    private func commitMessage(for utterance: RealtimeUtterance) throws -> RealtimeSocketMessage {
        switch settings.profile.provider {
        case .openAI, .xAI:
            try OpenAIXAIRealtimeCodec.commit()
        case .qwen:
            try QwenRealtimeCodec.commit(utterance)
        case .gemini:
            try GeminiRealtimeCodec.commit(utterance)
        }
    }

    private func mapCommitCodecError(_ error: RealtimeCodecError) -> RealtimeFailureCode {
        switch error {
        case .invalidAudio, .oversizedMessage:
            .capabilityRejected
        case .unsupportedProfile, .invalidAlias, .malformedMessage, .unsupportedMessage:
            .invalidConfiguration
        }
    }

    private func isCurrent(_ operation: UInt64, in expectedState: State) -> Bool {
        operationID == operation && state == expectedState
    }

    private static func setupMessage(
        for profile: NativeRealtimeProfile,
        sourceAlias: String,
        sourceRole: RealtimeAudioSourceRole
    ) throws -> RealtimeSocketMessage {
        switch profile.provider {
        case .openAI, .xAI:
            try OpenAIXAIRealtimeCodec.sessionUpdate(
                profile: profile,
                sourceAlias: sourceAlias,
                sourceRole: sourceRole
            )
        case .qwen:
            try QwenRealtimeCodec.setup(sourceAlias: sourceAlias, sourceRole: sourceRole)
        case .gemini:
            try GeminiRealtimeCodec.setup(sourceAlias: sourceAlias, sourceRole: sourceRole)
        }
    }

    private static func validAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("audio-"),
              let number = Int(alias.dropFirst("audio-".count)),
              (1...999).contains(number) else {
            return false
        }
        return alias == "audio-\(number)"
    }
}
