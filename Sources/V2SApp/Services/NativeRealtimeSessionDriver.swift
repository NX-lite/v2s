import Foundation

actor NativeRealtimeSessionDriver: RealtimeSessionDriving {
    private static let maximumAudioChunkBytes = 32_000
    private static let maximumAudioMailboxBytes = 512_000
    private static let maximumAudioMailboxChunks = 128

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
        case ignored
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
              let credential, !credential.isEmpty else {
            state = .failed
            emitFailure(.invalidConfiguration, alias: self.sourceAlias, generation: sourceGeneration)
            throw RealtimeFailureCode.invalidConfiguration
        }

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
            for chunk in committed {
                audioMessages.append(try audioMessage(for: chunk, alias: alias, generation: generation))
            }
            boundary = try commitMessage(for: utterance)
        } catch let error as RealtimeCodecError {
            throw mapCommitCodecError(error)
        }

        audioMailbox = remainder
        audioMailboxBytes = remainderBytes
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
        for message in audioMessages + [boundary] {
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
              state == .awaitingCommitAcknowledgement else { return }
        drainTask = nil
        if !expectsCommitAcknowledgement {
            // Gemini has no commit acknowledgement; activityEnd completes the turn boundary.
            state = .ready
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
                if events.contains(where: { $0 == .providerError }) {
                    await fail(.connectionFailed, operation: operation)
                    return
                }
                committed = false
            }
            if committed, state == .awaitingCommitAcknowledgement {
                state = .ready
            }
        } catch {
            await fail(.malformedResponse, operation: operation)
        }
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
