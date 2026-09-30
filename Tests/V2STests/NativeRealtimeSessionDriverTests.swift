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
        #expect(await connection.waitUntilSentMessageCount(4))
        #expect(await connection.sentMessageTypes() == [
            "session.update",
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
        ])

        // A second commit before the acknowledgement must fail without another boundary.
        await expectFailure(.capabilityRejected) {
            try await driver.commit(makeUtterance(generation: 7, start: 501, end: 1_000))
        }
        #expect(await connection.sentMessageTypes().count == 4)

        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(5))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_empty"}}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_empty","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(10))

        // The later chunk stayed queued for the next utterance.
        try await driver.commit(makeUtterance(generation: 7, start: 501, end: 1_000))
        #expect(await connection.waitUntilSentMessageCount(7))
        #expect(await connection.sentMessageTypes() == [
            "session.update",
            "input_audio_buffer.append",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
            "response.create",
            "input_audio_buffer.append",
            "input_audio_buffer.commit",
        ])

        await driver.stop()
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
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: captionID,
                utteranceID: "turn-42",
                text: "Where is the next station?"
            ),
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
        #expect(await events.waitForCount(1))

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
        #expect(await events.snapshot().count == 1)

        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_current"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_current","delta":"second caption"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_current","status":"completed"}}"#))
        #expect(await events.waitForCount(2))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: firstUtterance.captionID,
                utteranceID: firstUtterance.utteranceID,
                text: "first caption"
            ),
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: secondUtterance.captionID,
                utteranceID: secondUtterance.utteranceID,
                text: "second caption"
            ),
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
        ]
        for (index, reply) in replies.enumerated() {
            let timestamp = UInt64(100 + index * 200)
            let responseID = "resp_answer_\(index)"
            let sentCount = await connection.sentMessageTypes().count
            try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: timestamp))
            try await driver.commit(makeUtterance(
                generation: 7,
                start: timestamp - 10,
                end: timestamp + 100
            ))
            #expect(await connection.waitUntilSentMessageCount(sentCount + 2))
            await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
            #expect(await connection.waitUntilSentMessageCount(sentCount + 3))
            await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"\#(responseID)"}}"#))
            await connection.enqueue(.text(#"{"type":"response.text.delta","response_id":"\#(responseID)","delta":"\#(reply)"}"#))
            await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"\#(responseID)","status":"completed"}}"#))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await events.snapshot().isEmpty)

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
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
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_reply"}}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_reply","delta":"Hello! How can I help you today?"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_reply","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await events.snapshot().isEmpty)
        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
    }

    @Test func cancelledQwenResponseCannotCorrectCaption() async throws {
        let (driver, connection, recorder, task) = await makeReadyDriver(profile: .qwenOmniFlash)
        let (events, eventTask) = await recordEvents(from: driver)
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
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
        try await driver.sendAudioChunk(makeChunk(generation: 7, timestamp: 100))
        try await driver.commit(makeUtterance(generation: 7, start: 90, end: 200))
        #expect(await connection.waitUntilSentMessageCount(3))
        await connection.enqueue(.text(#"{"type":"input_audio_buffer.committed"}"#))
        #expect(await connection.waitUntilSentMessageCount(4))
        await connection.enqueue(.text(#"{"type":"response.created","response":{"id":"resp_long"}}"#))
        let firstHalf = String(repeating: "a", count: 5_000)
        let secondHalf = String(repeating: "b", count: 5_000)
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_long","delta":"\#(firstHalf)"}"#))
        await connection.enqueue(.text(#"{"type":"response.output_text.delta","response_id":"resp_long","delta":"\#(secondHalf)"}"#))
        await connection.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_long","status":"completed"}}"#))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await events.snapshot().isEmpty)

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
        #expect(await healthyEvents.waitForCount(1))
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
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot() == [
            .correctedText(
                sourceAlias: "audio-1",
                generation: 7,
                captionID: utterance.captionID,
                utteranceID: utterance.utteranceID,
                text: "transcribed words"
            ),
        ])
        #expect(!(await events.snapshot().description.contains("private-generated-audio")))

        await driver.stop()
        eventTask.cancel()
        #expect(await recorder.outcome() == .succeeded)
        await task.value
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
        #expect(await events.waitForCount(1))
        #expect(await events.snapshot().first == .correctedText(
            sourceAlias: "audio-1",
            generation: 7,
            captionID: firstUtterance.captionID,
            utteranceID: "synthetic-utterance",
            text: "corrected words"
        ))

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
    profile: NativeRealtimeProfile
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
        videoEnabled: false,
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

private func makeUtterance(
    alias: String = "audio-1",
    generation: Int,
    start: UInt64,
    end: UInt64
) -> RealtimeUtterance {
    RealtimeUtterance(
        sourceAlias: alias,
        generation: generation,
        captionID: UUID(),
        utteranceID: "synthetic-utterance",
        startMonotonicNanoseconds: start,
        endMonotonicNanoseconds: end
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
    private let suspendSendType: String?
    private var messages: [RealtimeSocketMessage] = []
    private var sentMessages: [RealtimeSocketMessage] = []
    private var sentTypes: [String] = []
    private var receiveWaiter: CheckedContinuation<RealtimeSocketMessage, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var sendStarted = false
    private var suspendedSendTypeStarted: String?
    private var closed = false
    private var closes = 0

    init(suspendSend: Bool = false, suspendSendType: String? = nil) {
        self.suspendSend = suspendSend
        self.suspendSendType = suspendSendType
    }

    func send(_ message: RealtimeSocketMessage) async throws {
        guard !closed else { throw RealtimeTransportError.closed }
        sendStarted = true
        let messageType = Self.messageType(message)
        let boundarySendIsSuspended = messageType == suspendSendType
        if boundarySendIsSuspended {
            // Model a frame that has reached the wire while its async send call
            // has not yet returned to the actor.
            sentMessages.append(message)
            sentTypes.append(messageType)
        }
        if suspendSend || messageType == suspendSendType {
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
    func sentTextMessages() -> [String] {
        sentMessages.compactMap { message in
            guard case .text(let text) = message else { return nil }
            return text
        }
    }
    func closeCount() -> Int { closes }

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
        if let realtimeInput = object["realtimeInput"] as? [String: Any] {
            if realtimeInput["activityStart"] != nil { return "activityStart" }
            if realtimeInput["audio"] != nil { return "audio" }
            if realtimeInput["activityEnd"] != nil { return "activityEnd" }
        }
        return "unknown"
    }
}
