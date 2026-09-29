import Foundation
import Testing
@testable import v2s

@Suite(.serialized)
struct NativeRealtimeSessionDriverTests {
    @Test func everyProfileWaitsForItsProtocolSpecificSetupAcknowledgement() async throws {
        let profiles: [NativeRealtimeProfile] = [
            .openAIMini,
            .openAI,
            .qwenOmniFlash,
            .geminiLive,
            .xAIVoice,
            .xAIVoiceThinkFast,
        ]

        for profile in profiles {
            let connection = FakeRealtimeWebSocketConnection()
            let connector = FakeRealtimeWebSocketConnector(profile: profile, connections: [connection])
            let driver = NativeRealtimeSessionDriver(
                settings: settings(profile: profile),
                credential: "synthetic-key",
                sourceRole: .applicationAudio,
                connector: connector,
                videoEnabled: false,
                setupTimeout: .seconds(1)
            )
            let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)

            #expect(await connection.waitUntilSentMessageCount(1))
            #expect(!(await recorder.hasFinished()))
            #expect(await connection.sentMessageTypes() == [profile == .geminiLive ? "setup" : "session.update"])

            await connection.enqueue(wrongAcknowledgement(for: profile))
            try await Task.sleep(for: .milliseconds(5))
            #expect(!(await recorder.hasFinished()))

            await connection.enqueue(acknowledgement(for: profile))
            #expect(await recorder.waitForOutcome() == .succeeded)
            await task.value
            #expect(await connection.closeCount() == 0)
            #expect(await connector.sanitizedRequests() == [
                SanitizedConnectRequest(host: expectedHost(for: profile), profile: profile),
            ])
            await driver.stop()
            #expect(await connection.closeCount() == 1)
        }
    }

    @Test func setupErrorIsMappedToAnAllowlistedCodeAndClosesSocket() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        var eventIterator = await driver.events().makeAsyncIterator()
        let (recorder, task) = launchStart(driver, alias: "audio-2", generation: 3)

        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(
            #"{"type":"error","error":{"code":"rate_limit_exceeded","message":"synthetic-key https://private.invalid/?key=hidden server-body"}}"#
        ))

        #expect(await recorder.waitForOutcome() == .failed(.rateLimited))
        await task.value
        #expect(await connection.closeCount() == 1)
        #expect(await connection.sentMessageTypes() == ["session.update"])
        #expect(!String(describing: await recorder.outcome()).contains("synthetic-key"))
        #expect(!String(describing: await recorder.outcome()).contains("server-body"))
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-2", generation: 3, .rateLimited))
        #expect(!String(describing: event).contains("synthetic-key"))
        #expect(!String(describing: event).contains("server-body"))
    }

    @Test func malformedServerPayloadIsReplacedWithAnAllowlistedParserFailure() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        var eventIterator = await driver.events().makeAsyncIterator()
        let (recorder, task) = launchStart(driver, alias: "audio-3", generation: 2)

        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text("synthetic-key malformed server-body"))

        #expect(await recorder.waitForOutcome() == .failed(.malformedResponse))
        await task.value
        #expect(await connection.closeCount() == 1)
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-3", generation: 2, .malformedResponse))
        #expect(!String(describing: event).contains("synthetic-key"))
        #expect(!String(describing: event).contains("server-body"))
    }

    @Test func invalidAliasCredentialWorkspaceAndRegionFailBeforeConnecting() async {
        var invalidInputs: [(NativeRealtimeSettings, String?, String)] = []
        invalidInputs.append((settings(profile: .openAIMini), "synthetic-key", "stable-device-id"))
        invalidInputs.append((settings(profile: .openAIMini), nil, "audio-1"))

        var invalidWorkspace = settings(profile: .qwenOmniFlash)
        invalidWorkspace.region = .china
        invalidWorkspace.qwenWorkspaceID = "workspace/path"
        invalidInputs.append((invalidWorkspace, "synthetic-key", "audio-1"))

        var invalidRegion = settings(profile: .qwenOmniFlash)
        invalidRegion.region = .unitedStates
        invalidRegion.qwenWorkspaceID = "workspace-123"
        invalidInputs.append((invalidRegion, "synthetic-key", "audio-1"))

        for (configuration, credential, alias) in invalidInputs {
            let connection = FakeRealtimeWebSocketConnection()
            let connector = FakeRealtimeWebSocketConnector(
                profile: configuration.profile,
                connections: [connection]
            )
            let driver = NativeRealtimeSessionDriver(
                settings: configuration,
                credential: credential,
                sourceRole: .microphone,
                connector: connector,
                setupTimeout: .seconds(1)
            )

            do {
                try await driver.start(sourceAlias: alias, generation: 1)
                Issue.record("Invalid setup unexpectedly succeeded")
            } catch let code as RealtimeFailureCode {
                #expect(code == .invalidConfiguration)
                #expect(!String(describing: code).contains("synthetic-key"))
            } catch {
                Issue.record("Setup returned a non-allowlisted error")
            }
            #expect(await connector.sanitizedRequests().isEmpty)
            #expect(await connection.closeCount() == 0)
            #expect(await connection.sentMessageTypes().isEmpty)
        }
    }

    @Test func connectorFailureDoesNotExposeConnectorDetails() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .openAIMini,
            connections: [connection],
            failConnect: true
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )

        do {
            try await driver.start(sourceAlias: "audio-1", generation: 2)
            Issue.record("Connector failure unexpectedly succeeded")
        } catch let code as RealtimeFailureCode {
            #expect(code == .connectionFailed)
            #expect(!String(describing: code).contains("synthetic-key"))
            #expect(!String(describing: code).contains("private-provider-error"))
        } catch {
            Issue.record("Setup returned a non-allowlisted error")
        }
        #expect((await connector.sanitizedRequests()).count == 1)
        #expect(await connection.sentMessageTypes().isEmpty)
        #expect(await connection.closeCount() == 0)
    }

    @Test func handshakeTimeoutClosesSocketAndLateAcknowledgementCannotSucceed() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .milliseconds(20)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 4)

        #expect(await connection.waitUntilSentMessageCount(1))
        #expect(await recorder.waitForOutcome() == .failed(.connectionFailed))
        await task.value
        #expect(await connection.closeCount() == 1)

        await connection.enqueue(acknowledgement(for: .openAIMini))
        try? await Task.sleep(for: .milliseconds(5))
        #expect(await recorder.outcome() == .failed(.connectionFailed))
        #expect(await connection.sentMessageTypes() == ["session.update"])
    }

    @Test func setupTimeoutCoversSuspendedConnectorAndClosesLateSocket() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .openAIMini,
            connections: [connection],
            suspendConnect: true
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .milliseconds(20)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 9)

        #expect(await connector.waitUntilConnectStarted())
        #expect(await recorder.waitForOutcome() == .failed(.connectionFailed))
        await task.value
        #expect(await connection.closeCount() == 0)

        await connector.releaseConnect()
        #expect(await connection.waitUntilClosed())
        #expect(await connection.sentMessageTypes().isEmpty)
    }

    @Test func setupTimeoutCoversSuspendedSetupSend() async {
        let connection = FakeRealtimeWebSocketConnection(suspendSend: true)
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .milliseconds(20)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 10)

        #expect(await connection.waitUntilSendStarted())
        #expect(await recorder.waitForOutcome() == .failed(.connectionFailed))
        await task.value
        #expect(await connection.closeCount() == 1)
        #expect(await connection.sentMessageTypes().isEmpty)
    }

    @Test func staleAcknowledgementFromPreviousGenerationCannotFinishRestart() async {
        let oldConnection = FakeRealtimeWebSocketConnection()
        let newConnection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .openAIMini,
            connections: [oldConnection, newConnection]
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (oldRecorder, oldTask) = launchStart(driver, alias: "audio-1", generation: 4)

        #expect(await oldConnection.waitUntilSentMessageCount(1))
        await driver.stop()
        #expect(await oldRecorder.waitForOutcome() == .failed(.connectionFailed))
        await oldTask.value

        let (newRecorder, newTask) = launchStart(driver, alias: "audio-1", generation: 5)
        #expect(await newConnection.waitUntilSentMessageCount(1))
        await oldConnection.enqueue(acknowledgement(for: .openAIMini))
        try? await Task.sleep(for: .milliseconds(5))
        #expect(!(await newRecorder.hasFinished()))

        await newConnection.enqueue(acknowledgement(for: .openAIMini))
        #expect(await newRecorder.waitForOutcome() == .succeeded)
        await newTask.value
        await driver.stop()
    }

    @Test func concurrentStartIsRejectedWithoutChangingActiveSourceOrGeneration() async {
        let firstConnection = FakeRealtimeWebSocketConnection()
        let secondConnection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .openAIMini,
            connections: [firstConnection, secondConnection]
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        var eventIterator = await driver.events().makeAsyncIterator()
        let (firstRecorder, firstTask) = launchStart(driver, alias: "audio-1", generation: 11)

        #expect(await firstConnection.waitUntilSentMessageCount(1))
        let (secondRecorder, secondTask) = launchStart(driver, alias: "audio-2", generation: 12)
        let secondOutcome = await secondRecorder.waitForOutcome()
        #expect(secondOutcome == .failed(.connectionFailed))

        if secondOutcome != .failed(.connectionFailed) {
            await driver.stop()
            await firstTask.value
            await secondTask.value
            return
        }

        #expect(!(await firstRecorder.hasFinished()))
        #expect(await connector.sanitizedRequests() == [
            SanitizedConnectRequest(host: "api.openai.com", profile: .openAIMini),
        ])
        #expect(await secondConnection.sentMessageTypes().isEmpty)
        #expect(await secondConnection.closeCount() == 0)

        await firstConnection.enqueue(acknowledgement(for: .openAIMini))
        #expect(await firstRecorder.waitForOutcome() == .succeeded)
        await firstTask.value

        await firstConnection.enqueue(.text(
            #"{"type":"error","error":{"code":"rate_limit_exceeded","message":"synthetic-key private-provider-body"}}"#
        ))
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-1", generation: 11, .rateLimited))
        #expect(!String(describing: event).contains("synthetic-key"))
        #expect(!String(describing: event).contains("private-provider-body"))
        await driver.stop()
    }

    @Test func stopDuringSuspendedReceiveFailsStartAndRejectsLateAcknowledgement() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        var eventIterator = await driver.events().makeAsyncIterator()
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 6)

        #expect(await connection.waitUntilSentMessageCount(1))
        await driver.stop()
        await connection.enqueue(acknowledgement(for: .openAIMini))

        #expect(await recorder.waitForOutcome() == .failed(.connectionFailed))
        await task.value
        #expect(await connection.closeCount() == 1)
        #expect(await connection.sentMessageTypes() == ["session.update"])
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-1", generation: 6, .connectionFailed))
        #expect(!String(describing: event).contains("synthetic-key"))
    }

    @Test func stopDuringSuspendedConnectorClosesSocketWhenConnectReturns() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .openAIMini,
            connections: [connection],
            suspendConnect: true
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)

        #expect(await connector.waitUntilConnectStarted())
        await driver.stop()
        await connector.releaseConnect()

        #expect(await recorder.waitForOutcome() == .failed(.connectionFailed))
        await task.value
        #expect(await connection.closeCount() == 1)
        #expect(await connection.sentMessageTypes().isEmpty)
    }

    @Test func noMediaIsSentBeforeAcknowledgementOrInTaskTwo() async {
        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 8)

        #expect(await connection.waitUntilSentMessageCount(1))
        do {
            try await driver.sendAudioChunk(RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: 8,
                capturedAtMonotonicNanoseconds: 12,
                pcm16LEData: Data([0, 0]),
                sampleRate: 16_000
            ))
            Issue.record("Audio send unexpectedly succeeded")
        } catch let code as RealtimeFailureCode {
            #expect(code == .capabilityRejected)
        } catch {
            Issue.record("Audio send returned a non-allowlisted error")
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        #expect(!(await recorder.hasFinished()))

        await connection.enqueue(acknowledgement(for: .openAIMini))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        await driver.stop()
        #expect(await connection.sentMessageTypes() == ["session.update"])
    }
}

private enum StartOutcome: Equatable {
    case succeeded
    case failed(RealtimeFailureCode)
}

private actor StartOutcomeRecorder {
    private var storedOutcome: StartOutcome?

    func complete(_ outcome: StartOutcome) {
        guard storedOutcome == nil else { return }
        storedOutcome = outcome
    }

    func hasFinished() -> Bool { storedOutcome != nil }
    func outcome() -> StartOutcome? { storedOutcome }

    func waitForOutcome() async -> StartOutcome? {
        for _ in 0..<200 {
            if let storedOutcome { return storedOutcome }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return storedOutcome
    }
}

private func launchStart(
    _ driver: NativeRealtimeSessionDriver,
    alias: String,
    generation: Int
) -> (StartOutcomeRecorder, Task<Void, Never>) {
    let recorder = StartOutcomeRecorder()
    let task = Task {
        do {
            try await driver.start(sourceAlias: alias, generation: generation)
            await recorder.complete(.succeeded)
        } catch let code as RealtimeFailureCode {
            await recorder.complete(.failed(code))
        } catch {
            await recorder.complete(.failed(.connectionFailed))
        }
    }
    return (recorder, task)
}

private func settings(profile: NativeRealtimeProfile) -> NativeRealtimeSettings {
    var value = NativeRealtimeSettings.default
    value.isEnabled = true
    value.profile = profile
    if profile == .qwenOmniFlash {
        value.region = .singapore
        value.qwenWorkspaceID = "workspace-123"
    }
    return value
}

private func acknowledgement(for profile: NativeRealtimeProfile) -> RealtimeSocketMessage {
    profile == .geminiLive
        ? .text(#"{"setupComplete":{}}"#)
        : .text(#"{"type":"session.updated"}"#)
}

private func wrongAcknowledgement(for profile: NativeRealtimeProfile) -> RealtimeSocketMessage {
    profile == .geminiLive
        ? .text(#"{"serverContent":{"turnComplete":true}}"#)
        : .text(#"{"type":"session.created"}"#)
}

private func expectedHost(for profile: NativeRealtimeProfile) -> String {
    switch profile.provider {
    case .openAI: "api.openai.com"
    case .qwen: "workspace-123.ap-southeast-1.maas.aliyuncs.com"
    case .gemini: "generativelanguage.googleapis.com"
    case .xAI: "api.x.ai"
    }
}

private struct SanitizedConnectRequest: Equatable, Sendable {
    let host: String
    let profile: NativeRealtimeProfile
}

private actor FakeRealtimeWebSocketConnector: RealtimeWebSocketConnecting {
    private let profile: NativeRealtimeProfile
    private let connections: [FakeRealtimeWebSocketConnection]
    private let suspendConnect: Bool
    private let failConnect: Bool
    private var requestIndex = 0
    private var requests: [SanitizedConnectRequest] = []
    private var pendingConnect: CheckedContinuation<any RealtimeWebSocketConnection, Error>?

    init(
        profile: NativeRealtimeProfile,
        connections: [FakeRealtimeWebSocketConnection],
        suspendConnect: Bool = false,
        failConnect: Bool = false
    ) {
        self.profile = profile
        self.connections = connections
        self.suspendConnect = suspendConnect
        self.failConnect = failConnect
    }

    func connect(request: URLRequest) async throws -> any RealtimeWebSocketConnection {
        guard let host = request.url?.host else { throw FakeConnectorError() }
        requests.append(SanitizedConnectRequest(host: host, profile: profile))

        guard requestIndex < connections.count else { throw FakeConnectorError() }
        let connection = connections[requestIndex]
        requestIndex += 1
        if failConnect { throw FakeConnectorError() }
        if suspendConnect {
            return try await withCheckedThrowingContinuation { pendingConnect = $0 }
        }
        return connection
    }

    func sanitizedRequests() -> [SanitizedConnectRequest] { requests }

    func waitUntilConnectStarted() async -> Bool {
        for _ in 0..<200 {
            if !requests.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !requests.isEmpty
    }

    func releaseConnect() {
        guard let pendingConnect else { return }
        self.pendingConnect = nil
        pendingConnect.resume(returning: connections[0])
    }
}

private struct FakeConnectorError: Error, CustomStringConvertible {
    var description: String { "synthetic-key private-provider-error https://private.invalid" }
}

private actor FakeRealtimeWebSocketConnection: RealtimeWebSocketConnection {
    private let suspendSend: Bool
    private var messages: [RealtimeSocketMessage] = []
    private var sentTypes: [String] = []
    private var receiveWaiter: CheckedContinuation<RealtimeSocketMessage, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var sendStarted = false
    private var closed = false
    private var closes = 0

    init(suspendSend: Bool = false) {
        self.suspendSend = suspendSend
    }

    func send(_ message: RealtimeSocketMessage) async throws {
        guard !closed else { throw RealtimeTransportError.closed }
        sendStarted = true
        if suspendSend {
            try await withCheckedThrowingContinuation { sendWaiter = $0 }
        }
        guard !closed else { throw RealtimeTransportError.closed }
        sentTypes.append(Self.messageType(message))
    }

    func receive() async throws -> RealtimeSocketMessage {
        if !messages.isEmpty { return messages.removeFirst() }
        guard !closed else { throw RealtimeTransportError.closed }
        return try await withCheckedThrowingContinuation { receiveWaiter = $0 }
    }

    func enqueue(_ message: RealtimeSocketMessage) {
        guard !closed else { return }
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: message)
        } else {
            messages.append(message)
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        closes += 1
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(throwing: RealtimeTransportError.closed)
        }
        if let sendWaiter {
            self.sendWaiter = nil
            sendWaiter.resume(throwing: RealtimeTransportError.closed)
        }
    }

    func sentMessageTypes() -> [String] { sentTypes }
    func closeCount() -> Int { closes }

    func waitUntilSendStarted() async -> Bool {
        for _ in 0..<200 {
            if sendStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sendStarted
    }

    func waitUntilClosed() async -> Bool {
        for _ in 0..<200 {
            if closed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return closed
    }

    func waitUntilSentMessageCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if sentTypes.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sentTypes.count >= count
    }

    private static func messageType(_ message: RealtimeSocketMessage) -> String {
        guard case .text(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unknown"
        }
        if let type = object["type"] as? String { return type }
        if object["setup"] != nil { return "setup" }
        return "unknown"
    }
}
