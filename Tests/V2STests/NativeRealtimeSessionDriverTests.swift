import Foundation
import Testing
@testable import v2s

private final class DriverVideoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(nowNanoseconds: UInt64) {
        value = nowNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        value += nanoseconds
    }
}

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

    @Test func videoIsOffByDefaultAndUnavailableBeforeSetupAcknowledgement() async throws {
        let (defaultOffDriver, defaultOffConnection, _, defaultOffTask) = await makeReadyDriver(
            profile: .geminiLive
        )
        await expectFailure(.capabilityRejected) {
            try await defaultOffDriver.sendVideoFrame(makeVideoFrame(timestamp: 1_000_000_000))
        }
        #expect(await defaultOffConnection.sentMessageTypes() == ["setup"])
        await defaultOffDriver.stop()
        await defaultOffTask.value

        let connection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            videoEnabled: true,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await expectFailure(.capabilityRejected) {
            try await driver.sendVideoFrame(makeVideoFrame(timestamp: 1_000_000_000))
        }
        await connection.enqueue(acknowledgement(for: .geminiLive))
        #expect(await recorder.waitForOutcome() == .succeeded)
        #expect(await connection.sentMessageTypes() == ["setup"])
        await driver.stop()
        await task.value
    }

    @Test func onlyQwenAndGeminiSendValidatedCompositeFrames() async throws {
        for profile in NativeRealtimeProfile.allCases {
            let (driver, connection, _, task) = await makeReadyDriver(profile: profile, videoEnabled: true)
            let frame = makeVideoFrame(timestamp: 1_000_000_000)
            if profile.supportsVideo {
                try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 10))
                try await driver.sendVideoFrame(frame)
                try await driver.commit(makeUtterance(generation: 7, start: 0, end: 20))
                #expect(await connection.waitUntilSentFrame(frame))
                let sentTypes = await connection.sentMessageTypes()
                #expect(sentTypes.contains("input_image_buffer.append") || sentTypes.contains("video"), "sent types: \(sentTypes)")
                let messages = await connection.sentTextMessages()
                #expect(messages.contains { containsEncodedFrame($0, frame: frame) })
                await expectFailure(.capabilityRejected) {
                    try await driver.sendVideoFrame(RealtimeVideoFrame(
                        sourceAlias: "audio-1",
                        capturedAtMonotonicNanoseconds: 2_000_000_000,
                        jpegData: frame.jpegData
                    ))
                }
            } else {
                await expectFailure(.capabilityRejected) {
                    try await driver.sendVideoFrame(frame)
                }
            }
            await driver.stop()
            await task.value
        }
    }

    @Test func qwenHoldsFirstFrameUntilFirstAudioAppend() async throws {
        let (driver, connection, _, task) = await makeReadyDriver(
            profile: .qwenOmniFlash,
            videoEnabled: true
        )
        let frame = makeVideoFrame(timestamp: 1_000_000_000)
        try await driver.sendVideoFrame(frame)
        #expect(await connection.sentMessageTypes() == ["session.update"])

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 10))
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 20))
        #expect(await connection.waitUntilSentFrame(frame))
        let sentTypes = await connection.sentMessageTypes()
        #expect(sentTypes.firstIndex(of: "input_audio_buffer.append") != nil)
        #expect(sentTypes.firstIndex(of: "input_image_buffer.append") != nil)
        #expect(sentTypes.firstIndex(of: "input_audio_buffer.append")! < sentTypes.firstIndex(of: "input_image_buffer.append")!)

        await driver.stop()
        await task.value

        let (stoppedDriver, stoppedConnection, _, stoppedTask) = await makeReadyDriver(
            profile: .qwenOmniFlash,
            videoEnabled: true
        )
        try await stoppedDriver.sendVideoFrame(makeVideoFrame(timestamp: 4_000_000_000))
        await stoppedDriver.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await stoppedConnection.sentMessageTypes() == ["session.update"])
        await stoppedTask.value
    }

    @Test func qwenSendsHeldFrameSuccessfullyBeforeCommitBoundary() async throws {
        let connection = FakeRealtimeWebSocketConnection(
            suspendSendTypes: ["input_image_buffer.append", "input_audio_buffer.commit"]
        )
        let connector = FakeRealtimeWebSocketConnector(profile: .qwenOmniFlash, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .qwenOmniFlash),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            videoEnabled: true,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: .qwenOmniFlash))
        #expect(await recorder.waitForOutcome() == .succeeded)

        let firstFrame = makeVideoFrame(timestamp: 10, marker: 0x11)
        let frameDuringImageSend = makeVideoFrame(timestamp: 40, marker: 0x22)
        let newestPendingFrame = makeVideoFrame(timestamp: 50, marker: 0x33)
        try await driver.sendVideoFrame(firstFrame)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 20))
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 30))
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("input_image_buffer.append"))
        #expect(!(await connection.sentMessageTypes().contains("input_audio_buffer.commit")))
        try await driver.sendVideoFrame(frameDuringImageSend)

        await connection.releaseSuspendedSend()
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("input_audio_buffer.commit"))
        try await driver.sendVideoFrame(newestPendingFrame)
        await connection.releaseSuspendedSend()
        #expect(await connection.waitUntilSentMessageCount(4))
        #expect(await connection.sentMessageTypes() == [
            "session.update",
            "input_audio_buffer.append",
            "input_image_buffer.append",
            "input_audio_buffer.commit",
        ])
        let firstTurnMessages = await connection.sentTextMessages()
        #expect(firstTurnMessages.contains { containsEncodedFrame($0, frame: firstFrame) })
        #expect(!firstTurnMessages.contains { containsEncodedFrame($0, frame: frameDuringImageSend) })
        #expect(!firstTurnMessages.contains { containsEncodedFrame($0, frame: newestPendingFrame) })

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageType("response.create"))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_video_gate"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_video_gate","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(10))

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 40))
        try await driver.commit(makeUtterance(generation: 7, start: 35, end: 45))
        #expect(await connection.waitUntilSentMessageCount(6))
        let secondTurnTypes = await connection.sentMessageTypes()
        #expect(secondTurnTypes.filter { $0 == "input_image_buffer.append" }.count == 1)
        #expect(secondTurnTypes.filter { $0 == "input_audio_buffer.append" }.count == 2)
        #expect(secondTurnTypes.filter { $0 == "input_audio_buffer.commit" }.count == 2)

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(7))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_video_gate_second"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_video_gate_second","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(20))

        try await Task.sleep(for: .milliseconds(1_050))
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 60))
        try await driver.commit(makeUtterance(generation: 7, start: 55, end: 65))
        #expect(await connection.waitUntilSentFrame(newestPendingFrame))
        #expect(await connection.waitUntilSentMessageCount(10))
        let thirdTurnTypes = await connection.sentMessageTypes()
        #expect(thirdTurnTypes.filter { $0 == "input_image_buffer.append" }.count == 2)
        #expect(thirdTurnTypes.filter { $0 == "input_audio_buffer.append" }.count == 3)
        #expect(thirdTurnTypes.filter { $0 == "input_audio_buffer.commit" }.count == 3)
        let allSentMessages = await connection.sentTextMessages()
        #expect(allSentMessages.contains { containsEncodedFrame($0, frame: newestPendingFrame) })
        #expect(!allSentMessages.contains { containsEncodedFrame($0, frame: frameDuringImageSend) })
        await driver.stop()
        await task.value
    }

    @Test func videoMailboxKeepsNewestFrameRateLimitsAndRevocationClearsIt() async throws {
        let clock = DriverVideoTestClock(nowNanoseconds: 10_000_000_000)
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "audio")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            videoEnabled: true,
            setupTimeout: .seconds(1),
            videoNowNanoseconds: { clock.nowNanoseconds() }
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: .geminiLive))
        #expect(await recorder.waitForOutcome() == .succeeded)

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 10))
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 20))
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("audio"))

        let older = makeVideoFrame(timestamp: 2_000_000_000, marker: 0x11)
        let newest = makeVideoFrame(timestamp: 2_100_000_000, marker: 0x22)
        try await driver.sendVideoFrame(older)
        try await driver.sendVideoFrame(newest)
        await connection.releaseSuspendedSend()
        #expect(await connection.waitUntilSentFrame(newest))
        let afterFirstDrain = await connection.sentTextMessages()
        #expect(afterFirstDrain.contains { containsEncodedFrame($0, frame: newest) })
        #expect(!afterFirstDrain.contains { containsEncodedFrame($0, frame: older) })

        let rateLimited = makeVideoFrame(timestamp: 2_500_000_000, marker: 0x33)
        clock.advance(nanoseconds: 400_000_000)
        try await driver.sendVideoFrame(rateLimited)
        let newestRateLimited = makeVideoFrame(timestamp: 2_700_000_000, marker: 0x44)
        clock.advance(nanoseconds: 200_000_000)
        try await driver.sendVideoFrame(newestRateLimited)
        // Even if the CI runner pauses for longer than a second, the controlled
        // clock has advanced only 600 ms and the queued frame must remain blocked.
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(await connection.sentMessageTypes().filter { $0 == "video" }.count == 1)

        await driver.revokeVideoPermission()
        clock.advance(nanoseconds: 1_000_000_000)
        try await Task.sleep(for: .milliseconds(1_050))
        #expect(await connection.sentMessageTypes().filter { $0 == "video" }.count == 1)
        await expectFailure(.capabilityRejected) {
            try await driver.sendVideoFrame(makeVideoFrame(timestamp: 3_600_000_000))
        }

        await driver.stop()
        await task.value
    }

    @Test func geminiMailboxDoesNotReplaceNewerPendingFrameWithOlderCapture() async throws {
        let (driver, connection, _, task) = await makeReadyDriver(
            profile: .geminiLive,
            videoEnabled: true
        )
        let first = makeVideoFrame(timestamp: 2_000_000_000, marker: 0x11)
        let newestPending = makeVideoFrame(timestamp: 2_700_000_000, marker: 0x22)
        let olderArrival = makeVideoFrame(timestamp: 2_600_000_000, marker: 0x33)

        try await driver.sendVideoFrame(first)
        #expect(await connection.waitUntilSentFrame(first))
        try await driver.sendVideoFrame(newestPending)
        try await driver.sendVideoFrame(olderArrival)

        try await Task.sleep(for: .milliseconds(1_050))
        #expect(await connection.waitUntilSentFrame(newestPending))
        let sentMessages = await connection.sentTextMessages()
        #expect(sentMessages.contains { containsEncodedFrame($0, frame: newestPending) })
        #expect(!sentMessages.contains { containsEncodedFrame($0, frame: olderArrival) })

        await driver.stop()
        await task.value
    }

    @Test func qwenMailboxDoesNotReplaceNewerPendingFrameWithOlderCapture() async throws {
        let (driver, connection, _, task) = await makeReadyDriver(
            profile: .qwenOmniFlash,
            videoEnabled: true
        )
        let first = makeVideoFrame(timestamp: 2_000_000_000, marker: 0x11)
        let newestPending = makeVideoFrame(timestamp: 2_700_000_000, marker: 0x22)
        let olderArrival = makeVideoFrame(timestamp: 2_600_000_000, marker: 0x33)

        try await driver.sendVideoFrame(first)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 10))
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 20))
        #expect(await connection.waitUntilSentFrame(first))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(5))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_qwen_mailbox"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_qwen_mailbox","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(20))

        try await driver.sendVideoFrame(newestPending)
        try await driver.sendVideoFrame(olderArrival)
        try await Task.sleep(for: .milliseconds(1_050))
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 40))
        try await driver.commit(makeUtterance(generation: 7, start: 35, end: 45))

        #expect(await connection.waitUntilSentFrame(newestPending))
        let sentMessages = await connection.sentTextMessages()
        #expect(sentMessages.contains { containsEncodedFrame($0, frame: newestPending) })
        #expect(!sentMessages.contains { containsEncodedFrame($0, frame: olderArrival) })

        await driver.stop()
        await task.value
    }

    @Test func videoSendCooldownSurvivesStopAndRestart() async throws {
        let firstConnection = FakeRealtimeWebSocketConnection()
        let secondConnection = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(
            profile: .geminiLive,
            connections: [firstConnection, secondConnection]
        )
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .applicationAudio,
            connector: connector,
            videoEnabled: true,
            setupTimeout: .seconds(1)
        )
        let (firstRecorder, firstStart) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await firstConnection.waitUntilSentMessageCount(1))
        await firstConnection.enqueue(acknowledgement(for: .geminiLive))
        #expect(await firstRecorder.waitForOutcome() == .succeeded)
        let firstFrame = makeVideoFrame(timestamp: 2_000_000_000, marker: 0x11)
        try await driver.sendVideoFrame(firstFrame)
        #expect(await firstConnection.waitUntilSentFrame(firstFrame))

        await driver.stop()
        await firstStart.value

        let secondStart = Task {
            try await driver.start(sourceAlias: "audio-1", generation: 8)
        }
        #expect(await secondConnection.waitUntilSentMessageCount(1))
        await secondConnection.enqueue(acknowledgement(for: .geminiLive))
        try await secondStart.value
        let secondFrame = makeVideoFrame(timestamp: 2_100_000_000, marker: 0x22)
        try await driver.sendVideoFrame(secondFrame)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await secondConnection.sentMessageTypes().filter { $0 == "video" }.isEmpty)
        #expect(await secondConnection.waitUntilSentFrame(secondFrame))

        await driver.stop()
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

    @Test func audioChunkValidationRejectsBadInputBeforeAnySocketSend() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)

        let wrongAlias = makeChunk(alias: "audio-2", generation: 7, timestamp: 100)
        await expectFailure(.invalidConfiguration) { try await driver.sendAudioChunk(wrongAlias) }
        let wrongGeneration = makeChunk(generation: 8, timestamp: 100)
        await expectFailure(.invalidConfiguration) { try await driver.sendAudioChunk(wrongGeneration) }
        let wrongRate = makeChunk(generation: 7, timestamp: 100, sampleRate: 8_000)
        await expectFailure(.capabilityRejected) { try await driver.sendAudioChunk(wrongRate) }
        let empty = makeChunk(generation: 7, timestamp: 100, bytes: 0)
        await expectFailure(.capabilityRejected) { try await driver.sendAudioChunk(empty) }
        let odd = makeChunk(generation: 7, timestamp: 100, bytes: 3)
        await expectFailure(.capabilityRejected) { try await driver.sendAudioChunk(odd) }
        let oversized = makeChunk(generation: 7, timestamp: 100, bytes: 32_002)
        await expectFailure(.capabilityRejected) { try await driver.sendAudioChunk(oversized) }

        #expect(await connection.sentMessageTypes() == ["session.update"])
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        #expect(await connection.sentMessageTypes() == ["session.update"])
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func commitDrainsOnlyCommittedIntervalThenSendsBoundary() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 200))
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 900))

        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])

        // A second commit before the acknowledgement must fail without another boundary.
        await expectFailure(.capabilityRejected) {
            try await driver.commit(makeUtterance(generation: 7, start: 501, end: 1_000))
        }
        #expect(await connection.sentMessageTypes().count == 3)

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_empty"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_empty","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(10))

        // The later chunk stayed queued for the next utterance.
        try await driver.commit(makeUtterance(generation: 7, start: 501, end: 1_000))
        #expect(await connection.waitUntilSentMessageCount(6))
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
            "response.create", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])

        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func openAIExactCommitResamplesOnlyTheSelectedCaptionBeforeWireAppend() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        var operationSucceeded = false
        do {
            let source = Data([10, 0, 20, 0])
            try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 0, pcm16LEData: source))
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 125_000))
            operationSucceeded = true
        } catch {
            operationSucceeded = false
        }
        let didSend = await connection.waitUntilSentMessageCount(3)
        let messages = await connection.sentTextMessages()
        let sentTypes = await connection.sentMessageTypes()
        let savedTasks = await driver.backgroundTasksForTesting()
        await driver.stop()
        await task.value
        for savedTask in savedTasks { await savedTask.value }
        #expect(operationSucceeded)
        #expect(didSend)
        #expect(appendedPCM(in: messages) == [Data([10, 0, 17, 0, 20, 0])])
        #expect(sentTypes == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func openAIWirePreservesSignedConstantRampAndExtremaVectors() async throws {
        func pcm16LE(_ samples: [Int16]) -> Data {
            Data(samples.flatMap { sample in
                let bits = UInt16(bitPattern: sample)
                return [UInt8(bits & 0xff), UInt8(bits >> 8)]
            })
        }
        let vectors: [([Int16], [Int16])] = [
            ([-1234], [-1234]),
            ([1234, 1234, 1234, 1234], [1234, 1234, 1234, 1234, 1234, 1234]),
            ([0, 300, 600, 900], [0, 200, 400, 600, 800, 900]),
            ([-32_768, 32_767], [-32_768, 10_922, 32_767]),
            ([32_767, -32_768], [32_767, -10_923, -32_768]),
        ]
        for (sourceSamples, expectedSamples) in vectors {
            let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
            var operationSucceeded = false
            do {
                let source = pcm16LE(sourceSamples)
                let duration = UInt64(sourceSamples.count) * 62_500
                try await driver.sendAudioChunk(makeExactChunk(
                    generation: 7, start: 0, pcm16LEData: source
                ))
                try await driver.commit(makeUtterance(generation: 7, start: 0, end: duration))
                operationSucceeded = true
            } catch {
                operationSucceeded = false
            }
            let didSend = await connection.waitUntilSentMessageCount(3)
            let appends = appendedPCM(in: await connection.sentTextMessages())
            let savedTasks = await driver.backgroundTasksForTesting()
            await driver.stop()
            await task.value
            for savedTask in savedTasks { await savedTask.value }
            #expect(operationSucceeded)
            #expect(didSend)
            #expect(appends == [pcm16LE(expectedSamples)])
            #expect(await recorder.outcome() == .succeeded)
        }
    }

    @Test func oneSecondOpenAIUtteranceSplitsAtWireByteCap() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        var operationSucceeded = false
        do {
            let source = Data(repeating: 0, count: 32_000)
            try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 0, pcm16LEData: source))
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 1_000_000_000))
            operationSucceeded = true
        } catch {
            operationSucceeded = false
        }
        let didSend = await connection.waitUntilSentMessageCount(4)
        let appends = appendedPCM(in: await connection.sentTextMessages())
        let savedTasks = await driver.backgroundTasksForTesting()
        await driver.stop()
        await task.value
        for savedTask in savedTasks { await savedTask.value }
        #expect(operationSucceeded)
        #expect(didSend)
        #expect(appends.count == 2)
        #expect(appends.map(\.count) == [32_000, 16_000])
        #expect(appends.allSatisfy { !$0.isEmpty && $0.count.isMultiple(of: 2) && $0.count <= 32_000 })
        #expect(appends.reduce(0) { $0 + $1.count } == 48_000)
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func maximumCanonicalOpenAIUtteranceProducesAtMostTwentyFourWireAppends() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        var operationSucceeded = false
        do {
            let source = Data(repeating: 0, count: 32_000)
            for index in 0..<16 {
                try await driver.sendAudioChunk(makeExactChunk(
                    generation: 7, start: UInt64(index) * 1_000_000_000, pcm16LEData: source
                ))
            }
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 16_000_000_000))
            operationSucceeded = true
        } catch {
            operationSucceeded = false
        }
        let didSend = await connection.waitUntilSentMessageCount(26)
        let messages = await connection.sentTextMessages()
        let sentTypes = await connection.sentMessageTypes()
        let appends = appendedPCM(in: messages)
        let savedTasks = await driver.backgroundTasksForTesting()
        await driver.stop()
        await task.value
        for savedTask in savedTasks { await savedTask.value }
        #expect(operationSucceeded)
        #expect(didSend)
        #expect(appends.count == 24)
        #expect(appends.allSatisfy { $0.count == 32_000 && $0.count.isMultiple(of: 2) })
        #expect(appends.reduce(0) { $0 + $1.count } == 768_000)
        #expect(sentTypes.suffix(25).filter { $0 == "input_audio_buffer.commit" }.count == 1)
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func exactCommitRejectsGapsAndPreservesBothUsableRanges() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let firstPCM = Data([10, 0, 20, 0])
        let laterPCM = Data([40, 0, 50, 0])
        try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 0, pcm16LEData: firstPCM))
        try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 187_500, pcm16LEData: laterPCM))

        var gapWasRejected = false
        do {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 312_500))
        } catch let code as RealtimeFailureCode {
            gapWasRejected = code == .invalidConfiguration
        }
        #expect(gapWasRejected)
        if !gapWasRejected {
            #expect(await connection.waitUntilSentMessageCount(3))
            #expect(await connection.sentMessageTypes() == ["session.update"])
            await driver.stop()
            eventTask.cancel()
            #expect(await recorder.outcome() == .succeeded)
            await task.value
            return
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])

        // The failed full-span commit left both disjoint chunks available for their
        // own caption intervals, with no partial audio sent for the rejected one.
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 125_000))
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(appendedPCM(in: await connection.sentTextMessages()) == [Data([10, 0, 17, 0, 20, 0])])
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_gap_first"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_gap_first","delta":"first"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_gap_first","status":"completed"}}"#))
        #expect(await events.waitForCount(2))

        try await driver.commit(makeUtterance(generation: 7, start: 187_500, end: 312_500))
        #expect(await connection.waitUntilSentMessageCount(6))
        #expect(appendedPCM(in: await connection.sentTextMessages()) == [Data([10, 0, 17, 0, 20, 0]), Data([40, 0, 47, 0, 50, 0])])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactCommitRejectsUnavailableStartHistoryWithoutSendingPCM() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        try await driver.sendAudioChunk(makeExactChunk(
            generation: 7,
            start: 125_000,
            pcm16LEData: Data([10, 0, 20, 0])
        ))
        var rejected = false
        do {
            try await driver.commit(makeUtterance(generation: 7, start: 62_500, end: 187_500))
        } catch let code as RealtimeFailureCode {
            rejected = code == .invalidConfiguration
        }
        #expect(rejected)
        if !rejected { #expect(await connection.waitUntilSentMessageCount(3)) }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactCommitRejectsUnavailableEndHistoryWithoutSendingPCM() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        try await driver.sendAudioChunk(makeExactChunk(
            generation: 7,
            start: 125_000,
            pcm16LEData: Data([10, 0, 20, 0])
        ))
        var rejected = false
        do {
            try await driver.commit(makeUtterance(generation: 7, start: 125_000, end: 312_500))
        } catch let code as RealtimeFailureCode {
            rejected = code == .invalidConfiguration
        }
        #expect(rejected)
        if !rejected { #expect(await connection.waitUntilSentMessageCount(3)) }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func preciseCoverageRequirementRejectsPointOnlyAudioAndPreservesCompatibilityMailbox() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let interval = makeUtterance(
            generation: 7,
            start: 0,
            end: 500,
            requiresPreciseSampleCoverage: true
        )
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100, bytes: 4))

        var rejected = false
        do {
            try await driver.commit(interval)
        } catch let code as RealtimeFailureCode {
            rejected = code == .invalidConfiguration
        }
        #expect(rejected)
        if !rejected {
            #expect(await connection.waitUntilSentMessageCount(3))
            #expect(await connection.sentMessageTypes().contains("input_audio_buffer.append"))
            await driver.stop()
            #expect(await recorder.outcome() == .succeeded)
            await task.value
            return
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])

        // The compatibility caller can still consume the original point-only PCM.
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(appendedPCM(in: await connection.sentTextMessages()) == [Data([0, 0, 0, 0, 0, 0])])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactAudioRejectsIncompleteAndDurationInvalidSpans() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let incompleteChunks = [
            RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: 7,
                capturedAtMonotonicNanoseconds: 0,
                endMonotonicNanoseconds: 62_500,
                pcm16LEData: Data([1, 0]),
                sampleRate: 16_000
            ),
            RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: 7,
                capturedAtMonotonicNanoseconds: 0,
                startMonotonicNanoseconds: 0,
                pcm16LEData: Data([2, 0]),
                sampleRate: 16_000
            ),
            RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: 7,
                capturedAtMonotonicNanoseconds: 0,
                startMonotonicNanoseconds: 0,
                endMonotonicNanoseconds: 125_000,
                pcm16LEData: Data([3, 0]),
                sampleRate: 16_000
            ),
        ]
        for chunk in incompleteChunks {
            await expectFailure(.invalidConfiguration) {
                try await driver.sendAudioChunk(chunk)
            }
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactAudioRejectsOverlappingInputWithoutSendingAudio() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        try await driver.sendAudioChunk(makeExactChunk(
            generation: 7,
            start: 0,
            pcm16LEData: Data([10, 0, 20, 0])
        ))
        await expectFailure(.invalidConfiguration) {
            try await driver.sendAudioChunk(makeExactChunk(
                generation: 7,
                start: 62_500,
                pcm16LEData: Data([30, 0, 40, 0])
            ))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactAudioRejectsOutOfOrderInput() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        try await driver.sendAudioChunk(makeExactChunk(
            generation: 7,
            start: 125_000,
            pcm16LEData: Data([10, 0, 20, 0])
        ))
        await expectFailure(.invalidConfiguration) {
            try await driver.sendAudioChunk(makeExactChunk(
                generation: 7,
                start: 0,
                pcm16LEData: Data([30, 0, 40, 0])
            ))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactAudioRejectsStaleInputAfterCommitDrainsMailbox() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let pcm = Data([10, 0, 20, 0])
        let chunk = makeExactChunk(generation: 7, start: 0, pcm16LEData: pcm)
        try await driver.sendAudioChunk(chunk)
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 125_000))
        #expect(await connection.waitUntilSentMessageCount(3))

        await expectFailure(.invalidConfiguration) {
            try await driver.sendAudioChunk(chunk)
        }
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactSampleBoundariesMustBeFrameAligned() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let pcm = Data([10, 0, 20, 0, 30, 0, 40, 0])
        try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 0, pcm16LEData: pcm))
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 187_501))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func exactCommitFailurePreservesQueuedPCM() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let pcm = Data([10, 0, 20, 0, 30, 0, 40, 0])
        try await driver.sendAudioChunk(makeExactChunk(generation: 7, start: 0, pcm16LEData: pcm))
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 187_501))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])

        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 250_000))
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(appendedPCM(in: await connection.sentTextMessages()) == [Data([10, 0, 17, 0, 23, 0, 30, 0, 37, 0, 40, 0])])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func commitSlicesPartialPCMChunksAndRetainsTheLaterSuffix() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let firstPCM = Data([10, 0, 20, 0, 30, 0, 40, 0])
        let secondPCM = Data([50, 0, 60, 0, 70, 0, 80, 0])
        try await driver.sendAudioChunk(RealtimeAudioChunk(
            sourceAlias: "audio-1",
            generation: 7,
            capturedAtMonotonicNanoseconds: 0,
            startMonotonicNanoseconds: 0,
            endMonotonicNanoseconds: 250_000,
            pcm16LEData: firstPCM,
            sampleRate: 16_000
        ))
        try await driver.sendAudioChunk(RealtimeAudioChunk(
            sourceAlias: "audio-1",
            generation: 7,
            capturedAtMonotonicNanoseconds: 250_000,
            startMonotonicNanoseconds: 250_000,
            endMonotonicNanoseconds: 500_000,
            pcm16LEData: secondPCM,
            sampleRate: 16_000
        ))

        try await driver.commit(makeUtterance(generation: 7, start: 62_500, end: 312_500))
        #expect(await connection.waitUntilSentMessageCount(3))
        let firstTurnMessages = await connection.sentTextMessages()
        #expect(appendedPCM(in: firstTurnMessages) == [
            Data([20, 0, 27, 0, 33, 0, 40, 0, 47, 0, 50, 0]),
        ])

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_sliced"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_sliced","delta":"ready"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_sliced","status":"completed"}}"#))
        #expect(await events.waitForCount(2))

        try await driver.commit(makeUtterance(generation: 7, start: 312_500, end: 500_000))
        #expect(await connection.waitUntilSentMessageCount(6))
        let secondTurnMessages = await connection.sentTextMessages()
        #expect(appendedPCM(in: secondTurnMessages) == [
            Data([20, 0, 27, 0, 33, 0, 40, 0, 47, 0, 50, 0]),
            Data([60, 0, 67, 0, 73, 0, 80, 0]),
        ])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func committedUtteranceRequestsOneTextCorrectionAndWaitsForCompletion() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let captionID = UUID(uuidString: "A452C695-8E33-4F47-A90D-4906381052A0")!
        let utterance = RealtimeUtterance(
            sourceAlias: "audio-1",
            generation: 7,
            captionID: captionID,
            utteranceID: "turn-42",
            startMonotonicNanoseconds: 90,
            endMonotonicNanoseconds: 200
        )

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])
        await expectFailure(.capabilityRejected) {
            try await driver.commit(utterance)
        }
        #expect(await connection.sentMessageTypes().count == 3)

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        let responseRequest = try #require(await connection.sentTextMessages().last)
        let responseObject = try #require(JSONSerialization.jsonObject(with: Data(responseRequest.utf8)) as? [String: Any])
        let response = try #require(responseObject["response"] as? [String: Any])
        #expect(responseObject["type"] as? String == "response.create")
        #expect(response["output_modalities"] as? [String] == ["text"])

        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_turn-42"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_turn-42","delta":"Where is the next station?"}"#))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await events.snapshot().isEmpty)

        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_turn-42","status":"completed"}}"#))
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: captionID,
                utteranceID: "turn-42",
                text: "Where is the next station?"
            ),
            .utteranceCompleted(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: captionID,
                utteranceID: "turn-42"
            ),
        ])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test(arguments: [NativeRealtimeProfile.openAIMini, .geminiLive])
    func eventLossDuringFailureOrExpiryCannotReuseProviderStream(profile: NativeRealtimeProfile) async throws {
        let connection = FakeRealtimeWebSocketConnection()
        let replacement = FakeRealtimeWebSocketConnection()
        let connector = FakeRealtimeWebSocketConnector(profile: profile, connections: [connection, replacement])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: profile),
            credential: "synthetic-key",
            sourceRole: .applicationAudio,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, startTask) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: profile))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await startTask.value

        // Retain exactly a full stream of correlated terminal events. The next
        // failure/expiry notification displaces one even though state is terminal.
        for turn in 1...32 {
            let timestamp = UInt64(1_000 + (turn - 1) * 1_000)
            let utterance = RealtimeUtterance(
                sourceAlias: "audio-1", generation: 7, captionID: UUID(),
                utteranceID: "terminal-state-loss-\(turn)",
                startMonotonicNanoseconds: timestamp,
                endMonotonicNanoseconds: timestamp + 1_000
            )
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp))
            try await driver.commit(utterance)
            if profile == .geminiLive {
                #expect(await connection.waitUntilSentMessageCount(1 + 3 * turn))
                await connection.enqueue(.text(#"{"serverContent":{"turnComplete":true}}"#))
            } else {
                #expect(await connection.waitUntilSentMessageCount(3 * turn))
                await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
                #expect(await connection.waitUntilSentMessageCount(1 + 3 * turn))
                let responseID = "resp_terminal_state_loss_\(turn)"
                await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
                await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed"}}"#))
            }
            await driver.waitForTerminalEventCountForTesting(turn)
        }
        if profile == .geminiLive {
            await connection.enqueue(.text(#"{"goAway":{"timeLeft":{"seconds":"12"}}}"#))
        } else {
            await connection.enqueue(.text(#"{"type":"error","error":{"code":"rate_limit_exceeded"}}"#))
        }
        await connection.waitForClose()

        // A valid new-generation socket would accept setup if restart were allowed.
        // Reject before dialing: correlation was lost, so this owner needs replacing.
        await replacement.enqueue(acknowledgement(for: profile))
        await expectFailure(.connectionFailed) {
            try await driver.start(sourceAlias: "audio-1", generation: 8)
        }
        #expect((await connector.sanitizedRequests()).count == 1)
        await driver.stop()
    }

    @Test func slowConsumerOverflowOnCorrectionDoesNotEmitTerminalForThatCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        var overflowUtterance: RealtimeUtterance?

        for turn in 1...17 {
            let timestamp = UInt64(1_000 + (turn - 1) * 1_000)
            let utterance = RealtimeUtterance(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: UUID(),
                utteranceID: "correction-overflow-\(turn)",
                startMonotonicNanoseconds: timestamp,
                endMonotonicNanoseconds: timestamp + 1_000
            )
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp))
            try await driver.commit(utterance)
            #expect(await connection.waitUntilSentMessageCount(3 * turn))
            await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
            #expect(await connection.waitUntilSentMessageCount(1 + 3 * turn))
            let responseID = "resp_correction_overflow_\(turn)"
            await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
            await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"\#(responseID)","delta":"corrected words for turn \#(turn)"}"#))
            await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed"}}"#))
            if turn < 17 {
                await driver.waitForTerminalEventCountForTesting(turn)
            } else {
                overflowUtterance = utterance
                await driver.waitForProviderEventBackpressureForTesting()
            }
        }

        #expect(await driver.isFailedForTesting())
        await connection.waitForClose()
        #expect(!(await driver.hasPendingMediaForTesting()))

        let stream = await driver.events()
        var iterator = stream.makeAsyncIterator()
        var bufferedEvents: [RealtimeProviderEvent] = []
        for _ in 0..<33 {
            guard let event = await iterator.next() else { break }
            bufferedEvents.append(event)
        }
        #expect(bufferedEvents.count == 32)
        #expect(bufferedEvents.last == .failure(sourceAlias: "audio-1", generation: 7, .backpressure))
        if let overflowUtterance {
            #expect(bufferedEvents.contains(.correctedText(
                sourceAlias: overflowUtterance.sourceAlias,
                generation: overflowUtterance.generation,
                captionID: overflowUtterance.captionID,
                utteranceID: overflowUtterance.utteranceID,
                text: "corrected words for turn 17"
            )))
            #expect(!bufferedEvents.contains(completedEvent(for: overflowUtterance)))
        }

        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func slowProviderEventConsumerIsBoundedAndFailsOnlyItsDriver() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(
            profile: .qwenOmniFlash,
            videoEnabled: true
        )
        let (sibling, siblingConnection, siblingRecorder, siblingTask) = await makeReadyDriver(profile: .openAIMini)
        try await driver.sendVideoFrame(makeVideoFrame(timestamp: 1_000_000_000))

        for index in 0..<33 {
            let turn = index + 1
            let timestamp = UInt64(1_000 + index * 1_000)
            let utterance = RealtimeUtterance(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: UUID(),
                utteranceID: "overflow-\(turn)",
                startMonotonicNanoseconds: timestamp,
                endMonotonicNanoseconds: timestamp + 1_000
            )
            if turn == 33 {
                try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp + 2_000))
            }
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp))
            try await driver.commit(utterance)
            #expect(await connection.waitUntilSentMessageCount(3 * turn))
            await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
            #expect(await connection.waitUntilSentMessageCount(1 + 3 * turn))
            let responseID = "resp_overflow_\(turn)"
            await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
            await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed"}}"#))
            await driver.waitForTerminalEventCountForTesting(turn)
        }

        let didFail = await driver.isFailedForTesting()
        #expect(didFail)
        if didFail {
            await connection.waitForClose()
            #expect(!(await driver.hasPendingMediaForTesting()))
        }

        let stream = await driver.events()
        var iterator = stream.makeAsyncIterator()
        var bufferedEvents: [RealtimeProviderEvent] = []
        for _ in 0..<33 {
            guard let event = await iterator.next() else { break }
            bufferedEvents.append(event)
        }
        #expect(bufferedEvents.count == 32)
        #expect(bufferedEvents.last == .failure(sourceAlias: "audio-1", generation: 7, .backpressure))
        #expect(bufferedEvents.filter {
            if case .utteranceCompleted = $0 { return true }
            return false
        }.count == 31)

        // A lost event degrades only its owning driver; the sibling can still complete
        // and delivers its correction before the matching terminal event.
        let siblingStream = await sibling.events()
        let siblingUtterance = makeUtterance(generation: 7, start: 100, end: 200)
        try await sibling.sendAudioChunk(makeChunk(generation: 7, timestamp: 150))
        try await sibling.commit(siblingUtterance)
        #expect(await siblingConnection.waitUntilSentMessageCount(3))
        await siblingConnection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await siblingConnection.waitUntilSentMessageCount(4))
        await siblingConnection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_sibling"}}"#))
        await siblingConnection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_sibling","delta":"healthy caption"}"#))
        await siblingConnection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_sibling","status":"completed"}}"#))
        await sibling.waitForTerminalEventCountForTesting(1)
        var siblingIterator = siblingStream.makeAsyncIterator()
        #expect(await siblingIterator.next() == .correctedText(
            sourceAlias: "audio-1",
            generation: 7,
            captionID: siblingUtterance.captionID,
            utteranceID: siblingUtterance.utteranceID,
            text: "healthy caption"
        ))
        #expect(await siblingIterator.next() == completedEvent(for: siblingUtterance))

        await driver.stop()
        await sibling.stop()
        #expect(await recorder.outcome() == .succeeded)
        #expect(await siblingRecorder.outcome() == .succeeded)
        await task.value
        await siblingTask.value
    }

    @Test func emptyTerminalCompletesOnceAndAllowsTheNextUtterance() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let emptyUtterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(emptyUtterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_empty"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_empty","status":"completed"}}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [completedEvent(for: emptyUtterance)])

        let nextUtterance = makeUtterance(generation: 7, start: 290, end: 400)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 300))
        try await driver.commit(nextUtterance)
        #expect(await connection.waitUntilSentMessageCount(6))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(7))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_next"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_next","delta":"next statement"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_next","status":"completed"}}"#))
        #expect(await events.waitForCount(3))
        #expect(await events.snapshot() == [
            completedEvent(for: emptyUtterance),
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: nextUtterance.captionID,
                utteranceID: nextUtterance.utteranceID,
                text: "next statement"
            ),
            completedEvent(for: nextUtterance),
        ])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func providersUseTheirManualCommitAndResponseSequence() async throws {
        for profile in [NativeRealtimeProfile.openAIMini, .xAIVoice, .qwenOmniFlash, .geminiLive] {
            let (driver, connection, recorder, task) = await makeReadyDriver(profile: profile)
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
            try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))

            if profile == .geminiLive {
                #expect(await connection.waitUntilSentMessageCount(4))
                #expect(await connection.sentMessageTypes() == [
                    "setup", "activityStart", "audio", "activityEnd",
                ])
                #expect(!(await connection.sentMessageTypes()).contains("response.create"))
            } else {
                #expect(await connection.waitUntilSentMessageCount(3))
                #expect(await connection.sentMessageTypes() == [
                    "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
                ])
                if profile.provider == .xAI {
                    let wireMessages = await connection.sentTextMessages()
                    let setup = try #require(JSONSerialization.jsonObject(
                        with: Data(wireMessages[0].utf8)
                    ) as? [String: Any])
                    let session = try #require(setup["session"] as? [String: Any])
                    let audio = try #require(session["audio"] as? [String: Any])
                    let input = try #require(audio["input"] as? [String: Any])
                    let format = try #require(input["format"] as? [String: Any])
                    #expect(format["rate"] as? Int == 16_000)
                    #expect(appendedPCM(in: wireMessages) == [Data(repeating: 0, count: 320)])
                }
                await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
                #expect(await connection.waitUntilSentMessageCount(4))
                let responseRequest = try #require(await connection.sentTextMessages().last)
                let responseObject = try #require(JSONSerialization.jsonObject(with: Data(responseRequest.utf8)) as? [String: Any])
                #expect(responseObject["type"] as? String == "response.create")
                if profile.provider == .openAI {
                    let response = try #require(responseObject["response"] as? [String: Any])
                    #expect(response["output_modalities"] as? [String] == ["text"])
                } else if profile.provider == .xAI {
                    let response = try #require(responseObject["response"] as? [String: Any])
                    #expect(response["modalities"] as? [String] == ["text"])
                } else {
                    #expect(responseObject["response"] == nil)
                }
            }

            await driver.stop()
            #expect(await recorder.outcome() == .succeeded)
            await task.value
        }
    }

    @Test func unsolicitedAndMismatchedResponseTextCannotCorrectCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))

        // Text before response.created is unsolicited and must be ignored.
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp-real","delta":"unrequested"}"#))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp-real"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp-other","delta":"mismatched"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp-other","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await events.snapshot().isEmpty)

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func lateResponseIDFromPriorUtteranceCannotBindToNextCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let firstUtterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(firstUtterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_previous"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_previous","delta":"first caption"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_previous","status":"completed"}}"#))
        #expect(await events.waitForCount(2))

        let secondUtterance = makeUtterance(generation: 7, start: 290, end: 400)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 300))
        try await driver.commit(secondUtterance)
        #expect(await connection.waitUntilSentMessageCount(6))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(7))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_previous"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_previous","delta":"late prior text"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_previous","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().count == 2)

        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_current"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_current","delta":"second caption"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_current","status":"completed"}}"#))
        #expect(await events.waitForCount(4))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: firstUtterance.captionID,
                utteranceID: firstUtterance.utteranceID,
                text: "first caption"
            ),
            completedEvent(for: firstUtterance),
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: secondUtterance.captionID,
                utteranceID: secondUtterance.utteranceID,
                text: "second caption"
            ),
            completedEvent(for: secondUtterance),
        ])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func conversationalResponseCannotOverwriteCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .qwenOmniFlash)
        let (events, eventTask) = await recordEvents(from: driver)
        let replies = [
            "Can I help you with anything else?",
            "I can help with that.",
            "Hello! How can I help you today?",
            "Certainly, here’s the corrected transcript: hello.",
            "Absolutely, the transcription is: hello.",
            "Of course — I can provide the corrected transcript: hello.",
            "For this audio, I can provide a transcription: hello.",
        ]
        var expectedEvents: [RealtimeProviderEvent] = []
        for (index, reply) in replies.enumerated() {
            let timestamp = UInt64(100 + index * 200)
            let responseID = "resp_answer_\(index)"
            let sentCount = await connection.sentMessageTypes().count
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp))
            let utterance = makeUtterance(
                generation: 7,
                start: timestamp - 10,
                end: timestamp + 100
            )
            try await driver.commit(utterance)
            expectedEvents.append(completedEvent(for: utterance))
            #expect(await connection.waitUntilSentMessageCount(sentCount + 2))
            await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
            #expect(await connection.waitUntilSentMessageCount(sentCount + 3))
            await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
            await connection.enqueue(.text(#"{"type":"response.text.delta","response_id":"\#(responseID)","delta":"\#(reply)"}"#))
            await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed"}}"#))
            #expect(await events.waitForCount(expectedEvents.count))
        }
        #expect(await events.waitForCount(replies.count))
        #expect(await events.snapshot() == expectedEvents)

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func stoppingDuringOpenAIAppendPreventsLaterMessagesAfterRevocation() async throws {
        let connection = FakeRealtimeWebSocketConnection(
            suspendSendType: "input_audio_buffer.append", holdClose: true
        )
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, startTask) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: .openAIMini))
        let startOutcome = await recorder.waitForOutcome()
        if startOutcome != .succeeded {
            let startupTasks = await driver.backgroundTasksForTesting()
            await connection.releaseHeldClose()
            await driver.stop()
            for startupTask in startupTasks { await startupTask.value }
            await startTask.value
            #expect(startOutcome == .succeeded)
            return
        }
        await startTask.value

        var admitted = false
        do {
            try await driver.sendAudioChunk(makeExactChunk(
                generation: 7, start: 0, pcm16LEData: Data(repeating: 0, count: 32_000)
            ))
            admitted = true
        } catch {
            admitted = false
        }
        var commitTask: Task<Void, Error>?
        if admitted {
            commitTask = Task {
                try await driver.commit(makeUtterance(generation: 7, start: 0, end: 1_000_000_000))
            }
        }
        let heldAppend = await connection.waitUntilSuspendedMessageTypeStarted("input_audio_buffer.append")
        let savedTasks = await driver.backgroundTasksForTesting()
        let savedDrain = await driver.drainTaskForTesting()
        let stopTask = Task { await driver.stop() }
        let closeHeld = await connection.waitUntilCloseStarted()

        // Revoke the generation while the first append is held, then let that
        // already-recorded send succeed while the socket remains open. The drain
        // must hit its operation/state fence before attempting append two.
        await connection.releaseSuspendedSend()
        if heldAppend {
            await savedDrain?.value
        } else {
            await connection.releaseHeldClose()
            await driver.stop()
            await savedDrain?.value
        }
        let typesBeforeClose = await connection.sentMessageTypes()
        await connection.releaseHeldClose()
        await stopTask.value
        for savedTask in savedTasks { await savedTask.value }
        if let commitTask {
            do { try await commitTask.value } catch { }
        }
        let finalTypes = await connection.sentMessageTypes()
        #expect(admitted)
        #expect(heldAppend)
        #expect(closeHeld)
        #expect(typesBeforeClose == ["session.update", "input_audio_buffer.append"])
        #expect(finalTypes == ["session.update", "input_audio_buffer.append"])
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func openAIAppendFailureClearsStateWithoutLaterMessages() async throws {
        let connection = FakeRealtimeWebSocketConnection(
            suspendSendType: "input_audio_buffer.append", holdClose: true
        )
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, startTask) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: .openAIMini))
        let startOutcome = await recorder.waitForOutcome()
        if startOutcome != .succeeded {
            let startupTasks = await driver.backgroundTasksForTesting()
            await connection.releaseHeldClose()
            await driver.stop()
            for startupTask in startupTasks { await startupTask.value }
            await startTask.value
            #expect(startOutcome == .succeeded)
            return
        }
        await startTask.value

        var admitted = false
        do {
            try await driver.sendAudioChunk(makeExactChunk(
                generation: 7, start: 0, pcm16LEData: Data(repeating: 0, count: 32_000)
            ))
            admitted = true
        } catch {
            admitted = false
        }
        var commitTask: Task<Void, Error>?
        if admitted {
            commitTask = Task {
                try await driver.commit(makeUtterance(generation: 7, start: 0, end: 1_000_000_000))
            }
        }
        let heldAppend = await connection.waitUntilSuspendedMessageTypeStarted("input_audio_buffer.append")
        let savedTasks = await driver.backgroundTasksForTesting()
        let savedDrain = await driver.drainTaskForTesting()
        await connection.failSuspendedSend()
        let closeHeld = await connection.waitUntilCloseStarted()
        let failed = await driver.isFailedForTesting()
        let mailboxCleared = !(await driver.hasPendingMediaForTesting())
        if !heldAppend {
            await connection.releaseSuspendedSend()
            await connection.releaseHeldClose()
            await driver.stop()
        } else {
            await connection.releaseHeldClose()
        }
        await savedDrain?.value
        for savedTask in savedTasks { await savedTask.value }
        if let commitTask {
            do { try await commitTask.value } catch { }
        }
        let stopTask = Task { await driver.stop() }
        await stopTask.value
        let sentTypes = await connection.sentMessageTypes()
        #expect(admitted)
        #expect(heldAppend)
        #expect(closeHeld)
        #expect(failed)
        #expect(mailboxCleared)
        #expect(sentTypes == ["session.update", "input_audio_buffer.append"])
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func commitAcknowledgementBeforeBoundaryFlushCannotRequestResponse() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "input_audio_buffer.commit")
        let connector = FakeRealtimeWebSocketConnector(profile: .openAIMini, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .openAIMini),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(acknowledgement(for: .openAIMini))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value

        // An ACK before this utterance's boundary send starts is stale and ignored.
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await connection.sentMessageTypes() == ["session.update"])

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("input_audio_buffer.commit"))
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])

        // The boundary is on wire, but send() has not returned to the actor yet.
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await connection.sentMessageTypes() == [
            "session.update", "input_audio_buffer.append", "input_audio_buffer.commit",
        ])

        await connection.releaseSuspendedSend()
        #expect(await connection.waitUntilSentMessageCount(3))
        #expect(await connection.waitUntilSentMessageCount(4))
        #expect(await connection.sentMessageTypes().last == "response.create")

        await driver.stop()
    }

    @Test func completedResponseWithAudioContentFailsEveryTextOnlyProvider() async throws {
        for profile in [NativeRealtimeProfile.openAIMini, .xAIVoice, .qwenOmniFlash] {
            let (driver, connection, recorder, task) = await makeReadyDriver(profile: profile)
            let (events, eventTask) = await recordEvents(from: driver)
            let responseID = "resp_audio_\(profile.provider.rawValue)"
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
            try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
            #expect(await connection.waitUntilSentMessageCount(3))
            await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
            #expect(await connection.waitUntilSentMessageCount(4))
            await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
            await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"\#(responseID)","delta":"must not apply"}"#))
            await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed","output":[{"type":"message","content":[{"type":"audio","data":"AQID"}]}]}}"#))
            #expect(await events.waitForCount(1))
            #expect(await events.snapshot() == [
                .failure(sourceAlias: "audio-1", generation: 7, .capabilityRejected),
            ])

            eventTask.cancel()
            await driver.stop()
            #expect(await recorder.outcome() == .succeeded)
            await task.value
        }
    }

    @Test func embeddedConversationalAnswerCannotOverwriteCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_reply"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_reply","delta":"Hello! How can I help you today?"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_reply","status":"completed"}}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [completedEvent(for: utterance)])
        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func ordinarySpokenStatementRemainsEligibleForCorrection() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_statement"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_statement","delta":"The package arrives\ntomorrow."}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_statement","status":"completed"}}"#))
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: utterance.captionID,
                utteranceID: utterance.utteranceID,
                text: "The package arrives\ntomorrow."
            ),
            completedEvent(for: utterance),
        ])
        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func cancelledQwenResponseCannotCorrectCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .qwenOmniFlash)
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_cancel"}}"#))
        await connection.enqueue(.text(#"{"type":"response.text.delta","response_id":"resp_cancel","delta":"must not apply"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_cancel","status":"cancelled"}}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [
            .failure(sourceAlias: "audio-1", generation: 7, .capabilityRejected),
        ])

        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func overlongCumulativeResponseCannotCorrectCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_long"}}"#))
        let firstHalf = String(repeating: "a", count: 5_000)
        let secondHalf = String(repeating: "b", count: 5_000)
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_long","delta":"\#(firstHalf)"}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_long","delta":"\#(secondHalf)"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_long","status":"completed"}}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [completedEvent(for: utterance)])

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func stoppingDuringResponseClearsPendingCorrectionAcrossRestart() async throws {
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
        let (events, eventTask) = await recordEvents(from: driver)
        let (recorder, firstStart) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await oldConnection.waitUntilSentMessageCount(1))
        await oldConnection.enqueue(acknowledgement(for: .openAIMini))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await firstStart.value
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await oldConnection.waitUntilSentMessageCount(3))
        await oldConnection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await oldConnection.waitUntilSentMessageCount(4))
        await oldConnection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_old"}}"#))
        await oldConnection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_old","delta":"stale text"}"#))
        try await Task.sleep(for: .milliseconds(20))

        await driver.stop()
        let secondStart = Task { try await driver.start(sourceAlias: "audio-1", generation: 7) }
        #expect(await newConnection.waitUntilSentMessageCount(1))
        await newConnection.enqueue(acknowledgement(for: .openAIMini))
        try await secondStart.value
        // The stopped socket cannot complete the old pending response after restart.
        await oldConnection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_old","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().isEmpty)

        await driver.stop()
        eventTask.cancel()
        await firstStart.value
    }

    @Test func textOnlySourceFailsIfProviderEmitsOutputAudio() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .xAIVoice)
        let (events, eventTask) = await recordEvents(from: driver)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_audio"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_audio.delta","response_id":"resp_audio","delta":"AQID"}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [
            .failure(sourceAlias: "audio-1", generation: 7, .capabilityRejected),
        ])
        #expect(await connection.waitUntilClosed())

        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func providerFailureOnOneSourceDoesNotStopAnotherSource() async throws {
        let (failedDriver, failedConnection, failedRecorder, failedTask) = await makeReadyDriver(profile: .openAIMini)
        let (healthyDriver, healthyConnection, healthyRecorder, healthyTask) = await makeReadyDriver(profile: .openAIMini)
        let (failedEvents, failedEventTask) = await recordEvents(from: failedDriver)
        let (healthyEvents, healthyEventTask) = await recordEvents(from: healthyDriver)
        let healthyUtterance = makeUtterance(generation: 7, start: 90, end: 200)
        let failedUtterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await failedDriver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await failedDriver.commit(failedUtterance)
        try await healthyDriver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await healthyDriver.commit(healthyUtterance)
        #expect(await failedConnection.waitUntilSentMessageCount(3))
        #expect(await healthyConnection.waitUntilSentMessageCount(3))
        await failedConnection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        await healthyConnection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await failedConnection.waitUntilSentMessageCount(4))
        #expect(await healthyConnection.waitUntilSentMessageCount(4))

        await failedConnection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_failed"}}"#))
        await failedConnection.enqueue(.text(#"{"type":"response.output_audio.delta","response_id":"resp_failed","delta":"AQID"}"#))
        await healthyConnection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_healthy"}}"#))
        await healthyConnection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_healthy","delta":"healthy caption"}"#))
        await healthyConnection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_healthy","status":"completed"}}"#))
        #expect(await failedEvents.waitForCount(1))
        #expect(await healthyEvents.waitForCount(2))
        #expect(await failedEvents.snapshot() == [
            .failure(sourceAlias: "audio-1", generation: 7, .capabilityRejected),
        ])
        #expect(await healthyEvents.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: healthyUtterance.captionID,
                utteranceID: healthyUtterance.utteranceID,
                text: "healthy caption"
            ),
            completedEvent(for: healthyUtterance),
        ])

        await failedDriver.stop()
        await healthyDriver.stop()
        failedEventTask.cancel()
        healthyEventTask.cancel()
        #expect(await failedRecorder.outcome() == .succeeded)
        #expect(await healthyRecorder.outcome() == .succeeded)
        await failedTask.value
        await healthyTask.value
    }

    @Test func geminiTurnCompleteCorrectsFromTranscriptionAndDiscardsGeneratedAudio() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .geminiLive)
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"transcribed words"},"turnComplete":true,"modelTurn":{"parts":[{"inlineData":{"data":"private-generated-audio"}}]}}}"#))
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: utterance.captionID,
                utteranceID: utterance.utteranceID,
                text: "transcribed words"
            ),
            completedEvent(for: utterance),
        ])
        #expect(!(await events.snapshot().description.contains("private-generated-audio")))

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func geminiTurnCompleteDuringActivityEndSendIsDeferredUntilSendSucceeds() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "activityEnd")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(#"{"setupComplete":{}}"#))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        let (events, eventTask) = await recordEvents(from: driver)

        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("activityEnd"))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"turn left"},"turnComplete":true}}"#))
        await driver.waitForDeferredGeminiTerminalForTesting()
        #expect(await events.snapshot().isEmpty)

        await connection.releaseSuspendedSend()
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: utterance.captionID,
                utteranceID: utterance.utteranceID,
                text: "turn left"
            ),
            completedEvent(for: utterance),
        ])
        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
    }

    @Test func geminiInterruptedTurnWithTurnCompleteCannotCorrectDuringActivityEndSend() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "activityEnd")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(#"{"setupComplete":{}}"#))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("activityEnd"))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"cancelled words"},"interrupted":true,"turnComplete":true}}"#))
        await driver.waitForDeferredGeminiTerminalForTesting()
        #expect(await events.snapshot().isEmpty)

        await connection.releaseSuspendedSend()
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [completedEvent(for: utterance)])
        await driver.stop()
        eventTask.cancel()
    }

    @Test func geminiInterruptedTurnIgnoresLaterTurnCompleteDuringActivityEndSend() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "activityEnd")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(#"{"setupComplete":{}}"#))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        let (events, eventTask) = await recordEvents(from: driver)
        let utterance = makeUtterance(generation: 7, start: 90, end: 200)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(utterance)
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("activityEnd"))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"cancelled words"},"interrupted":true}}"#))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"late words"},"turnComplete":true}}"#))
        await driver.waitForDeferredGeminiTerminalForTesting()
        #expect(await events.snapshot().isEmpty)

        await connection.releaseSuspendedSend()
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [completedEvent(for: utterance)])
        await driver.stop()
        eventTask.cancel()
    }

    @Test func geminiStopDuringActivityEndSendDiscardsDeferredTurn() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "activityEnd")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(#"{"setupComplete":{}}"#))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        let (events, eventTask) = await recordEvents(from: driver)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("activityEnd"))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"must be discarded"},"turnComplete":true}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().isEmpty)

        await driver.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().isEmpty)
        eventTask.cancel()
    }

    @Test func geminiActivityEndSendFailureDiscardsDeferredTurn() async throws {
        let connection = FakeRealtimeWebSocketConnection(suspendSendType: "activityEnd")
        let connector = FakeRealtimeWebSocketConnector(profile: .geminiLive, connections: [connection])
        let driver = NativeRealtimeSessionDriver(
            settings: settings(profile: .geminiLive),
            credential: "synthetic-key",
            sourceRole: .microphone,
            connector: connector,
            setupTimeout: .seconds(1)
        )
        let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
        #expect(await connection.waitUntilSentMessageCount(1))
        await connection.enqueue(.text(#"{"setupComplete":{}}"#))
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
        let (events, eventTask) = await recordEvents(from: driver)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSuspendedMessageTypeStarted("activityEnd"))
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"must be discarded"},"turnComplete":true}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().isEmpty)

        await connection.failSuspendedSend()
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [
            .failure(sourceAlias: "audio-1", generation: 7, .connectionFailed),
        ])
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func textOnlyProvidersRejectResponsesWithoutCorrelationIDs() async throws {
        enum MissingIDCase {
            case created, textDelta, responseDone
        }

        for profile in [NativeRealtimeProfile.openAIMini, .xAIVoice, .qwenOmniFlash] {
            for missingIDCase in [MissingIDCase.created, .textDelta, .responseDone] {
                let (driver, connection, recorder, task) = await makeReadyDriver(profile: profile)
                let (events, eventTask) = await recordEvents(from: driver)
                let responseID = "resp_id_\(profile.provider.rawValue)"
                let deltaType = profile.provider == .qwen ? "response.text.delta" : "response.output_text.delta"
                try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
                try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
                #expect(await connection.waitUntilSentMessageCount(3))
                await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
                #expect(await connection.waitUntilSentMessageCount(4))

                switch missingIDCase {
                case .created:
                    await connection.enqueue(.text(#"{"type":"response.created","response":{}}"#))
                    await connection.enqueue(.text(#"{"type":"\#(deltaType)","delta":"unattributed text"}"#))
                    await connection.enqueue(.text(#"{"type":"response.done","response":{"status":"completed"}}"#))
                case .textDelta:
                    await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
                    await connection.enqueue(.text(#"{"type":"\#(deltaType)","delta":"unattributed text"}"#))
                case .responseDone:
                    await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
                    await connection.enqueue(.text(#"{"type":"\#(deltaType)","response_id":"\#(responseID)","delta":"text before unattributed completion"}"#))
                    await connection.enqueue(.text(#"{"type":"response.done","response":{"status":"completed"}}"#))
                }

                #expect(await events.waitForCount(1))
                #expect(await events.snapshot() == [
                    .failure(sourceAlias: "audio-1", generation: 7, .malformedResponse),
                ])
                await driver.stop()
                eventTask.cancel()
                #expect(await recorder.outcome() == .succeeded)
                await task.value
            }
        }
    }

    @Test func geminiGoAwayExpiresGenerationAndRejectsSameGenerationRestart() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .geminiLive)
        let (events, eventTask) = await recordEvents(from: driver)
        await connection.enqueue(.text(#"{"goAway":{"timeLeft":{"seconds":"12"}}}"#))
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [.expired(sourceAlias: "audio-1", generation: 7)])
        await expectFailure(.invalidConfiguration) {
            try await driver.start(sourceAlias: "audio-1", generation: 7)
        }

        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func commitWithoutAudioInIntervalIsRejected() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 900))
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])

        // A commit whose utterance metadata is invalid is also rejected before sending.
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(alias: "audio-2", generation: 7, start: 800, end: 1_000))
        }
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(generation: 7, start: 1_000, end: 900))
        }

        // The queued chunk survives the rejected commits.
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 1_000))
        #expect(await connection.waitUntilSentMessageCount(3))
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func mailboxOverflowFailsOnlyThatSourceAndClearsQueuedMedia() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        let (otherDriver, otherConnection, otherRecorder, otherTask) =
            await makeReadyDriver(profile: .openAIMini)
        var eventIterator = await driver.events().makeAsyncIterator()

        for index in 0..<128 {
            try await driver.sendAudioChunk(
                makeChunk(generation: 7, timestamp: UInt64(index + 1))
            )
        }
        await expectFailure(.backpressure) {
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 999))
        }
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-1", generation: 7, .backpressure))

        // The overflowing source's mailbox was cleared; nothing was sent.
        await expectFailure(.invalidConfiguration) {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 1_000))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])

        // The overflow does not affect a second source's driver.
        try await otherDriver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await otherDriver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        #expect(await otherConnection.waitUntilSentMessageCount(3))

        // The overflowing source can queue new audio after the failure.
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        #expect(await connection.waitUntilSentMessageCount(3))

        await driver.stop()
        await otherDriver.stop()
        #expect(await recorder.outcome() == .succeeded)
        #expect(await otherRecorder.outcome() == .succeeded)
        await task.value
        await otherTask.value
    }

    @Test func mailboxByteLimitOverflowEmitsBackpressure() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)
        var eventIterator = await driver.events().makeAsyncIterator()

        // 16 chunks of 32,000 bytes fill the 512,000-byte mailbox exactly.
        for index in 0..<16 {
            try await driver.sendAudioChunk(
                makeChunk(generation: 7, timestamp: UInt64(index + 1), bytes: 32_000)
            )
        }
        await expectFailure(.backpressure) {
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 999))
        }
        let event = await eventIterator.next()
        #expect(event == .failure(sourceAlias: "audio-1", generation: 7, .backpressure))
        #expect(await connection.sentMessageTypes() == ["session.update"])
        await driver.stop()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func geminiCommitSendsAudioAndBoundaryThenReturnsToReady() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .geminiLive)
        let (events, eventTask) = await recordEvents(from: driver)

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        let firstUtterance = makeUtterance(generation: 7, start: 0, end: 500)
        try await driver.commit(firstUtterance)
        #expect(await connection.waitUntilSentMessageCount(4))
        let types = await connection.sentMessageTypes()
        #expect(types == ["setup", "activityStart", "audio", "activityEnd"])
        await connection.enqueue(.text(#"{"serverContent":{"outputTranscription":{"text":"corrected words"},"turnComplete":true,"modelTurn":{"parts":[{"inlineData":{"data":"discard-this-audio"}}]}}}"#))
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: firstUtterance.captionID,
                utteranceID: "synthetic-utterance",
                text: "corrected words"
            ),
            completedEvent(for: firstUtterance),
        ])

        // The next Gemini utterance may begin after turnComplete.
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 600))
        try await driver.commit(makeUtterance(generation: 7, start: 501, end: 1_000))
        #expect(await connection.waitUntilSentMessageCount(7))
        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func stopClearsMailboxAndRejectsFurtherMedia() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .openAIMini)

        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        await driver.stop()

        await expectFailure(.capabilityRejected) {
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 200))
        }
        await expectFailure(.capabilityRejected) {
            try await driver.commit(makeUtterance(generation: 7, start: 0, end: 500))
        }
        #expect(await connection.sentMessageTypes() == ["session.update"])
        #expect(await recorder.waitForOutcome() == .succeeded)
        await task.value
    }
}

private enum StartOutcome: Equatable {
    case succeeded
    case failed(RealtimeFailureCode)
}

private actor RealtimeProviderEventRecorder {
    private var storedEvents: [RealtimeProviderEvent] = []

    func record(_ event: RealtimeProviderEvent) {
        storedEvents.append(event)
    }

    func snapshot() -> [RealtimeProviderEvent] { storedEvents }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if storedEvents.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return storedEvents.count >= count
    }
}

private func recordEvents(
    from driver: NativeRealtimeSessionDriver
) async -> (RealtimeProviderEventRecorder, Task<Void, Never>) {
    let recorder = RealtimeProviderEventRecorder()
    let stream = await driver.events()
    let task = Task {
        for await event in stream {
            await recorder.record(event)
        }
    }
    return (recorder, task)
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

private func makeReadyDriver(
    profile: NativeRealtimeProfile,
    videoEnabled: Bool = false
) async -> (
    NativeRealtimeSessionDriver,
    FakeRealtimeWebSocketConnection,
    StartOutcomeRecorder,
    Task<Void, Never>
) {
    let connection = FakeRealtimeWebSocketConnection()
    let connector = FakeRealtimeWebSocketConnector(profile: profile, connections: [connection])
    let driver = NativeRealtimeSessionDriver(
        settings: settings(profile: profile),
        credential: "synthetic-key",
        sourceRole: .applicationAudio,
        connector: connector,
        videoEnabled: videoEnabled,
        setupTimeout: .seconds(1)
    )
    let (recorder, task) = launchStart(driver, alias: "audio-1", generation: 7)
    _ = await connection.waitUntilSentMessageCount(1)
    await connection.enqueue(acknowledgement(for: profile))
    _ = await recorder.waitForOutcome()
    return (driver, connection, recorder, task)
}

private func makeChunk(
    alias: String = "audio-1",
    generation: Int,
    timestamp: UInt64,
    bytes: Int = 320,
    sampleRate: Int = 16_000
) -> RealtimeAudioChunk {
    RealtimeAudioChunk(
        sourceAlias: alias,
        generation: generation,
        capturedAtMonotonicNanoseconds: timestamp,
        pcm16LEData: Data(repeating: 0, count: bytes),
        sampleRate: sampleRate
    )
}

private func makeExactChunk(
    alias: String = "audio-1",
    generation: Int,
    start: UInt64,
    pcm16LEData: Data
) -> RealtimeAudioChunk {
    let frameCount = UInt64(pcm16LEData.count / 2)
    return RealtimeAudioChunk(
        sourceAlias: alias,
        generation: generation,
        capturedAtMonotonicNanoseconds: start,
        startMonotonicNanoseconds: start,
        endMonotonicNanoseconds: start + frameCount * 62_500,
        pcm16LEData: pcm16LEData,
        sampleRate: 16_000
    )
}

private func makeVideoFrame(
    timestamp: UInt64,
    marker: UInt8 = 0x01
) -> RealtimeVideoFrame {
    RealtimeVideoFrame(
        sourceAlias: "visual-composite",
        capturedAtMonotonicNanoseconds: timestamp,
        jpegData: Data([0xFF, 0xD8, marker, 0xFF, 0xD9])
    )
}

private func containsEncodedFrame(_ text: String, frame: RealtimeVideoFrame) -> Bool {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    if object["image"] as? String == frame.jpegData.base64EncodedString() { return true }
    guard let realtimeInput = object["realtimeInput"] as? [String: Any],
          let video = realtimeInput["video"] as? [String: Any] else { return false }
    return video["data"] as? String == frame.jpegData.base64EncodedString()
}

private func appendedPCM(in messages: [String]) -> [Data] {
    messages.compactMap { message in
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "input_audio_buffer.append",
              let encoded = object["audio"] as? String else {
            return nil
        }
        return Data(base64Encoded: encoded)
    }
}

private func makeUtterance(
    alias: String = "audio-1",
    generation: Int,
    start: UInt64,
    end: UInt64,
    requiresPreciseSampleCoverage: Bool = false
) -> RealtimeUtterance {
    RealtimeUtterance(
        sourceAlias: alias,
        generation: generation,
        captionID: UUID(),
        utteranceID: "synthetic-utterance",
        startMonotonicNanoseconds: start,
        endMonotonicNanoseconds: end,
        requiresPreciseSampleCoverage: requiresPreciseSampleCoverage
    )
}

private func completedEvent(for utterance: RealtimeUtterance) -> RealtimeProviderEvent {
    .utteranceCompleted(
        sourceAlias: utterance.sourceAlias,
        generation: utterance.generation,
        captionID: utterance.captionID,
        utteranceID: utterance.utteranceID
    )
}

private func expectFailure(
    _ expected: RealtimeFailureCode,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected) but the operation succeeded")
    } catch let code as RealtimeFailureCode {
        #expect(code == expected)
    } catch {
        Issue.record("Expected \(expected) but got a non-allowlisted error")
    }
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
    private let suspendSendTypes: Set<String>
    private let holdCloseInitially: Bool
    private var heldCloseReleased = false
    private var heldCloseWaiter: CheckedContinuation<Void, Never>?
    private var closeHasStarted = false
    private var messages: [RealtimeSocketMessage] = []
    private var sentMessages: [RealtimeSocketMessage] = []
    private var sentTypes: [String] = []
    private var receiveWaiter: CheckedContinuation<RealtimeSocketMessage, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var sendStarted = false
    private var suspendedSendTypeStarted: String?
    private var didSuspendConfiguredSendTypes: Set<String> = []
    private var closed = false
    private var closes = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        suspendSend: Bool = false,
        suspendSendType: String? = nil,
        suspendSendTypes: Set<String> = [],
        holdClose: Bool = false
    ) {
        self.suspendSend = suspendSend
        self.holdCloseInitially = holdClose
        var configuredTypes = suspendSendTypes
        if let suspendSendType { configuredTypes.insert(suspendSendType) }
        self.suspendSendTypes = configuredTypes
    }

    func send(_ message: RealtimeSocketMessage) async throws {
        guard !closed else { throw RealtimeTransportError.closed }
        sendStarted = true
        let messageType = Self.messageType(message)
        let boundarySendIsSuspended = suspendSendTypes.contains(messageType) &&
            !didSuspendConfiguredSendTypes.contains(messageType)
        if boundarySendIsSuspended { didSuspendConfiguredSendTypes.insert(messageType) }
        if boundarySendIsSuspended {
            // Model a frame that has reached the wire while its async send call
            // has not yet returned to the actor.
            sentMessages.append(message)
            sentTypes.append(messageType)
        }
        if suspendSend || boundarySendIsSuspended {
            suspendedSendTypeStarted = messageType
            try await withCheckedThrowingContinuation { sendWaiter = $0 }
        }
        guard !closed else { throw RealtimeTransportError.closed }
        if !boundarySendIsSuspended {
            sentMessages.append(message)
            sentTypes.append(messageType)
        }
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
        closeHasStarted = true
        if holdCloseInitially && !heldCloseReleased {
            await withCheckedContinuation { heldCloseWaiter = $0 }
        }
        guard !closed else { return }
        closed = true
        closes += 1
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
    func sentTextMessages() -> [String] {
        sentMessages.compactMap { message in
            guard case .text(let text) = message else { return nil }
            return text
        }
    }

    func waitUntilSentFrame(_ frame: RealtimeVideoFrame) async -> Bool {
        for _ in 0..<200 {
            if sentMessages.contains(where: { Self.containsFrame($0, frame: frame) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sentMessages.contains(where: { Self.containsFrame($0, frame: frame) })
    }
    func closeCount() -> Int { closes }

    func waitForClose() async {
        if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func waitUntilSendStarted() async -> Bool {
        for _ in 0..<200 {
            if sendStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sendStarted
    }

    func waitUntilSuspendedMessageTypeStarted(_ type: String) async -> Bool {
        for _ in 0..<200 {
            if suspendedSendTypeStarted == type { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return suspendedSendTypeStarted == type
    }

    func releaseSuspendedSend() {
        guard let sendWaiter else { return }
        self.sendWaiter = nil
        sendWaiter.resume()
    }

    func releaseHeldClose() {
        heldCloseReleased = true
        guard let waiter = heldCloseWaiter else { return }
        heldCloseWaiter = nil
        waiter.resume()
    }

    func waitUntilCloseStarted() async -> Bool {
        for _ in 0..<200 {
            if closeHasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return closeHasStarted
    }

    func failSuspendedSend() {
        guard let sendWaiter else { return }
        self.sendWaiter = nil
        sendWaiter.resume(throwing: RealtimeTransportError.closed)
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

    func waitUntilSentMessageType(_ type: String) async -> Bool {
        for _ in 0..<200 {
            if sentTypes.contains(type) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sentTypes.contains(type)
    }

    private static func messageType(_ message: RealtimeSocketMessage) -> String {
        guard case .text(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unknown"
        }
        if let type = object["type"] as? String { return type }
        if object["setup"] != nil { return "setup" }
        if let realtimeInput = object["realtimeInput"] as? [String: Any] {
            if realtimeInput["activityStart"] != nil { return "activityStart" }
            if realtimeInput["audio"] != nil { return "audio" }
            if realtimeInput["video"] != nil { return "video" }
            if realtimeInput["activityEnd"] != nil { return "activityEnd" }
        }
        return "unknown"
    }

    private static func containsFrame(_ message: RealtimeSocketMessage, frame: RealtimeVideoFrame) -> Bool {
        guard case .text(let text) = message else { return false }
        return containsEncodedFrame(text, frame: frame)
    }
}
