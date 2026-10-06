import Foundation
import Testing
@testable import v2s

@Suite struct NativeRealtimeSessionCoordinatorTests {
    @Test func optedInCapturesGetIsolatedAliasesAndOnlyTheirOwnPCM() async throws {
        let backend = CoordinatorCredentialBackend(secret: "fake-secret")
        let bag = CoordinatorDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { settings, _, _ in
                let driver = CoordinatorFakeDriver(factoryEnabledSourceIDs: settings.enabledSourceIDs)
                bag.append(driver)
                return driver
            }
        )
        let first = makeCoordinatorCapture(sourceID: "private-device-id")
        let second = makeCoordinatorCapture(sourceID: "private-app-id")
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = [first.source.sourceID, second.source.sourceID]

        let started = await coordinator.start(captures: [first.source, second.source], settings: settings)
        #expect(started.count == 2)
        #expect(started.map(\.alias) == ["audio-1", "audio-2"])
        #expect(started[0].generation != started[1].generation)

        try offer([1, 0], to: first)
        try offer([2, 0], to: second)
        let drivers = bag.all()
        var factorySourceIDs: [[String]] = []
        for driver in drivers { factorySourceIDs.append(await driver.factorySettingsEnabledSources()) }
        #expect(factorySourceIDs.allSatisfy { $0.isEmpty })
        try await waitForCoordinatorCondition {
            var counts: [Int] = []
            for driver in drivers { counts.append(await driver.audioChunks().count) }
            return counts == [1, 1]
        }
        let firstChunks = await drivers[0].audioChunks()
        let secondChunks = await drivers[1].audioChunks()
        #expect(firstChunks == [RealtimeAudioChunk(
            sourceAlias: "audio-1",
            generation: started[0].generation,
            capturedAtMonotonicNanoseconds: 101,
            startMonotonicNanoseconds: 0,
            endMonotonicNanoseconds: 62_500,
            pcm16LEData: Data([1, 0]),
            sampleRate: 16_000
        )])
        #expect(secondChunks == [RealtimeAudioChunk(
            sourceAlias: "audio-2",
            generation: started[1].generation,
            capturedAtMonotonicNanoseconds: 202,
            startMonotonicNanoseconds: 0,
            endMonotonicNanoseconds: 62_500,
            pcm16LEData: Data([2, 0]),
            sampleRate: 16_000
        )])
        await coordinator.stop()
    }

    @Test func captionQueuedDuringCredentialLookupWaitsForExactSendAdmission() async throws {
        let backend = SuspendingCoordinatorCredentialBackend()
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendSendUntilStop: true)
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let caption = RealtimeAcceptedCaptionMetadata(
            sourceID: capture.source.sourceID,
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "utterance-1",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 2..<5
        )
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("credential lookup") {
                await backend.lookupCount() == 1
            }
            #expect(await coordinator.submitAcceptedCaption(caption) == .queued)
            try offer(
                [1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8, 0],
                to: capture,
                sampleInterval: 0..<8,
                captureTimestampNanoseconds: 17
            )
            await backend.releaseLookup(with: "fake-secret")
            let started = await startTask.value
            #expect(started.count == 1)
            guard let driver = bag.all().first else {
                throw CoordinatorFixtureError.offerRejected
            }
            try await requireCoordinatorCondition("held first audio send") {
                await driver.isSendSuspended()
            }
            #expect(await driver.committedUtterances().isEmpty)

            await driver.releaseSendSuccessfully()
            try await requireCoordinatorCondition("admitted caption commit") {
                await driver.committedUtterances().count == 1
            }
            let commits = await driver.committedUtterances()
            #expect(commits.count == 1)
            #expect(commits.first?.captionID == caption.captionID)
            #expect(commits.first?.utteranceID == caption.utteranceID)
            #expect(commits.first?.startMonotonicNanoseconds == 125_000)
            #expect(commits.first?.endMonotonicNanoseconds == 312_500)
            #expect(commits.first?.requiresPreciseSampleCoverage == true)
            await coordinator.stop()
        } catch {
            deferredError = error
        }
        await backend.releaseLookup(with: "fake-secret")
        for driver in bag.all() {
            await driver.releaseSendSuccessfully()
            await driver.releaseSuspendedStop()
        }
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func committedCaptionIsNotReportedLocalOnlyWhenAudioReaderFailsBeforeTerminal() async throws {
        let bag = CoordinatorDriverBag()
        let dispositions = CoordinatorCaptionDispositionBag()
        let events = CoordinatorCaptionEventBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setCaptionDispositionHandler { metadata, disposition in
            dispositions.append(metadata, disposition)
        }
        await coordinator.setCaptionEventHandler { events.append($0) }
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)
        guard let driver = bag.all().first, let active = started.first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        let caption = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "committed-without-terminal",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<1
        )
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("event reader subscription before correction") {
                await driver.hasEventSubscriber()
            }
            #expect(await coordinator.submitAcceptedCaption(caption) == .queued)
            try offer([1, 0], to: capture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("caption commit succeeds before terminal") {
                let commits = await driver.committedUtterances()
                return commits.count == 1 && commits.first?.captionID == caption.captionID
            }
            await driver.yieldEvent(.correctedText(
                sourceAlias: active.alias,
                generation: active.generation,
                captionID: caption.captionID,
                utteranceID: caption.utteranceID,
                text: "committed correction"
            ))
            try await requireCoordinatorCondition("correction proves commit success") {
                events.all().count == 1
            }

            capture.source.input.finish(error: .invalidAudioChunk)
            try await requireCoordinatorCondition("audio failure tears down the source") {
                failures.all().count == 1
            }
            #expect(failures.all().first?.0 == "source-a")
            #expect(failures.all().first?.1 == .malformedResponse)
            #expect(events.all().map(\.kind) == [.correctedText("committed correction")])
            #expect(dispositions.all().isEmpty)
        } catch {
            deferredError = error
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func knownPreInputAndAudioGapsAreRejectedBeforeCaptionEndArrives() async throws {
        let bag = CoordinatorDriverBag()
        let dispositions = CoordinatorCaptionDispositionBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["pre-input", "gap"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionDispositionHandler { metadata, disposition in
            dispositions.append(metadata, disposition)
        }
        let preInput = makeCoordinatorCapture(sourceID: "pre-input")
        let gap = makeCoordinatorCapture(sourceID: "gap")
        let preInputCaption = RealtimeAcceptedCaptionMetadata(
            sourceID: "pre-input",
            sourceToken: preInput.source.input.sourceToken,
            captureGeneration: preInput.source.input.generation,
            captionID: UUID(),
            utteranceID: "pre-input-utterance",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<8
        )
        let gapCaption = RealtimeAcceptedCaptionMetadata(
            sourceID: "gap",
            sourceToken: gap.source.input.sourceToken,
            captureGeneration: gap.source.input.generation,
            captionID: UUID(),
            utteranceID: "gap-utterance",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 1..<7
        )
        var deferredError: Error?
        do {
            let started = await coordinator.start(
                captures: [preInput.source, gap.source],
                settings: settings
            )
            #expect(started.count == 2)
            #expect(await coordinator.submitAcceptedCaption(preInputCaption) == .queued)
            #expect(await coordinator.submitAcceptedCaption(gapCaption) == .queued)
            try offer([1, 0], to: preInput, sampleInterval: 5..<6, captureTimestampNanoseconds: 19)
            try offer([2, 0, 3, 0], to: gap, sampleInterval: 0..<2, captureTimestampNanoseconds: 20)
            try offer([4, 0, 5, 0], to: gap, sampleInterval: 4..<6, captureTimestampNanoseconds: 23)
            try await requireCoordinatorCondition("known uncovered caption spans") {
                dispositions.all().count == 2
            }
            let observed = dispositions.all()
            #expect(observed.contains(where: {
                $0.metadata.captionID == preInputCaption.captionID
                    && $0.disposition == .localOnly(.missingAudioCoverage)
            }))
            #expect(observed.contains(where: {
                $0.metadata.captionID == gapCaption.captionID
                    && $0.disposition == .localOnly(.missingAudioCoverage)
            }))
            #expect(bag.all().count == 2)
            for driver in bag.all() {
                #expect(await driver.committedUtterances().isEmpty)
            }
            await coordinator.stop()
        } catch {
            deferredError = error
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func contiguousReaderLagWaitsForTheRemainingAudioSamples() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("reader-lag source starts") {
                started.count == 1 && bag.all().count == 1
            }
            let driver = bag.all()[0]
            let caption = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: capture.source.input.sourceToken,
                captureGeneration: capture.source.input.generation,
                captionID: UUID(),
                utteranceID: "reader-lag-span",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<4
            )
            #expect(await coordinator.submitAcceptedCaption(caption) == .queued)
            try offer([1, 0, 2, 0], to: capture, sampleInterval: 0..<2)
            try await requireCoordinatorCondition("first half is admitted while caption still waits") {
                let ranges = await coordinator.admittedAudioRangeCountForTesting(sourceID: "source-a")
                let chunks = await driver.audioChunks()
                return ranges == 1 && chunks.count == 1
            }
            #expect(await driver.commitInvocationCount() == 0)
            #expect(await driver.committedUtterances().isEmpty)

            try offer([3, 0, 4, 0], to: capture, sampleInterval: 2..<4)
            try await requireCoordinatorCondition("remaining adjacent samples complete coverage") {
                let attempts = await driver.commitInvocationCount()
                let commits = await driver.committedUtterances()
                return attempts == 1 && commits.count == 1
            }
            let committed = await driver.committedUtterances()[0]
            #expect(committed.captionID == caption.captionID)
            #expect(committed.utteranceID == caption.utteranceID)
            #expect(committed.startMonotonicNanoseconds == 0)
            #expect(committed.endMonotonicNanoseconds == 250_000)
            #expect(committed.requiresPreciseSampleCoverage)
            #expect(await driver.commitInvocationCount() == 1)
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseSendSuccessfully()
            await driver.releaseCommitSuccessfully()
            await driver.releaseSuspendedStop()
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func captionEventsRequireExactIdentityAndOnlyExactTerminalReleasesNextCaption() async throws {
        let bag = CoordinatorDriverBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)
        #expect(started.count == 1)
        guard let driver = bag.all().first, let active = started.first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }

        let first = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "utterance-first",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<2
        )
        let second = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "utterance-second",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 2..<4
        )
        var deferredError: Error?
        do {
            #expect(await coordinator.submitAcceptedCaption(first) == .queued)
            #expect(await coordinator.submitAcceptedCaption(second) == .queued)
            try offer([1, 0, 2, 0, 3, 0, 4, 0], to: capture, sampleInterval: 0..<4)
            try await requireCoordinatorCondition("first caption commit and event reader") {
                let invocations = await driver.commitInvocationCount()
                let commits = await driver.committedUtterances()
                let hasSubscriber = await driver.hasEventSubscriber()
                return invocations == 1 && commits.count == 1 && hasSubscriber
            }

            let alias = active.alias
            let generation = active.generation
            await driver.yieldEvent(.correctedText(
                sourceAlias: "wrong-alias",
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "wrong alias"
            ))
            await driver.yieldEvent(.correctedText(
                sourceAlias: alias,
                generation: generation + 1,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "wrong generation"
            ))
            await driver.yieldEvent(.correctedText(
                sourceAlias: alias,
                generation: generation,
                captionID: UUID(),
                utteranceID: first.utteranceID,
                text: "wrong caption"
            ))
            await driver.yieldEvent(.correctedText(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: "wrong-utterance",
                text: "wrong utterance"
            ))
            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: "wrong-alias",
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: alias,
                generation: generation + 1,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: alias,
                generation: generation,
                captionID: UUID(),
                utteranceID: first.utteranceID
            ))
            await driver.yieldEvent(.correctedText(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "corrected first"
            ))
            try await requireCoordinatorCondition("exact correction delivery after stale events") {
                events.all().count == 1
            }
            let corrected = events.all().first
            #expect(corrected?.sourceID == first.sourceID)
            #expect(corrected?.sourceToken == first.sourceToken)
            #expect(corrected?.captureGeneration == first.captureGeneration)
            #expect(corrected?.sourceAlias == alias)
            #expect(corrected?.driverGeneration == generation)
            #expect(corrected?.captionID == first.captionID)
            #expect(corrected?.utteranceID == first.utteranceID)
            #expect(corrected?.sourceLanguageID == first.sourceLanguageID)
            #expect(corrected?.targetLanguageID == first.targetLanguageID)
            #expect(corrected?.kind == .correctedText("corrected first"))
            #expect(await driver.commitInvocationCount() == 1)
            #expect(await driver.committedUtterances().count == 1)

            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: "wrong-utterance"
            ))
            await driver.yieldEvent(.suggestion(
                sourceAlias: alias,
                generation: generation,
                text: "suggestion does not release"
            ))
            try await requireCoordinatorCondition("suggestion delivery without releasing first caption") {
                events.all().count == 2
            }
            #expect(events.all().last?.kind == .suggestion("suggestion does not release"))
            #expect(await driver.commitInvocationCount() == 1)

            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            try await requireCoordinatorCondition("exact terminal advances second caption") {
                let invocations = await driver.commitInvocationCount()
                let commits = await driver.committedUtterances()
                return invocations == 2 && commits.count == 2
            }
            let commits = await driver.committedUtterances()
            #expect(commits.map(\.captionID) == [first.captionID, second.captionID])
            #expect(commits.map(\.utteranceID) == [first.utteranceID, second.utteranceID])
            #expect(commits.map(\.startMonotonicNanoseconds) == [0, 125_000])
            #expect(commits.map(\.endMonotonicNanoseconds) == [125_000, 250_000])
            #expect(events.all().last?.kind == .utteranceCompleted)
        } catch {
            deferredError = error
        }
        await driver.releaseCommitSuccessfully()
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func terminalReceivedDuringHeldCommitWaitsForCommitSuccessBeforeDeliveryAndRelease() async throws {
        let bag = CoordinatorDriverBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendCommitUntilReleased: true)
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)
        #expect(started.count == 1)
        guard let driver = bag.all().first, let active = started.first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        let first = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "held-first",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<2
        )
        let second = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: capture.source.input.sourceToken,
            captureGeneration: capture.source.input.generation,
            captionID: UUID(),
            utteranceID: "held-second",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 2..<4
        )
        var deferredError: Error?
        do {
            #expect(await coordinator.submitAcceptedCaption(first) == .queued)
            #expect(await coordinator.submitAcceptedCaption(second) == .queued)
            try offer([1, 0, 2, 0, 3, 0, 4, 0], to: capture, sampleInterval: 0..<4)
            try await requireCoordinatorCondition("held first commit and subscribed event reader") {
                let invocations = await driver.commitInvocationCount()
                let held = await driver.isCommitSuspended()
                let subscribed = await driver.hasEventSubscriber()
                return invocations == 1 && held && subscribed
            }
            await driver.yieldEvent(.correctedText(
                sourceAlias: active.alias,
                generation: active.generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "held correction"
            ))
            await driver.yieldEvent(.utteranceCompleted(
                sourceAlias: active.alias,
                generation: active.generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            try await requireCoordinatorCondition("both events stashed behind held commit") {
                await coordinator.stashedCaptionEventsForTesting(
                    sourceID: "source-a",
                    captionID: first.captionID
                ) == 2
            }
            #expect(events.all().isEmpty)
            #expect(await driver.commitInvocationCount() == 1)
            #expect(await driver.committedUtterances().isEmpty)

            await driver.releaseCommitSuccessfully()
            try await requireCoordinatorCondition("commit success releases stashed events and next caption") {
                let invocations = await driver.commitInvocationCount()
                let commits = await driver.committedUtterances()
                return events.all().count == 2 && invocations == 2 && commits.count == 2
            }
            let delivered = events.all()
            #expect(delivered.map(\.captionID) == [first.captionID, first.captionID])
            #expect(delivered.map(\.utteranceID) == [first.utteranceID, first.utteranceID])
            #expect(delivered.map(\.kind) == [.correctedText("held correction"), .utteranceCompleted])
            #expect(await driver.committedUtterances().map(\.captionID) == [first.captionID, second.captionID])
        } catch {
            deferredError = error
        }
        await driver.releaseCommitSuccessfully()
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func failedHeldCommitDropsStashedEventsAndKeepsSiblingSourceRunning() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendCommitUntilReleased: bag.all().isEmpty)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let secondCapture = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(
            captures: [firstCapture.source, secondCapture.source],
            settings: settings
        )
        #expect(started.map(\.sourceID) == ["source-a", "source-b"])
        guard bag.all().count == 2, let firstStarted = started.first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        let failedDriver = bag.all()[0]
        let healthyDriver = bag.all()[1]
        let first = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: firstCapture.source.input.sourceToken,
            captureGeneration: firstCapture.source.input.generation,
            captionID: UUID(),
            utteranceID: "failed-commit-utterance",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<2
        )
        let sibling = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-b",
            sourceToken: secondCapture.source.input.sourceToken,
            captureGeneration: secondCapture.source.input.generation,
            captionID: UUID(),
            utteranceID: "sibling-utterance",
            sourceLanguageID: "yue",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<2
        )
        var deferredError: Error?
        do {
            #expect(await coordinator.submitAcceptedCaption(first) == .queued)
            #expect(await coordinator.submitAcceptedCaption(sibling) == .queued)
            try offer([1, 0, 2, 0], to: firstCapture, sampleInterval: 0..<2)
            try offer([3, 0, 4, 0], to: secondCapture, sampleInterval: 0..<2)
            try await requireCoordinatorCondition("source-a held commit and both event readers") {
                let firstHeld = await failedDriver.isCommitSuspended()
                let firstSubscribed = await failedDriver.hasEventSubscriber()
                let secondCommits = await healthyDriver.committedUtterances()
                let secondSubscribed = await healthyDriver.hasEventSubscriber()
                return firstHeld && firstSubscribed && secondCommits.count == 1 && secondSubscribed
            }
            await failedDriver.yieldEvent(.correctedText(
                sourceAlias: firstStarted.alias,
                generation: firstStarted.generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "must be dropped"
            ))
            await failedDriver.yieldEvent(.utteranceCompleted(
                sourceAlias: firstStarted.alias,
                generation: firstStarted.generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            try await requireCoordinatorCondition("failed source stashes early events") {
                await coordinator.stashedCaptionEventsForTesting(
                    sourceID: "source-a",
                    captionID: first.captionID
                ) == 2
            }
            #expect(events.all().isEmpty)

            await failedDriver.releaseCommitFailure(.connectionFailed)
            try await requireCoordinatorCondition("failed source isolates after commit error") {
                let active = await coordinator.activeSourceIDs()
                let seenFailures = failures.all()
                return active == ["source-b"]
                    && seenFailures.count == 1
                    && seenFailures.first?.0 == "source-a"
                    && seenFailures.first?.1 == .connectionFailed
            }
            #expect(events.all().isEmpty)
            #expect(await failedDriver.committedUtterances().isEmpty)
            try offer([5, 0], to: secondCapture, sampleInterval: 2..<3)
            try await requireCoordinatorCondition("sibling keeps streaming after source-a commit failure") {
                await healthyDriver.audioChunks().count == 2
            }
            #expect(await coordinator.activeSourceIDs() == ["source-b"])
        } catch {
            deferredError = error
        }
        await failedDriver.releaseCommitFailure(.connectionFailed)
        await failedDriver.releaseCommitSuccessfully()
        await healthyDriver.releaseCommitSuccessfully()
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func ninthEarlyEventBackpressuresOnlyItsSourceAndDropsStashedCallbacks() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let isFirst = bag.all().isEmpty
                let driver = CoordinatorFakeDriver(
                    suspendCommitUntilReleased: isFirst,
                    suspendStopUntilReleased: isFirst
                )
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(
            captures: [firstCapture.source, siblingCapture.source],
            settings: settings
        )
        var deferredError: Error?
        do {
            guard started.count == 2, bag.all().count == 2 else {
                throw CoordinatorFixtureError.offerRejected
            }
            let firstStarted = started[0]
            let failingDriver = bag.all()[0]
            let siblingDriver = bag.all()[1]
            let first = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: firstCapture.source.input.sourceToken,
                captureGeneration: firstCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "event-overflow-first",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<1
            )
            try await requireCoordinatorCondition("both event streams subscribe before overflow") {
                let firstSubscribed = await failingDriver.hasEventSubscriber()
                let siblingSubscribed = await siblingDriver.hasEventSubscriber()
                return firstSubscribed && siblingSubscribed
            }
            #expect(await coordinator.submitAcceptedCaption(first) == .queued)
            try offer([1, 0], to: firstCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("source-a commit is held while events arrive") {
                await failingDriver.isCommitSuspended()
            }

            for index in 0..<8 {
                if index.isMultiple(of: 2) {
                    await failingDriver.yieldEvent(.correctedText(
                        sourceAlias: firstStarted.alias,
                        generation: firstStarted.generation,
                        captionID: first.captionID,
                        utteranceID: first.utteranceID,
                        text: "held correction \(index)"
                    ))
                } else {
                    await failingDriver.yieldEvent(.suggestion(
                        sourceAlias: firstStarted.alias,
                        generation: firstStarted.generation,
                        text: "held suggestion \(index)"
                    ))
                }
            }
            try await requireCoordinatorCondition("exactly eight events are stashed") {
                await coordinator.stashedCaptionEventsForTesting(
                    sourceID: "source-a",
                    captionID: first.captionID
                ) == 8
            }
            await failingDriver.yieldEvent(.suggestion(
                sourceAlias: firstStarted.alias,
                generation: firstStarted.generation,
                text: "ninth event exceeds bounded stash"
            ))
            try await requireCoordinatorCondition("ninth event revokes and holds source-a stop") {
                let active = await coordinator.activeSourceIDs()
                let stopped = await failingDriver.isStopSuspended()
                let seenFailures = failures.all()
                return active == ["source-b"]
                    && stopped
                    && seenFailures.count == 1
                    && seenFailures.first?.0 == "source-a"
                    && seenFailures.first?.1 == .backpressure
            }
            #expect(events.all().isEmpty)

            let sibling = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-b",
                sourceToken: siblingCapture.source.input.sourceToken,
                captureGeneration: siblingCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "sibling-after-event-overflow",
                sourceLanguageID: "yue",
                targetLanguageID: "en",
                sampleInterval: 0..<1
            )
            #expect(await coordinator.submitAcceptedCaption(sibling) == .queued)
            try offer([2, 0], to: siblingCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("sibling continues during source-a event backpressure") {
                let commits = await siblingDriver.committedUtterances()
                return commits.count == 1 && commits.first?.captionID == sibling.captionID
            }
            #expect(await coordinator.activeSourceIDs() == ["source-b"])
            #expect(events.all().isEmpty)
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseSendSuccessfully()
            await driver.releaseCommitSuccessfully()
            await driver.releaseSuspendedStop()
        }
        await coordinator.stop()
        #expect(events.all().isEmpty)
        if let deferredError { throw deferredError }
    }

    @Test func acceptedCaptionMetadataRejectsMissingInvalidDuplicateAndOutOfOrderIdentity() async {
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in CoordinatorFakeDriver() }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [capture.source], settings: settings)

        func metadata(
            sourceID: String = "source-a",
            sourceToken: UUID? = nil,
            captureGeneration: UInt64? = nil,
            captionID: UUID = UUID(),
            utteranceID: String = "accepted-utterance",
            sourceLanguageID: String = "en",
            interval: Range<Int64>? = 10..<12
        ) -> RealtimeAcceptedCaptionMetadata {
            RealtimeAcceptedCaptionMetadata(
                sourceID: sourceID,
                sourceToken: sourceToken ?? capture.source.input.sourceToken,
                captureGeneration: captureGeneration ?? capture.source.input.generation,
                captionID: captionID,
                utteranceID: utteranceID,
                sourceLanguageID: sourceLanguageID,
                targetLanguageID: "zh-Hans",
                sampleInterval: interval
            )
        }

        let firstID = UUID()
        let first = metadata(captionID: firstID, utteranceID: "ordered-first")
        #expect(await coordinator.submitAcceptedCaption(metadata(interval: nil)) == .localOnly(.missingProvenance))
        #expect(await coordinator.submitAcceptedCaption(metadata(sourceID: "source\nA")) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(sourceLanguageID: "")) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(utteranceID: String(repeating: "x", count: 129))) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(interval: -1..<1)) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(interval: 4..<4)) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(
            interval: (Int64.max - 1)..<Int64.max
        )) == .localOnly(.invalidMetadata))
        #expect(await coordinator.submitAcceptedCaption(metadata(sourceToken: UUID())) == .localOnly(.unavailableSource))
        #expect(await coordinator.submitAcceptedCaption(metadata(
            captureGeneration: capture.source.input.generation &+ 1
        )) == .localOnly(.unavailableSource))

        #expect(await coordinator.submitAcceptedCaption(first) == .queued)
        #expect(await coordinator.submitAcceptedCaption(metadata(
            captionID: firstID,
            utteranceID: "duplicate-caption",
            interval: 12..<14
        )) == .localOnly(.duplicateIdentity))
        #expect(await coordinator.submitAcceptedCaption(metadata(
            captionID: UUID(),
            utteranceID: first.utteranceID,
            interval: 12..<14
        )) == .localOnly(.duplicateIdentity))
        #expect(await coordinator.submitAcceptedCaption(metadata(
            captionID: UUID(),
            utteranceID: "out-of-order",
            interval: 9..<10
        )) == .localOnly(.outOfOrderInterval))
        await coordinator.stop()
    }

    @Test func perSourceCaptionQueueLimitIsEightAndOverflowLeavesSiblingRunning() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(
            captures: [firstCapture.source, siblingCapture.source],
            settings: settings
        )
        #expect(started.map(\.sourceID) == ["source-a", "source-b"])
        guard started.count == 2, bag.all().count == 2 else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        var deferredError: Error?
        do {
            for index in 0..<8 {
                let metadata = RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-a",
                    sourceToken: firstCapture.source.input.sourceToken,
                    captureGeneration: firstCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "queued-\(index)",
                    sourceLanguageID: "en",
                    targetLanguageID: "zh-Hans",
                    sampleInterval: Int64(index)..<Int64(index + 1)
                )
                #expect(await coordinator.submitAcceptedCaption(metadata) == .queued)
            }
            let rejected = await coordinator.submitAcceptedCaption(RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: firstCapture.source.input.sourceToken,
                captureGeneration: firstCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "queued-overflow",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 8..<9
            ))
            #expect(rejected == .localOnly(.backpressure))
            try await requireCoordinatorCondition("caption queue overflow isolates source-a") {
                let active = await coordinator.activeSourceIDs()
                let seenFailures = failures.all()
                return active == ["source-b"]
                    && seenFailures.count == 1
                    && seenFailures.first?.0 == "source-a"
                    && seenFailures.first?.1 == .backpressure
            }

            #expect(await coordinator.submitAcceptedCaption(RealtimeAcceptedCaptionMetadata(
                sourceID: "source-b",
                sourceToken: siblingCapture.source.input.sourceToken,
                captureGeneration: siblingCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "sibling-after-overflow",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<1
            )) == .queued)
            try offer([9, 0], to: siblingCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("sibling caption commits after queue overflow") {
                await bag.all()[1].committedUtterances().count == 1
            }
            #expect(await bag.all()[0].committedUtterances().isEmpty)
            #expect(await bag.all()[1].committedUtterances().first?.utteranceID == "sibling-after-overflow")
        } catch {
            deferredError = error
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func audioCoverageLedgerCapsAt128DisjointRangesAndBackpressuresOnlyThatSource() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 512)
        let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(
            captures: [firstCapture.source, siblingCapture.source],
            settings: settings
        )
        #expect(started.map(\.sourceID) == ["source-a", "source-b"])
        guard started.count == 2, bag.all().count == 2 else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        let firstDriver = bag.all()[0]
        let siblingDriver = bag.all()[1]
        var deferredError: Error?
        do {
            for index in 0..<128 {
                let lower = Int64(index * 2)
                let upper = lower + 1
                try offer(
                    [1, 0],
                    to: firstCapture,
                    sampleInterval: lower..<upper,
                    captureTimestampNanoseconds: UInt64(index + 1)
                )
                let expectedCount = index + 1
                try await requireCoordinatorCondition("admitted disjoint audio range \(expectedCount)") {
                    let chunks = await firstDriver.audioChunks()
                    let ranges = await coordinator.admittedAudioRangeCountForTesting(sourceID: "source-a")
                    return chunks.count == expectedCount && ranges == expectedCount
                }
            }

            let overflowLower: Int64 = 256
            try offer(
                [1, 0],
                to: firstCapture,
                sampleInterval: overflowLower..<(overflowLower + 1),
                captureTimestampNanoseconds: 129
            )
            try await requireCoordinatorCondition("129th disjoint range isolates source-a") {
                let active = await coordinator.activeSourceIDs()
                let seenFailures = failures.all()
                return active == ["source-b"]
                    && seenFailures.count == 1
                    && seenFailures.first?.0 == "source-a"
                    && seenFailures.first?.1 == .backpressure
            }
            #expect(await firstDriver.audioChunks().count == 129)

            try offer([2, 0], to: siblingCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("sibling remains usable after ledger overflow") {
                await siblingDriver.audioChunks().count == 1
            }
            #expect(await coordinator.activeSourceIDs() == ["source-b"])
        } catch {
            deferredError = error
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func noOptedInCaptureDoesNotLoadCredentialOrCreateDriver() async {
        let backend = CoordinatorCredentialBackend(secret: "fake-secret")
        let bag = CoordinatorDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        let capture = makeCoordinatorCapture(sourceID: "not-opted-in")

        let started = await coordinator.start(captures: [capture.source], settings: settings)

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await backend.lookupCount() == 0)
        await coordinator.stop()
    }

    @Test func cancellingWhileCredentialLookupIsSuspendedDoesNotStartDrivers() async throws {
        let backend = SuspendingCoordinatorCredentialBackend()
        let bag = CoordinatorDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { await backend.lookupCount() == 1 }

        startTask.cancel()
        await backend.releaseLookup(with: "fake-secret")
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func inputFinishedDuringCredentialLookupDoesNotStartDriver() async throws {
        let backend = SuspendingCoordinatorCredentialBackend()
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { await backend.lookupCount() == 1 }

        capture.source.input.finish()
        await backend.releaseLookup(with: "fake-secret")
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
    }

    @Test func offerOverflowDuringCredentialLookupStopsBeforeCreatingDriver() async throws {
        let backend = SuspendingCoordinatorCredentialBackend()
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 1)
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { await backend.lookupCount() == 1 }

        try offer([1, 0], to: capture)
        #expect(offerResult([2, 0], to: capture) == .backpressureExceeded)
        try await waitForCoordinatorCondition { failures.all().count == 1 }
        #expect(bag.all().isEmpty)
        await backend.releaseLookup(with: "fake-secret")
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .backpressure)
    }

    @Test func cancellingReservedStartupSuppressesQueuedInputFailureAfterObserverHop() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let inputGate = CoordinatorReleaseGate()
        let cleanupGate = CoordinatorReleaseGate()
        let inputDidFinishReturned = CoordinatorTestSignal()
        let startCompleted = CoordinatorCompletionFlag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setInputDidFinishTestingHooks(
            before: { await inputGate.suspend() },
            after: { inputDidFinishReturned.signal() }
        )
        await coordinator.setBeforeCancellationCleanupForTesting {
            await cleanupGate.suspend()
        }
        let capture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 1)
        let startTask = Task {
            let result = await coordinator.start(captures: [capture.source], settings: settings)
            await startCompleted.markComplete()
            return result
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("reserved driver creation") { bag.all().count == 1 }
            guard let driver = bag.all().first else { throw CoordinatorFixtureError.offerRejected }
            try await requireCoordinatorCondition("reserved driver start suspension") {
                let starts = await driver.startInvocationCount()
                let suspended = await driver.isStartSuspended()
                return starts == 1 && suspended
            }
            try offer([1, 0], to: capture)
            #expect(offerResult([2, 0], to: capture) == .backpressureExceeded)
            try await requireCoordinatorCondition("input observer gate") { await inputGate.hasSuspended() }

            startTask.cancel()
            try await requireCoordinatorCondition("startup cleanup gate") { await cleanupGate.hasSuspended() }
            #expect(capture.source.input.terminationError == .backpressureExceeded)
            await inputGate.resume()
            try await requireCoordinatorCondition("input observer actor return") { inputDidFinishReturned.isSignaled() }
            #expect(failures.all().isEmpty)
            #expect(await startCompleted.hasCompleted() == false)

            await driver.releaseStartSuccessfully()
            await cleanupGate.resume()
            _ = await startTask.value
            #expect(failures.all().isEmpty)
        } catch {
            deferredError = error
        }
        await inputGate.resume()
        await cleanupGate.resume()
        await coordinator.setInputDidFinishTestingHooks(before: nil, after: nil)
        await coordinator.setBeforeCancellationCleanupForTesting(nil)
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSendSuccessfully()
            await driver.releaseSuspendedStop()
        }
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func cancellingReplacementDuringPriorStopSuppressesQueuedInputFailure() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let inputGate = CoordinatorReleaseGate()
        let inputDidFinishReturned = CoordinatorTestSignal()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStopUntilReleased: bag.all().isEmpty)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let originalCapture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [originalCapture.source], settings: settings)
        guard let originalDriver = bag.all().first else { throw CoordinatorFixtureError.offerRejected }
        await coordinator.setInputDidFinishTestingHooks(
            before: { await inputGate.suspend() },
            after: { inputDidFinishReturned.signal() }
        )
        let replacementCapture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 1)
        let replacementTask = Task {
            await coordinator.start(captures: [replacementCapture.source], settings: settings)
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("prior driver stop suspension") { await originalDriver.isStopSuspended() }
            try await requireCoordinatorCondition("replacement startup publication") {
                await coordinator.startupSourceIDsForTesting() == ["source-a"]
            }
            try offer([1, 0], to: replacementCapture)
            #expect(offerResult([2, 0], to: replacementCapture) == .backpressureExceeded)
            try await requireCoordinatorCondition("input observer gate") { await inputGate.hasSuspended() }

            replacementTask.cancel()
            await inputGate.resume()
            try await requireCoordinatorCondition("input observer actor return") { inputDidFinishReturned.isSignaled() }
            #expect(replacementCapture.source.input.terminationError == .backpressureExceeded)
            #expect(failures.all().isEmpty)
            #expect(replacementTask.isCancelled)
            #expect(await coordinator.activeSourceIDs().isEmpty)

            await originalDriver.releaseSuspendedStop()
            _ = await replacementTask.value
            #expect(failures.all().isEmpty)
        } catch {
            deferredError = error
        }
        await inputGate.resume()
        await originalDriver.releaseSuspendedStop()
        await coordinator.setInputDidFinishTestingHooks(before: nil, after: nil)
        _ = await replacementTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func cancellingCredentialWaitSuppressesInputFailureWithoutPendingDriver() async throws {
        let backend = SuspendingCoordinatorCredentialBackend()
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let inputGate = CoordinatorReleaseGate()
        let cleanupGate = CoordinatorReleaseGate()
        let inputDidFinishReturned = CoordinatorTestSignal()
        let startCompleted = CoordinatorCompletionFlag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: backend),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setInputDidFinishTestingHooks(
            before: { await inputGate.suspend() },
            after: { inputDidFinishReturned.signal() }
        )
        await coordinator.setBeforeCancellationCleanupForTesting {
            await cleanupGate.suspend()
        }
        let capture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 1)
        let startTask = Task {
            let result = await coordinator.start(captures: [capture.source], settings: settings)
            await startCompleted.markComplete()
            return result
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("credential lookup start") { await backend.lookupCount() == 1 }
            try offer([1, 0], to: capture)
            #expect(offerResult([2, 0], to: capture) == .backpressureExceeded)
            try await requireCoordinatorCondition("input observer gate") { await inputGate.hasSuspended() }

            startTask.cancel()
            try await requireCoordinatorCondition("credential cleanup gate") { await cleanupGate.hasSuspended() }
            #expect(capture.source.input.terminationError == .backpressureExceeded)
            await inputGate.resume()
            try await requireCoordinatorCondition("input observer actor return") { inputDidFinishReturned.isSignaled() }
            #expect(failures.all().isEmpty)
            #expect(bag.all().isEmpty)
            #expect(await startCompleted.hasCompleted() == false)

            await backend.releaseLookup(with: "fake-secret")
            await cleanupGate.resume()
            let started = await startTask.value
            #expect(started.isEmpty)
            #expect(failures.all().isEmpty)
            #expect(bag.all().isEmpty)
        } catch {
            deferredError = error
        }
        await inputGate.resume()
        await cleanupGate.resume()
        await backend.releaseLookup(with: "fake-secret")
        await coordinator.setInputDidFinishTestingHooks(before: nil, after: nil)
        await coordinator.setBeforeCancellationCleanupForTesting(nil)
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSendSuccessfully()
            await driver.releaseSuspendedStop()
        }
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func cancelledStartupSuppressesSiblingReaderFailureAfterHeldStop() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let cleanupGate = CoordinatorReleaseGate()
        let startCompleted = CoordinatorCompletionFlag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let index = bag.all().count
                let driver = CoordinatorFakeDriver(
                    sendFailure: index == 1 ? .backpressure : nil,
                    suspendStartUntilStop: index == 0,
                    suspendStopUntilReleased: index == 1
                )
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setBeforeCancellationCleanupForTesting {
            await cleanupGate.suspend()
        }
        let pendingCapture = makeCoordinatorCapture(sourceID: "source-a")
        let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            let result = await coordinator.start(
                captures: [pendingCapture.source, siblingCapture.source],
                settings: settings
            )
            await startCompleted.markComplete()
            return result
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("two driver creation") { bag.all().count == 2 }
            let drivers = bag.all()
            guard drivers.count == 2 else { throw CoordinatorFixtureError.offerRejected }
            let pendingDriver = drivers[0]
            let siblingDriver = drivers[1]
            try await requireCoordinatorCondition("pending and sibling reader activation") {
                let pendingSuspended = await pendingDriver.isStartSuspended()
                let siblingStarted = await siblingDriver.successfulStartCount()
                let activeSources = await coordinator.activeSourceIDs()
                return pendingSuspended && siblingStarted == 1 && activeSources == ["source-b"]
            }
            try offer([1, 0], to: siblingCapture)
            try await requireCoordinatorCondition("sibling read failure and held stop") {
                let sends = await siblingDriver.sendInvocationCount()
                let stopping = await siblingDriver.isStopSuspended()
                return sends == 1 && stopping
            }
            #expect(failures.all().isEmpty)

            startTask.cancel()
            try await requireCoordinatorCondition("reader cleanup gate") { await cleanupGate.hasSuspended() }
            await siblingDriver.releaseSuspendedStop()
            try await requireCoordinatorCondition("sibling reader completion") { await coordinator.activeSourceIDs().isEmpty }
            #expect(failures.all().isEmpty)
            #expect(await startCompleted.hasCompleted() == false)

            await pendingDriver.releaseStartSuccessfully()
            await cleanupGate.resume()
            _ = await startTask.value
            #expect(failures.all().isEmpty)
        } catch {
            deferredError = error
        }
        await cleanupGate.resume()
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSendSuccessfully()
            await driver.releaseSuspendedStop()
        }
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func audioUsesNormalizedSampleSpansKeepsGapsAndRejectsOverlapPerSource() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let sibling = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(captures: [first.source, sibling.source], settings: settings)
        #expect(started.map(\.sourceID) == ["source-a", "source-b"])
        let drivers = bag.all()

        try offer([1, 0, 1, 0], to: first, sampleInterval: 8..<10, captureTimestampNanoseconds: 11)
        try offer([2, 0], to: first, sampleInterval: 14..<15, captureTimestampNanoseconds: 12)
        try offer([3, 0], to: first, sampleInterval: 14..<15, captureTimestampNanoseconds: 13)
        try offer([4, 0], to: sibling, sampleInterval: 32_000..<32_001, captureTimestampNanoseconds: 1)

        try await waitForCoordinatorCondition {
            let active = await coordinator.activeSourceIDs()
            let firstChunks = await drivers[0].audioChunks().count
            let siblingChunks = await drivers[1].audioChunks().count
            let receivedFailures = failures.all()
            return active == ["source-b"]
                && firstChunks == 2
                && siblingChunks == 1
                && receivedFailures.contains(where: { $0.0 == "source-a" && $0.1 == .malformedResponse })
        }

        let firstChunks = await drivers[0].audioChunks()
        let siblingChunks = await drivers[1].audioChunks()
        #expect(firstChunks == [
            RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: started[0].generation,
                capturedAtMonotonicNanoseconds: 11,
                startMonotonicNanoseconds: 500_000,
                endMonotonicNanoseconds: 625_000,
                pcm16LEData: Data([1, 0, 1, 0]),
                sampleRate: 16_000
            ),
            RealtimeAudioChunk(
                sourceAlias: "audio-1",
                generation: started[0].generation,
                capturedAtMonotonicNanoseconds: 12,
                startMonotonicNanoseconds: 875_000,
                endMonotonicNanoseconds: 937_500,
                pcm16LEData: Data([2, 0]),
                sampleRate: 16_000
            ),
        ])
        #expect(firstChunks[0].endMonotonicNanoseconds < firstChunks[1].startMonotonicNanoseconds)
        #expect(siblingChunks == [RealtimeAudioChunk(
            sourceAlias: "audio-2",
            generation: started[1].generation,
            capturedAtMonotonicNanoseconds: 1,
            startMonotonicNanoseconds: 2_000_000_000,
            endMonotonicNanoseconds: 2_000_062_500,
            pcm16LEData: Data([4, 0]),
            sampleRate: 16_000
        )])
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .malformedResponse)
        await coordinator.stop()
    }

    @Test func malformedAndOverflowSampleSpansFailOnlyTheirOwnSources() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["malformed", "overflow", "healthy"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let malformed = makeCoordinatorCapture(sourceID: "malformed")
        let overflow = makeCoordinatorCapture(sourceID: "overflow")
        let healthy = makeCoordinatorCapture(sourceID: "healthy")
        let started = await coordinator.start(
            captures: [malformed.source, overflow.source, healthy.source],
            settings: settings
        )
        #expect(started.map(\.sourceID) == ["malformed", "overflow", "healthy"])

        #expect(offerResult(
            [1, 0],
            to: malformed,
            sampleInterval: -1..<0,
            captureTimestampNanoseconds: 101
        ) == .invalidAudioChunk)
        #expect(offerResult(
            [2, 0],
            to: overflow,
            sampleInterval: (Int64.max - 1)..<Int64.max,
            captureTimestampNanoseconds: 202
        ) == .enqueued)
        try offer([3, 0], to: healthy, sampleInterval: 7..<8, captureTimestampNanoseconds: 1)

        try await waitForCoordinatorCondition {
            let active = await coordinator.activeSourceIDs()
            let healthyChunks = await bag.all()[2].audioChunks().count
            let receivedFailures = failures.all()
            return active == ["healthy"]
                && healthyChunks == 1
                && receivedFailures.count == 2
        }
        let receivedFailures = failures.all()
        #expect(Set(receivedFailures.map(\.0)) == Set(["malformed", "overflow"]))
        #expect(receivedFailures.allSatisfy { $0.1 == .malformedResponse })
        #expect(await coordinator.activeSourceIDs() == ["healthy"])
        await coordinator.stop()
    }

    @Test func siblingReaderRunsWhileFirstStartIsHeldAndLateRemovedStartCannotRevive() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let shouldHoldStart = bag.all().isEmpty
                let driver = CoordinatorFakeDriver(
                    suspendStartUntilStop: shouldHoldStart,
                    stopReleasesStart: !shouldHoldStart,
                    suspendFirstStopUntilSecondCall: shouldHoldStart
                )
                bag.append(driver)
                return driver
            }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            await coordinator.start(captures: [firstCapture.source, siblingCapture.source], settings: settings)
        }
        var removalTask: Task<Void, Never>?
        var deferredError: Error?
        do {
            try await waitForCoordinatorCondition { bag.all().count == 2 }
            let drivers = bag.all()
            guard drivers.count == 2 else { throw CoordinatorFixtureError.offerRejected }
            let firstDriver = drivers[0]
            let siblingDriver = drivers[1]
            try await waitForCoordinatorCondition {
                let firstStarts = await firstDriver.startInvocationCount()
                let siblingStarts = await siblingDriver.successfulStartCount()
                return firstStarts == 1 && siblingStarts == 1
            }

            try offer([2, 0], to: siblingCapture)
            try await waitForCoordinatorCondition {
                let siblingChunks = await siblingDriver.audioChunks().count
                let activeSources = await coordinator.activeSourceIDs()
                return siblingChunks == 1 && activeSources == ["source-b"]
            }
            #expect(await firstDriver.isStartSuspended())
            #expect(await firstDriver.successfulStartCount() == 0)

            removalTask = Task { await coordinator.removeSource(sourceID: "source-a") }
            try await waitForCoordinatorCondition { await firstDriver.isStopSuspended() }
            #expect(await coordinator.activeSourceIDs() == ["source-b"])
            #expect(offerResult([1, 0], to: firstCapture) == .closed)

            await firstDriver.releaseStartSuccessfully()
            try await waitForCoordinatorCondition { await firstDriver.stopInvocationCount() >= 2 }
            #expect(await firstDriver.stopInvocationCount() >= 2)
            await firstDriver.releaseSuspendedStop()
            await removalTask?.value
            let started = await startTask.value
            #expect(started.map(\.sourceID) == ["source-b"])
            #expect(started.first?.alias == "audio-2")
            #expect(await coordinator.activeSourceIDs() == ["source-b"])
            #expect(await siblingDriver.audioChunks().count == 1)
            #expect(await firstDriver.stopInvocationCount() >= 2)
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSuspendedStop()
        }
        if let removalTask { await removalTask.value }
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func lateRevokedStartDoesNotJoinNewerSameIDStopBarrier() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let index = bag.all().count
                let driver = CoordinatorFakeDriver(
                    suspendStartUntilStop: index == 0,
                    stopReleasesStart: false,
                    suspendStopUntilReleased: index == 1
                )
                bag.append(driver)
                return driver
            }
        )
        let originalCapture = makeCoordinatorCapture(sourceID: "source-a")
        let replacementCapture = makeCoordinatorCapture(sourceID: "source-a")
        let originalStartCompleted = CoordinatorCompletionFlag()
        let originalStartTask = Task {
            let result = await coordinator.start(captures: [originalCapture.source], settings: settings)
            await originalStartCompleted.markComplete()
            return result
        }
        var originalRemovalTask: Task<Void, Never>?
        var replacementStartTask: Task<[NativeRealtimeStartedSource], Never>?
        var replacementRemovalTask: Task<Void, Never>?
        var deferredError: Error?
        do {
            try await waitForCoordinatorCondition { bag.all().count == 1 }
            guard let originalDriver = bag.all().first else {
                throw CoordinatorFixtureError.offerRejected
            }
            try await waitForCoordinatorCondition {
                let startCount = await originalDriver.startInvocationCount()
                let startIsSuspended = await originalDriver.isStartSuspended()
                return startCount == 1 && startIsSuspended
            }

            originalRemovalTask = Task { await coordinator.removeSource(sourceID: "source-a") }
            await originalRemovalTask?.value
            #expect(await originalDriver.stopInvocationCount() == 1)
            #expect(await originalDriver.isStartSuspended())
            #expect(await originalStartCompleted.hasCompleted() == false)

            replacementStartTask = Task {
                await coordinator.start(captures: [replacementCapture.source], settings: settings)
            }
            let replacement = await replacementStartTask?.value ?? []
            #expect(replacement.map(\.sourceID) == ["source-a"])
            #expect(await coordinator.activeSourceIDs() == ["source-a"])
            guard bag.all().count == 2 else { throw CoordinatorFixtureError.offerRejected }
            let replacementDriver = bag.all()[1]
            #expect(await replacementDriver.successfulStartCount() == 1)

            replacementRemovalTask = Task { await coordinator.removeSource(sourceID: "source-a") }
            try await waitForCoordinatorCondition { await replacementDriver.isStopSuspended() }
            #expect(await coordinator.activeSourceIDs().isEmpty)

            await originalDriver.releaseStartSuccessfully()
            try await waitForCoordinatorCondition {
                let originalStopCount = await originalDriver.stopInvocationCount()
                let replacementStopIsSuspended = await replacementDriver.isStopSuspended()
                let originalStartDidComplete = await originalStartCompleted.hasCompleted()
                return originalStopCount == 2
                    && replacementStopIsSuspended
                    && originalStartDidComplete
            }
            #expect(await originalDriver.stopInvocationCount() == 2)
            #expect(await replacementDriver.isStopSuspended())
            #expect(await originalStartCompleted.hasCompleted())
            #expect(await coordinator.activeSourceIDs().isEmpty)
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSuspendedStop()
        }
        if let originalRemovalTask { await originalRemovalTask.value }
        if let replacementRemovalTask { await replacementRemovalTask.value }
        _ = await originalStartTask.value
        if let replacementStartTask { _ = await replacementStartTask.value }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func cancellingStartupImmediatelyRevokesReservedAndActiveSources() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        let cleanupGate = CoordinatorReleaseGate()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b", "source-c"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let index = bag.all().count
                let isPendingStart = index == 0 || index == 2
                let driver = CoordinatorFakeDriver(
                    startFailure: index == 2,
                    suspendSendUntilStop: index == 1,
                    suspendStartUntilStop: isPendingStart,
                    stopReleasesStart: false,
                    suspendFirstStopUntilSecondCall: isPendingStart
                )
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        await coordinator.setBeforeCancellationCleanupForTesting {
            await cleanupGate.suspend()
        }
        let pendingCapture = makeCoordinatorCapture(sourceID: "source-a")
        let activeCapture = makeCoordinatorCapture(sourceID: "source-b")
        let failingCapture = makeCoordinatorCapture(sourceID: "source-c")
        let startCompleted = CoordinatorCompletionFlag()
        let startTask = Task {
            let result = await coordinator.start(
                captures: [pendingCapture.source, activeCapture.source, failingCapture.source],
                settings: settings
            )
            await startCompleted.markComplete()
            return result
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("three source reservations") { bag.all().count == 3 }
            let drivers = bag.all()
            guard drivers.count == 3 else { throw CoordinatorFixtureError.offerRejected }
            let pendingDriver = drivers[0]
            let activeDriver = drivers[1]
            let failingDriver = drivers[2]
            try await requireCoordinatorCondition("startup driver states") {
                let pendingStarted = await pendingDriver.startInvocationCount()
                let pendingSuspended = await pendingDriver.isStartSuspended()
                let failingStarted = await failingDriver.startInvocationCount()
                let failingSuspended = await failingDriver.isStartSuspended()
                let activeStarts = await activeDriver.successfulStartCount()
                return pendingStarted == 1 && pendingSuspended
                    && failingStarted == 1 && failingSuspended
                    && activeStarts == 1
            }
            try offer([1, 0], to: activeCapture)
            try await requireCoordinatorCondition("active driver send suspension") {
                await activeDriver.isSendSuspended()
            }
            try offer([2, 0], to: activeCapture)
            #expect(await activeDriver.sendInvocationCount() == 1)

            startTask.cancel()
            try await requireCoordinatorCondition("startup cleanup gate") { await cleanupGate.hasSuspended() }
            #expect(offerResult([3, 0], to: pendingCapture) == .closed)
            #expect(offerResult([4, 0], to: activeCapture) == .closed)
            #expect(offerResult([5, 0], to: failingCapture) == .closed)
            #expect(failures.all().isEmpty)
            await pendingDriver.releaseStartSuccessfully()
            await failingDriver.releaseStartSuccessfully()
            try await requireCoordinatorCondition("post-start reserved driver cleanup") {
                let pendingSuccesses = await pendingDriver.successfulStartCount()
                let pendingPostStartStops = await pendingDriver.postStartResultStopCount()
                let failingPostStartStops = await failingDriver.postStartResultStopCount()
                let pendingStopSuspended = await pendingDriver.isStopSuspended()
                let failingStopSuspended = await failingDriver.isStopSuspended()
                let activeIDs = await coordinator.activeSourceIDs()
                return pendingSuccesses == 1
                    && pendingPostStartStops >= 1
                    && failingPostStartStops >= 1
                    && pendingStopSuspended
                    && failingStopSuspended
                    && !activeIDs.contains("source-a")
                    && failures.all().isEmpty
            }
            #expect(await coordinator.activeSourceIDs().contains("source-a") == false)
            #expect(await pendingDriver.postStartResultStopCount() >= 1)
            #expect(await failingDriver.postStartResultStopCount() >= 1)
            #expect(failures.all().isEmpty)

            await activeDriver.releaseSendSuccessfully()
            try await requireCoordinatorCondition("active driver stop") {
                await activeDriver.stopInvocationCount() == 1
            }
            #expect(await activeDriver.sendInvocationCount() == 1)
            #expect(await activeDriver.audioChunks().count == 1)
            #expect(await activeDriver.stopInvocationCount() == 1)
            #expect(failures.all().isEmpty)
            #expect(await startCompleted.hasCompleted() == false)
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSendSuccessfully()
            await driver.releaseSuspendedStop()
        }
        await cleanupGate.resume()
        await coordinator.setBeforeCancellationCleanupForTesting(nil)
        _ = await startTask.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func failedStartReportsToItsHandlerBeforeHeldStopAndReplacement() async throws {
        let bag = CoordinatorDriverBag()
        let oldFailures = CoordinatorFailureBag()
        let newFailures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let isFirst = bag.all().isEmpty
                let driver = CoordinatorFakeDriver(
                    startFailure: isFirst,
                    suspendStopUntilReleased: isFirst
                )
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in oldFailures.append(sourceID, code) }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let firstStartTask = Task {
            await coordinator.start(captures: [firstCapture.source], settings: settings)
        }
        var replacementTask: Task<[NativeRealtimeStartedSource], Never>?
        var deferredError: Error?
        do {
            try await waitForCoordinatorCondition { bag.all().count == 1 }
            guard let failingDriver = bag.all().first else {
                throw CoordinatorFixtureError.offerRejected
            }
            try await waitForCoordinatorCondition { await failingDriver.startInvocationCount() == 1 }
            try await waitForCoordinatorCondition { await failingDriver.isStopSuspended() }

            #expect(oldFailures.all().count == 1)
            #expect(oldFailures.all().first?.0 == "source-a")
            #expect(oldFailures.all().first?.1 == .connectionFailed)

            await coordinator.setSourceFailureHandler { sourceID, code in
                newFailures.append(sourceID, code)
            }
            var replacementSettings = settings
            replacementSettings.enabledSourceIDs = ["source-b"]
            let replacementCapture = makeCoordinatorCapture(sourceID: "source-b")
            replacementTask = Task {
                await coordinator.start(captures: [replacementCapture.source], settings: replacementSettings)
            }
            try await waitForCoordinatorCondition {
                await coordinator.startupSourceIDsForTesting() == ["source-b"]
            }
            #expect(bag.all().count == 1)
            #expect(await coordinator.activeSourceIDs().isEmpty)
            await failingDriver.releaseSuspendedStop()

            let failedStart = await firstStartTask.value
            let replacement = await replacementTask?.value ?? []
            #expect(failedStart.isEmpty)
            #expect(replacement.map(\.sourceID) == ["source-b"])
            #expect(oldFailures.all().count == 1)
            #expect(newFailures.all().isEmpty)
            await coordinator.stop()
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSuspendedStop()
        }
        _ = await firstStartTask.value
        if let replacementTask { _ = await replacementTask.value }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func cancellingWhileDriverStartIsSuspendedStopsPendingDriver() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: bag.all().count == 1)
                bag.append(driver)
                return driver
            }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let secondCapture = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            await coordinator.start(captures: [firstCapture.source, secondCapture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 2 }
        let firstDriver = bag.all()[0]
        let pendingDriver = bag.all()[1]
        try await waitForCoordinatorCondition { await pendingDriver.startInvocationCount() == 1 }

        startTask.cancel()
        var stoppedBeforeStartReturned = false
        for _ in 0..<100 {
            if await pendingDriver.stopInvocationCount() > 0 {
                stoppedBeforeStartReturned = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !stoppedBeforeStartReturned {
            await pendingDriver.releaseStartSuccessfully()
        }
        let started = await startTask.value

        #expect(stoppedBeforeStartReturned)
        #expect(started.isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(await firstDriver.stopInvocationCount() > 0)
        #expect(await pendingDriver.stopInvocationCount() > 0)
        #expect(offerResult([1, 0], to: firstCapture) == .closed)
        #expect(offerResult([1, 0], to: secondCapture) == .closed)
    }

    @Test func inputFinishedWhileDriverStartsIsNotReportedStarted() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition { await driver.startInvocationCount() == 1 }

        capture.source.input.finish()
        var stoppedBeforeStartReturned = false
        for _ in 0..<100 {
            if await driver.stopInvocationCount() > 0 {
                stoppedBeforeStartReturned = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !stoppedBeforeStartReturned {
            await driver.releaseStartSuccessfully()
        }
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(stoppedBeforeStartReturned)
        #expect(await driver.stopInvocationCount() > 0)
        #expect(await coordinator.activeSourceIDs().isEmpty)
    }

    @Test func startResultOmitsSourceRemovedWhileLaterDriverStarts() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: bag.all().count == 1)
                bag.append(driver)
                return driver
            }
        )
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let secondCapture = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            await coordinator.start(captures: [firstCapture.source, secondCapture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 2 }
        let secondDriver = bag.all()[1]
        try await waitForCoordinatorCondition { await secondDriver.startInvocationCount() == 1 }

        firstCapture.source.input.finish()
        try await waitForCoordinatorCondition { await coordinator.activeSourceIDs().isEmpty }
        await secondDriver.releaseStartSuccessfully()
        let started = await startTask.value

        #expect(started.map(\.sourceID) == ["source-b"])
        #expect(await coordinator.activeSourceIDs() == ["source-b"])
        await coordinator.stop()
    }

    @Test func backpressureWhileDriverStartsStopsAndReportsPendingSource() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition { await driver.startInvocationCount() == 1 }

        capture.source.input.finish(error: .backpressureExceeded)
        try await waitForCoordinatorCondition { await driver.stopInvocationCount() > 0 }
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .backpressure)
    }

    @Test func offerOverflowWhileDriverStartsStopsAndReportsPendingSource() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a", maximumBufferedFrames: 1)
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition { await driver.startInvocationCount() == 1 }

        try offer([1, 0], to: capture)
        #expect(offerResult([2, 0], to: capture) == .backpressureExceeded)
        try await waitForCoordinatorCondition { await driver.stopInvocationCount() > 0 }
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .backpressure)
    }

    @Test func prefinishedInputPreservesTypedFailureWithoutStoppingHealthySibling() async {
        let cases: [(RealtimePCM16AudioStreamError, RealtimeFailureCode)] = [
            (.backpressureExceeded, .backpressure),
            (.invalidAudioChunk, .malformedResponse),
        ]
        for (streamError, expectedFailure) in cases {
            let bag = CoordinatorDriverBag()
            let failures = CoordinatorFailureBag()
            var settings = NativeRealtimeSettings.default
            settings.isEnabled = true
            settings.credentialReference = "fake-ref"
            settings.enabledSourceIDs = ["failed", "healthy"]
            let coordinator = NativeRealtimeSessionCoordinator(
                credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
                driverFactory: { _, _, _ in
                    let driver = CoordinatorFakeDriver()
                    bag.append(driver)
                    return driver
                },
                sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
            )
            let failed = makeCoordinatorCapture(sourceID: "failed")
            let healthy = makeCoordinatorCapture(sourceID: "healthy")
            failed.source.input.finish(error: streamError)

            let started = await coordinator.start(captures: [failed.source, healthy.source], settings: settings)

            #expect(started.map(\.sourceID) == ["healthy"])
            #expect(bag.all().count == 1)
            #expect(failures.all().count == 1)
            #expect(failures.all().first?.0 == "failed")
            #expect(failures.all().first?.1 == expectedFailure)
            await coordinator.stop()
        }
    }

    @Test func invalidAudioWhileDriverStartsReportsMalformedResponse() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition { await driver.startInvocationCount() == 1 }

        capture.source.input.finish(error: .invalidAudioChunk)
        try await waitForCoordinatorCondition { await driver.stopInvocationCount() > 0 }
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .malformedResponse)
    }

    @Test func invalidAudioAfterReaderStartsIsReportedExactlyOnce() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)

        capture.source.input.finish(error: .invalidAudioChunk)
        try await waitForCoordinatorCondition { await coordinator.activeSourceIDs().isEmpty }

        #expect(started.map(\.sourceID) == ["source-a"])
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .malformedResponse)
        #expect(await bag.all()[0].stopInvocationCount() == 1)
    }

    @Test func settingsReconfigurationRejectsAndRevokesPreviouslyConsumedAudioInput() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let firstRun = await coordinator.start(captures: [capture.source], settings: settings)
        let originalDriver = bag.all()[0]
        settings.profile = .openAI

        let rejectedRun = await coordinator.start(captures: [capture.source], settings: settings)

        #expect(firstRun.count == 1)
        #expect(rejectedRun.isEmpty)
        #expect(bag.all().count == 1)
        #expect(await originalDriver.stopInvocationCount() > 0)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .invalidConfiguration)
        #expect(offerResult([1, 0], to: capture) == .closed)
        await coordinator.stop()
    }

    @Test func stopThenRestartWithSamePCMInputDoesNotReportStarted() async {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let firstRun = await coordinator.start(captures: [capture.source], settings: settings)
        await coordinator.stop()

        let restarted = await coordinator.start(captures: [capture.source], settings: settings)

        #expect(firstRun.count == 1)
        #expect(restarted.isEmpty)
        #expect(bag.all().count == 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.1 == .invalidConfiguration)
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func naturalInputCompletionThenRestartWithSameInputDoesNotReportStarted() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let firstRun = await coordinator.start(captures: [capture.source], settings: settings)
        let firstDriver = bag.all()[0]
        capture.source.input.finish()
        try await waitForCoordinatorCondition {
            let activeSourceIDs = await coordinator.activeSourceIDs()
            let stopCount = await firstDriver.stopInvocationCount()
            return activeSourceIDs.isEmpty && stopCount > 0
        }

        let restarted = await coordinator.start(captures: [capture.source], settings: settings)

        #expect(firstRun.count == 1)
        #expect(restarted.isEmpty)
        #expect(bag.all().count == 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.1 == .invalidConfiguration)
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func multipleOptedInSourcesCannotShareOnePCMInput() async {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let aliasedCapture = NativeRealtimeCaptureSource(
            sourceID: "source-b",
            role: .applicationAudio,
            input: capture.source.input
        )

        let started = await coordinator.start(
            captures: [capture.source, aliasedCapture],
            settings: settings
        )

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 2)
        #expect(failures.all().allSatisfy { $0.1 == .invalidConfiguration })
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func reconfigurationToZeroOptedInSourcesStopsExistingDrivers() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [capture.source], settings: settings)
        let driver = bag.all()[0]
        settings.enabledSourceIDs = []

        let started = await coordinator.start(captures: [capture.source], settings: settings)

        #expect(started.isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(await driver.stopInvocationCount() >= 1)
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func oneDriverStartupFailureLeavesOtherSourceRunning() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(startFailure: bag.all().isEmpty)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let second = makeCoordinatorCapture(sourceID: "source-b")

        let started = await coordinator.start(captures: [first.source, second.source], settings: settings)

        #expect(started.count == 1)
        #expect(started.first?.sourceID == "source-b")
        #expect(started.first?.alias == "audio-2")
        #expect(offerResult([1, 0], to: first) == .closed)
        try offer([2, 0], to: second)
        try await waitForCoordinatorCondition { await bag.all()[1].audioChunks().count == 1 }
        let receivedFailures = failures.all()
        #expect(receivedFailures.count == 1)
        #expect(receivedFailures.first?.0 == "source-a")
        #expect(receivedFailures.first?.1 == .connectionFailed)
        await coordinator.stop()
    }

    @Test func missingCredentialFailsOnlyOptedInCapturesWithoutCreatingDrivers() async {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.enabledSourceIDs = ["native-source"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: nil)),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let nativeCapture = makeCoordinatorCapture(sourceID: "native-source")
        let ordinaryCapture = makeCoordinatorCapture(sourceID: "ordinary-chat-source")

        let started = await coordinator.start(
            captures: [nativeCapture.source, ordinaryCapture.source],
            settings: settings
        )

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(offerResult([1, 0], to: nativeCapture) == .closed)
        #expect(ordinaryCapture.fanout.offer(
            pcm16LE: Data([2, 0]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: ordinaryCapture.source.input.sourceToken,
            generation: ordinaryCapture.source.input.generation,
            captureTimestampNanoseconds: 202
        ) == .enqueued)
        let receivedFailures = failures.all()
        #expect(receivedFailures.count == 1)
        #expect(receivedFailures.first?.0 == "native-source")
        #expect(receivedFailures.first?.1 == .invalidConfiguration)
        await coordinator.stop()
    }

    @Test func oneSourceBackpressureDoesNotStopItsSibling() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let failNextSend = bag.all().isEmpty
                let driver = CoordinatorFakeDriver(sendFailure: failNextSend ? .backpressure : nil)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let second = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(captures: [first.source, second.source], settings: settings)
        try offer([1, 0], to: first)
        try offer([2, 0], to: second)

        try await waitForCoordinatorCondition {
            await coordinator.activeSourceIDs() == ["source-b"]
        }
        let receivedFailures = failures.all()
        #expect(receivedFailures.count == 1)
        #expect(receivedFailures.first?.0 == "source-a")
        #expect(receivedFailures.first?.1 == .backpressure)
        let drivers = bag.all()
        #expect(await drivers[1].audioChunks() == [RealtimeAudioChunk(
            sourceAlias: "audio-2",
            generation: started[1].generation,
            capturedAtMonotonicNanoseconds: 202,
            startMonotonicNanoseconds: 0,
            endMonotonicNanoseconds: 62_500,
            pcm16LEData: Data([2, 0]),
            sampleRate: 16_000
        )])
        await coordinator.removeSource(sourceID: "source-b")
        #expect(await coordinator.activeSourceIDs().isEmpty)
        await coordinator.stop()
    }

    @Test func removingOneSourceClosesItsInputAndLeavesSiblingReaderAlive() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let second = makeCoordinatorCapture(sourceID: "source-b")
        let started = await coordinator.start(captures: [first.source, second.source], settings: settings)

        await coordinator.removeSource(sourceID: "source-a")

        #expect(await coordinator.activeSourceIDs() == ["source-b"])
        #expect(offerResult([1, 0], to: first) == .closed)
        try offer([2, 0], to: second)
        try await waitForCoordinatorCondition { await bag.all()[1].audioChunks().count == 1 }
        let siblingChunk = await bag.all()[1].audioChunks()[0]
        #expect(siblingChunk.sourceAlias == "audio-2")
        #expect(siblingChunk.generation == started[1].generation)
        #expect(await bag.all()[0].stopInvocationCount() >= 1)
        await coordinator.stop()
    }

    @Test func fanoutOverflowBeforeReaderStartsIsIsolatedToThatCapture() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["overflowing", "healthy"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let overflowing = makeCoordinatorCapture(sourceID: "overflowing", maximumBufferedFrames: 1)
        let healthy = makeCoordinatorCapture(sourceID: "healthy")
        try offer([1, 0], to: overflowing)
        #expect(offerResult([2, 0], to: overflowing) == .backpressureExceeded)
        try offer([3, 0], to: healthy)

        let started = await coordinator.start(captures: [overflowing.source, healthy.source], settings: settings)
        #expect(started.map(\.sourceID) == ["healthy"])
        try await waitForCoordinatorCondition {
            await coordinator.activeSourceIDs() == ["healthy"]
        }
        let receivedFailures = failures.all()
        #expect(receivedFailures.count == 1)
        #expect(receivedFailures.first?.0 == "overflowing")
        #expect(receivedFailures.first?.1 == .backpressure)
        let drivers = bag.all()
        #expect(drivers.count == 1)
        if let healthyDriver = drivers.first {
            try await waitForCoordinatorCondition { await healthyDriver.audioChunks().count == 1 }
            #expect(await healthyDriver.audioChunks().count == 1)
        }

        let restarted = await coordinator.start(captures: [overflowing.source], settings: settings)
        #expect(restarted.isEmpty)
        #expect(bag.all().count == 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 2)
        #expect(failures.all().last?.1 == .backpressure)
        await coordinator.stop()
    }

    @Test func stopAndRestartWaitForAnAlreadyRemovingSourceToFinishStopping() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStopUntilReleased: bag.all().isEmpty)
                bag.append(driver)
                return driver
            }
        )
        let originalCapture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [originalCapture.source], settings: settings)
        let originalDriver = try #require(bag.all().first)

        let removalTask = Task { await coordinator.removeSource(sourceID: "source-a") }
        try await waitForCoordinatorCondition { await originalDriver.isStopSuspended() }
        let generationBeforeStop = await coordinator.lifecycleGenerationForTesting()
        let stopTask = Task { await coordinator.stop() }
        try await waitForCoordinatorCondition {
            await coordinator.lifecycleGenerationForTesting() > generationBeforeStop
        }
        let replacementCapture = makeCoordinatorCapture(sourceID: "source-a")
        let restartTask = Task {
            await coordinator.start(captures: [replacementCapture.source], settings: settings)
        }
        try await waitForCoordinatorCondition {
            await coordinator.startupSourceIDsForTesting() == ["source-a"]
        }

        #expect(bag.all().count == 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)

        await originalDriver.releaseSuspendedStop()
        await removalTask.value
        await stopTask.value
        let restarted = await restartTask.value

        #expect(restarted.count == 1)
        #expect(bag.all().count == 2)
        #expect(await coordinator.activeSourceIDs() == ["source-a"])
        await coordinator.stop()
    }

    @Test func removeDuringRestartBarrierTombstonesTheReplacementBeforeDriverCreation() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStopUntilReleased: bag.all().isEmpty)
                bag.append(driver)
                return driver
            }
        )
        let originalCapture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [originalCapture.source], settings: settings)
        let originalDriver = try #require(bag.all().first)

        let removalTask = Task { await coordinator.removeSource(sourceID: "source-a") }
        try await waitForCoordinatorCondition { await originalDriver.isStopSuspended() }
        let replacementCapture = makeCoordinatorCapture(sourceID: "source-b")
        let restartTask = Task {
            await coordinator.start(captures: [replacementCapture.source], settings: settings)
        }
        try await waitForCoordinatorCondition {
            await coordinator.startupSourceIDsForTesting() == ["source-b"]
        }
        await coordinator.removeSource(sourceID: "source-b")
        await originalDriver.releaseSuspendedStop()
        await removalTask.value
        let restarted = await restartTask.value

        #expect(restarted.isEmpty)
        #expect(bag.all().count == 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        await coordinator.stop()
    }

    @Test func stopClosesInputAndWaitsForSuspendedDriverSendToFinish() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendSendUntilStop: bag.all().isEmpty)
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let previousRun = await coordinator.start(captures: [capture.source], settings: settings)
        try offer([1, 0], to: capture)
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition { await driver.sendInvocationCount() == 1 }

        await coordinator.stop()

        #expect(await driver.stopInvocationCount() >= 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(capture.fanout.offer(
            pcm16LE: Data([2, 0]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: capture.source.input.sourceToken,
            generation: capture.source.input.generation,
            captureTimestampNanoseconds: 303
        ) == .closed)

        let nextCapture = makeCoordinatorCapture(sourceID: "source-a")
        let restarted = await coordinator.start(captures: [nextCapture.source], settings: settings)
        #expect(restarted.count == 1)
        #expect(restarted[0].generation > previousRun[0].generation)
        #expect(capture.fanout.offer(
            pcm16LE: Data([3, 0]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: capture.source.input.sourceToken,
            generation: capture.source.input.generation,
            captureTimestampNanoseconds: 404
        ) == .closed)
        try offer([4, 0], to: nextCapture)
        let newDriver = bag.all()[1]
        try await waitForCoordinatorCondition { await newDriver.audioChunks().count == 1 }
        #expect(await newDriver.audioChunks().first?.generation == restarted[0].generation)
        await coordinator.stop()
    }

    @Test func lateSuccessfulOldSendCannotAdmitAudioIntoReplacementCaptionLedger() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendSendUntilReleased: bag.all().isEmpty)
                bag.append(driver)
                return driver
            }
        )
        let oldCapture = makeCoordinatorCapture(sourceID: "source-a")
        let oldStarted = await coordinator.start(captures: [oldCapture.source], settings: settings)
        #expect(oldStarted.count == 1)
        guard let oldDriver = bag.all().first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        let oldCaption = RealtimeAcceptedCaptionMetadata(
            sourceID: "source-a",
            sourceToken: oldCapture.source.input.sourceToken,
            captureGeneration: oldCapture.source.input.generation,
            captionID: UUID(),
            utteranceID: "old-lifecycle-caption",
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            sampleInterval: 0..<1
        )
        let removalFinished = CoordinatorCompletionFlag()
        var removeTask: Task<Void, Never>?
        var deferredError: Error?
        do {
            #expect(await coordinator.submitAcceptedCaption(oldCaption) == .queued)
            try offer([1, 0], to: oldCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("old driver send is held") {
                await oldDriver.isSendSuspended()
            }
            removeTask = Task {
                await coordinator.removeSource(sourceID: "source-a")
                await removalFinished.markComplete()
            }
            try await requireCoordinatorCondition("removal joins held old send") {
                let stops = await oldDriver.stopInvocationCount()
                let removed = await removalFinished.hasCompleted()
                return stops == 1 && !removed
            }
            await oldDriver.releaseSendSuccessfully()
            try await requireCoordinatorCondition("removal completes after old send acknowledgement") {
                await removalFinished.hasCompleted()
            }
            await removeTask?.value
            #expect(await removalFinished.hasCompleted())

            let newCapture = makeCoordinatorCapture(sourceID: "source-a")
            let restarted = await coordinator.start(captures: [newCapture.source], settings: settings)
            #expect(restarted.count == 1)
            #expect((restarted.first?.generation ?? 0) > (oldStarted.first?.generation ?? 0))
            let newDriver = bag.all()[1]
            #expect(await coordinator.submitAcceptedCaption(oldCaption) == .localOnly(.unavailableSource))
            let newCaption = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: newCapture.source.input.sourceToken,
                captureGeneration: newCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "new-lifecycle-caption",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<1
            )
            #expect(await coordinator.submitAcceptedCaption(newCaption) == .queued)
            try offer([2, 0], to: newCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("new lifecycle commits only its own caption") {
                await newDriver.committedUtterances().count == 1
            }
            #expect(await newDriver.committedUtterances().first?.captionID == newCaption.captionID)
            #expect(await oldDriver.committedUtterances().isEmpty)
            #expect(await oldDriver.audioChunks().count == 1)
            #expect(await newDriver.audioChunks().count == 1)
        } catch {
            deferredError = error
        }
        await oldDriver.releaseSendSuccessfully()
        if let removeTask {
            do {
                try await requireCoordinatorCondition("removal task joins held old send") {
                    await removalFinished.hasCompleted()
                }
                await removeTask.value
            } catch {
                if deferredError == nil { deferredError = error }
            }
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func staleProviderEventHeldAcrossRemovalCannotAffectReplacementCapture() async throws {
        let bag = CoordinatorDriverBag()
        let events = CoordinatorCaptionEventBag()
        let deliveryGate = CoordinatorReleaseGate()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        await coordinator.setBeforeProviderEventDeliveryForTesting {
            await deliveryGate.suspend()
        }
        let oldCapture = makeCoordinatorCapture(sourceID: "source-a")
        let oldStarted = await coordinator.start(captures: [oldCapture.source], settings: settings)
        let removalFinished = CoordinatorCompletionFlag()
        var removeTask: Task<Void, Never>?
        var deferredError: Error?
        do {
            guard oldStarted.count == 1, bag.all().count == 1 else {
                throw CoordinatorFixtureError.offerRejected
            }
            let oldActive = oldStarted[0]
            let oldDriver = bag.all()[0]
            try await requireCoordinatorCondition("old event reader subscribes") {
                await oldDriver.hasEventSubscriber()
            }
            let oldCaption = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: oldCapture.source.input.sourceToken,
                captureGeneration: oldCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "old-held-event",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<1
            )
            #expect(await coordinator.submitAcceptedCaption(oldCaption) == .queued)
            try offer([1, 0], to: oldCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("old caption commits before its correction") {
                await oldDriver.committedUtterances().count == 1
            }
            await oldDriver.yieldEvent(.correctedText(
                sourceAlias: oldActive.alias,
                generation: oldActive.generation,
                captionID: oldCaption.captionID,
                utteranceID: oldCaption.utteranceID,
                text: "stale correction held before delivery"
            ))
            try await requireCoordinatorCondition("old correction is held between stream and actor delivery") {
                await deliveryGate.hasSuspended()
            }

            removeTask = Task {
                await coordinator.removeSource(sourceID: "source-a")
                await removalFinished.markComplete()
            }
            try await requireCoordinatorCondition("removal revokes source while stale event is held") {
                let active = await coordinator.activeSourceIDs()
                let stops = await oldDriver.stopInvocationCount()
                let removed = await removalFinished.hasCompleted()
                return active.isEmpty && stops == 1 && !removed
            }
            #expect(events.all().isEmpty)

            await deliveryGate.resume()
            try await requireCoordinatorCondition("removal joins the canceled held event reader") {
                await removalFinished.hasCompleted()
            }
            await removeTask?.value
            #expect(events.all().isEmpty)
            await coordinator.setBeforeProviderEventDeliveryForTesting(nil)

            let newCapture = makeCoordinatorCapture(sourceID: "source-a")
            let newStarted = await coordinator.start(captures: [newCapture.source], settings: settings)
            guard newStarted.count == 1, bag.all().count == 2 else {
                throw CoordinatorFixtureError.offerRejected
            }
            let newActive = newStarted[0]
            let newDriver = bag.all()[1]
            let newCaption = RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: newCapture.source.input.sourceToken,
                captureGeneration: newCapture.source.input.generation,
                captionID: UUID(),
                utteranceID: "replacement-current-event",
                sourceLanguageID: "yue",
                targetLanguageID: "en",
                sampleInterval: 0..<1
            )
            try await requireCoordinatorCondition("replacement event reader subscribes") {
                await newDriver.hasEventSubscriber()
            }
            #expect(await coordinator.submitAcceptedCaption(newCaption) == .queued)
            try offer([2, 0], to: newCapture, sampleInterval: 0..<1)
            try await requireCoordinatorCondition("replacement commits its own caption") {
                await newDriver.committedUtterances().count == 1
            }
            await newDriver.yieldEvent(.correctedText(
                sourceAlias: newActive.alias,
                generation: newActive.generation,
                captionID: newCaption.captionID,
                utteranceID: newCaption.utteranceID,
                text: "current replacement correction"
            ))
            try await requireCoordinatorCondition("replacement event remains deliverable") {
                events.all().count == 1
            }
            let delivered = events.all()[0]
            #expect(delivered.sourceToken == newCapture.source.input.sourceToken)
            #expect(delivered.captureGeneration == newCapture.source.input.generation)
            #expect(delivered.sourceAlias == newActive.alias)
            #expect(delivered.driverGeneration == newActive.generation)
            #expect(delivered.captionID == newCaption.captionID)
            #expect(delivered.utteranceID == newCaption.utteranceID)
            #expect(delivered.sourceLanguageID == "yue")
            #expect(delivered.targetLanguageID == "en")
            #expect(delivered.kind == .correctedText("current replacement correction"))
        } catch {
            deferredError = error
        }
        await deliveryGate.resume()
        await coordinator.setBeforeProviderEventDeliveryForTesting(nil)
        if let removeTask {
            do {
                try await requireCoordinatorCondition("held stale-event removal task finishes") {
                    await removalFinished.hasCompleted()
                }
                await removeTask.value
            } catch {
                if deferredError == nil { deferredError = error }
            }
        }
        for driver in bag.all() {
            await driver.releaseSendSuccessfully()
            await driver.releaseCommitSuccessfully()
            await driver.releaseSuspendedStop()
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func eventFailureExpiryAndUnexpectedEndRevokeThenJoinWithoutBlockingSibling() async throws {
        let cases: [(String, RealtimeFailureCode)] = [
            ("failure", .rateLimited),
            ("expired", .sessionExpired),
            ("unexpected-end", .connectionFailed),
        ]
        for (eventKind, expectedFailure) in cases {
            let bag = CoordinatorDriverBag()
            let failures = CoordinatorFailureBag()
            let events = CoordinatorCaptionEventBag()
            var settings = NativeRealtimeSettings.default
            settings.isEnabled = true
            settings.credentialReference = "fake-ref"
            settings.enabledSourceIDs = ["source-a", "source-b"]
            let coordinator = NativeRealtimeSessionCoordinator(
                credentialStore: RealtimeCredentialStore(
                    backend: CoordinatorCredentialBackend(secret: "fake-secret")
                ),
                driverFactory: { _, _, _ in
                    let driver = CoordinatorFakeDriver(
                        suspendStopUntilReleased: bag.all().isEmpty
                    )
                    bag.append(driver)
                    return driver
                },
                sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
            )
            await coordinator.setCaptionEventHandler { events.append($0) }
            let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
            let siblingCapture = makeCoordinatorCapture(sourceID: "source-b")
            let started = await coordinator.start(
                captures: [firstCapture.source, siblingCapture.source],
                settings: settings
            )
            #expect(started.map(\.sourceID) == ["source-a", "source-b"])
            guard started.count == 2, bag.all().count == 2 else {
                for driver in bag.all() { await driver.releaseSuspendedStop() }
                await coordinator.stop()
                throw CoordinatorFixtureError.offerRejected
            }
            let failingDriver = bag.all()[0]
            let siblingDriver = bag.all()[1]
            let failingStarted = started[0]
            let removalFinished = CoordinatorCompletionFlag()
            var removalTask: Task<Void, Never>?
            var deferredError: Error?
            do {
                try await requireCoordinatorCondition("both event streams subscribed for \(eventKind)") {
                    let first = await failingDriver.hasEventSubscriber()
                    let second = await siblingDriver.hasEventSubscriber()
                    return first && second
                }
                switch eventKind {
                case "failure":
                    await failingDriver.yieldEvent(.failure(
                        sourceAlias: failingStarted.alias,
                        generation: failingStarted.generation,
                        expectedFailure
                    ))
                case "expired":
                    await failingDriver.yieldEvent(.expired(
                        sourceAlias: failingStarted.alias,
                        generation: failingStarted.generation
                    ))
                default:
                    await failingDriver.finishEvents()
                }
                try await requireCoordinatorCondition("event failure revokes source and holds its stop for \(eventKind)") {
                    let stopHeld = await failingDriver.isStopSuspended()
                    let active = await coordinator.activeSourceIDs()
                    let seenFailures = failures.all()
                    return stopHeld
                        && active == ["source-b"]
                        && seenFailures.count == 1
                        && seenFailures.first?.0 == "source-a"
                        && seenFailures.first?.1 == expectedFailure
                }

                removalTask = Task {
                    await coordinator.removeSource(sourceID: "source-a")
                    await removalFinished.markComplete()
                }
                let siblingCaption = RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-b",
                    sourceToken: siblingCapture.source.input.sourceToken,
                    captureGeneration: siblingCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "sibling-after-\(eventKind)",
                    sourceLanguageID: "en",
                    targetLanguageID: "zh-Hans",
                    sampleInterval: 0..<1
                )
                #expect(await coordinator.submitAcceptedCaption(siblingCaption) == .queued)
                try offer([8, 0], to: siblingCapture, sampleInterval: 0..<1)
                try await requireCoordinatorCondition("healthy sibling commits during held failed-source stop") {
                    await siblingDriver.committedUtterances().count == 1
                }
                #expect(await removalFinished.hasCompleted() == false)
                #expect(events.all().isEmpty)

                await failingDriver.releaseSuspendedStop()
                try await requireCoordinatorCondition("removal joins event reader after stop release") {
                    await removalFinished.hasCompleted()
                }
                await removalTask?.value
                #expect(await coordinator.activeSourceIDs() == ["source-b"])
            } catch {
                deferredError = error
            }

            await failingDriver.releaseSuspendedStop()
            if let removalTask {
                do {
                    try await requireCoordinatorCondition("failed-source removal task terminates for \(eventKind)") {
                        await removalFinished.hasCompleted()
                    }
                    await removalTask.value
                } catch {
                    if deferredError == nil { deferredError = error }
                }
            }
            await coordinator.stop()
            if let deferredError { throw deferredError }
        }
    }

    @Test func seenCaptionIdentitiesStayBoundedAndCommittedFrontierRejectsEvictedOldSpan() async throws {
        let bag = CoordinatorDriverBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver()
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let started = await coordinator.start(captures: [capture.source], settings: settings)
        #expect(started.count == 1)
        guard let driver = bag.all().first, let active = started.first else {
            await coordinator.stop()
            throw CoordinatorFixtureError.offerRejected
        }
        var evictedCandidate: RealtimeAcceptedCaptionMetadata?
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("caption event reader subscribed before identity loop") {
                await driver.hasEventSubscriber()
            }
            for index in 0..<129 {
                let lower = Int64(index)
                let metadata = RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-a",
                    sourceToken: capture.source.input.sourceToken,
                    captureGeneration: capture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "bounded-\(index)",
                    sourceLanguageID: "en",
                    targetLanguageID: "zh-Hans",
                    sampleInterval: lower..<(lower + 1)
                )
                if index == 0 { evictedCandidate = metadata }
                #expect(await coordinator.submitAcceptedCaption(metadata) == .queued)
                try offer(
                    [1, 0],
                    to: capture,
                    sampleInterval: lower..<(lower + 1),
                    captureTimestampNanoseconds: UInt64(index + 1)
                )
                let expectedCount = index + 1
                try await requireCoordinatorCondition("caption \(expectedCount) commits in FIFO order") {
                    let attempts = await driver.commitInvocationCount()
                    let commits = await driver.committedUtterances()
                    return attempts == expectedCount && commits.count == expectedCount
                }
                let committed = await driver.committedUtterances().last
                #expect(committed?.utteranceID == metadata.utteranceID)
                await driver.yieldEvent(.utteranceCompleted(
                    sourceAlias: active.alias,
                    generation: active.generation,
                    captionID: metadata.captionID,
                    utteranceID: metadata.utteranceID
                ))
                try await requireCoordinatorCondition("caption \(expectedCount) exact terminal processed") {
                    events.all().count == expectedCount
                }
            }
            #expect(await coordinator.seenCaptionIdentityCountForTesting(sourceID: "source-a") == 128)
            guard let evictedCandidate else { throw CoordinatorFixtureError.offerRejected }
            #expect(await coordinator.submitAcceptedCaption(evictedCandidate) == .localOnly(.consumedAudio))
            #expect(await coordinator.submitAcceptedCaption(RealtimeAcceptedCaptionMetadata(
                sourceID: "source-a",
                sourceToken: capture.source.input.sourceToken,
                captureGeneration: capture.source.input.generation,
                captionID: UUID(),
                utteranceID: "evicted-old-span",
                sourceLanguageID: "en",
                targetLanguageID: "zh-Hans",
                sampleInterval: 0..<1
            )) == .localOnly(.consumedAudio))
            #expect(await driver.commitInvocationCount() == 129)
            #expect(await coordinator.seenCaptionIdentityCountForTesting(sourceID: "source-a") == 128)
        } catch {
            deferredError = error
        }
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }

    @Test func interleavedSourcesKeepStartupQueueCorrectionsAndTerminalIdentityIsolated() async throws {
        let bag = CoordinatorDriverBag()
        let events = CoordinatorCaptionEventBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(
                backend: CoordinatorCredentialBackend(secret: "fake-secret")
            ),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(
                    suspendStartUntilStop: bag.all().isEmpty
                )
                bag.append(driver)
                return driver
            }
        )
        await coordinator.setCaptionEventHandler { events.append($0) }
        let firstCapture = makeCoordinatorCapture(sourceID: "source-a")
        let secondCapture = makeCoordinatorCapture(sourceID: "source-b")
        let startFinished = CoordinatorCompletionFlag()
        let startTask = Task {
            let started = await coordinator.start(
                captures: [firstCapture.source, secondCapture.source],
                settings: settings
            )
            await startFinished.markComplete()
            return started
        }
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("source-a setup held while source-b becomes ready") {
                guard bag.all().count == 2 else { return false }
                let first = bag.all()[0]
                let second = bag.all()[1]
                let firstHeld = await first.isStartSuspended()
                let secondStarted = await second.successfulStartCount() == 1
                let active = await coordinator.activeSourceIDs()
                return firstHeld && secondStarted && active == ["source-b"]
            }
            guard bag.all().count == 2 else { throw CoordinatorFixtureError.offerRejected }
            let firstDriver = bag.all()[0]
            let secondDriver = bag.all()[1]

            let firstCaptions = [
                RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-a",
                    sourceToken: firstCapture.source.input.sourceToken,
                    captureGeneration: firstCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "a-first",
                    sourceLanguageID: "en",
                    targetLanguageID: "zh-Hans",
                    sampleInterval: 0..<1
                ),
                RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-a",
                    sourceToken: firstCapture.source.input.sourceToken,
                    captureGeneration: firstCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "a-second",
                    sourceLanguageID: "en",
                    targetLanguageID: "zh-Hans",
                    sampleInterval: 1..<2
                ),
            ]
            let siblingCaptions = [
                RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-b",
                    sourceToken: secondCapture.source.input.sourceToken,
                    captureGeneration: secondCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "b-first",
                    sourceLanguageID: "yue",
                    targetLanguageID: "en",
                    sampleInterval: 0..<1
                ),
                RealtimeAcceptedCaptionMetadata(
                    sourceID: "source-b",
                    sourceToken: secondCapture.source.input.sourceToken,
                    captureGeneration: secondCapture.source.input.generation,
                    captionID: UUID(),
                    utteranceID: "b-second",
                    sourceLanguageID: "yue",
                    targetLanguageID: "en",
                    sampleInterval: 1..<2
                ),
            ]
            for caption in firstCaptions + siblingCaptions {
                #expect(await coordinator.submitAcceptedCaption(caption) == .queued)
            }
            try offer([1, 0, 2, 0], to: firstCapture, sampleInterval: 0..<2, captureTimestampNanoseconds: 101)
            try offer([3, 0, 4, 0], to: secondCapture, sampleInterval: 0..<2, captureTimestampNanoseconds: 202)

            try await requireCoordinatorCondition("ready source-b delivers its first caption before source-a setup") {
                let attempts = await secondDriver.commitInvocationCount()
                let commits = await secondDriver.committedUtterances()
                let subscribed = await secondDriver.hasEventSubscriber()
                return attempts == 1 && commits.count == 1 && subscribed
            }
            #expect(await firstDriver.sendInvocationCount() == 0)
            #expect(await startFinished.hasCompleted() == false)
            let bFirstCommit = await secondDriver.committedUtterances()[0]
            await secondDriver.yieldEvent(.correctedText(
                sourceAlias: bFirstCommit.sourceAlias,
                generation: bFirstCommit.generation,
                captionID: bFirstCommit.captionID,
                utteranceID: bFirstCommit.utteranceID,
                text: "b first corrected"
            ))
            try await requireCoordinatorCondition("source-b first correction is delivered locally") {
                events.all().count == 1
            }
            await secondDriver.yieldEvent(.utteranceCompleted(
                sourceAlias: bFirstCommit.sourceAlias,
                generation: bFirstCommit.generation,
                captionID: bFirstCommit.captionID,
                utteranceID: bFirstCommit.utteranceID
            ))
            try await requireCoordinatorCondition("source-b exact terminal releases its second caption") {
                await secondDriver.commitInvocationCount() == 2
            }
            let bSecondCommit = await secondDriver.committedUtterances()[1]
            await secondDriver.yieldEvent(.correctedText(
                sourceAlias: bSecondCommit.sourceAlias,
                generation: bSecondCommit.generation,
                captionID: firstCaptions[0].captionID,
                utteranceID: firstCaptions[0].utteranceID,
                text: "cross-source stale correction"
            ))
            await secondDriver.yieldEvent(.correctedText(
                sourceAlias: bSecondCommit.sourceAlias,
                generation: bSecondCommit.generation,
                captionID: bSecondCommit.captionID,
                utteranceID: bSecondCommit.utteranceID,
                text: "b second corrected"
            ))
            try await requireCoordinatorCondition("source-b second exact correction ignores source-a identity") {
                events.all().count == 3
            }
            await secondDriver.yieldEvent(.utteranceCompleted(
                sourceAlias: bSecondCommit.sourceAlias,
                generation: bSecondCommit.generation,
                captionID: bSecondCommit.captionID,
                utteranceID: bSecondCommit.utteranceID
            ))
            try await requireCoordinatorCondition("source-b terminal delivered before releasing source-a setup") {
                events.all().count == 4
            }
            #expect(await startFinished.hasCompleted() == false)
            #expect(events.all()[0].sourceID == "source-b")
            #expect(events.all()[0].sourceLanguageID == "yue")
            #expect(events.all()[0].targetLanguageID == "en")
            #expect(events.all()[0].kind == .correctedText("b first corrected"))
            #expect(events.all()[2].captionID == siblingCaptions[1].captionID)
            #expect(events.all()[2].kind == .correctedText("b second corrected"))
            #expect(events.all()[3].kind == .utteranceCompleted)

            await firstDriver.releaseStartSuccessfully()
            try await requireCoordinatorCondition("source-a setup release activates its independent readers") {
                await startFinished.hasCompleted()
            }
            let started = await startTask.value
            #expect(started.map(\.sourceID) == ["source-a", "source-b"])
            try await requireCoordinatorCondition("source-a first caption waits for its own audio admission") {
                let attempts = await firstDriver.commitInvocationCount()
                let commits = await firstDriver.committedUtterances()
                let subscribed = await firstDriver.hasEventSubscriber()
                return attempts == 1 && commits.count == 1 && subscribed
            }
            let aFirstCommit = await firstDriver.committedUtterances()[0]
            #expect(aFirstCommit.captionID == firstCaptions[0].captionID)
            #expect(aFirstCommit.startMonotonicNanoseconds == 0)
            #expect(aFirstCommit.endMonotonicNanoseconds == 62_500)
            await firstDriver.yieldEvent(.correctedText(
                sourceAlias: aFirstCommit.sourceAlias,
                generation: aFirstCommit.generation,
                captionID: aFirstCommit.captionID,
                utteranceID: aFirstCommit.utteranceID,
                text: "a first corrected"
            ))
            try await requireCoordinatorCondition("source-a first exact correction is delivered") {
                events.all().count == 5
            }
            await firstDriver.yieldEvent(.utteranceCompleted(
                sourceAlias: aFirstCommit.sourceAlias,
                generation: aFirstCommit.generation,
                captionID: aFirstCommit.captionID,
                utteranceID: aFirstCommit.utteranceID
            ))
            try await requireCoordinatorCondition("source-a first terminal releases its second caption") {
                await firstDriver.commitInvocationCount() == 2
            }
            let aSecondCommit = await firstDriver.committedUtterances()[1]
            await firstDriver.yieldEvent(.correctedText(
                sourceAlias: aSecondCommit.sourceAlias,
                generation: aSecondCommit.generation,
                captionID: aFirstCommit.captionID,
                utteranceID: aFirstCommit.utteranceID,
                text: "late source-a first correction"
            ))
            await firstDriver.yieldEvent(.correctedText(
                sourceAlias: aSecondCommit.sourceAlias,
                generation: aSecondCommit.generation,
                captionID: aSecondCommit.captionID,
                utteranceID: aSecondCommit.utteranceID,
                text: "a second corrected"
            ))
            try await requireCoordinatorCondition("source-a second correction ignores prior utterance") {
                events.all().count == 7
            }
            await firstDriver.yieldEvent(.utteranceCompleted(
                sourceAlias: aSecondCommit.sourceAlias,
                generation: aSecondCommit.generation,
                captionID: aSecondCommit.captionID,
                utteranceID: aSecondCommit.utteranceID
            ))
            try await requireCoordinatorCondition("all source-a captions complete in FIFO order") {
                events.all().count == 8
            }
            let delivered = events.all()
            #expect(delivered.map(\.sourceID) == ["source-b", "source-b", "source-b", "source-b", "source-a", "source-a", "source-a", "source-a"])
            #expect(delivered.map(\.captionID) == [
                siblingCaptions[0].captionID,
                siblingCaptions[0].captionID,
                siblingCaptions[1].captionID,
                siblingCaptions[1].captionID,
                firstCaptions[0].captionID,
                firstCaptions[0].captionID,
                firstCaptions[1].captionID,
                firstCaptions[1].captionID,
            ])
            #expect(delivered.map(\.sourceLanguageID) == ["yue", "yue", "yue", "yue", "en", "en", "en", "en"])
            #expect(delivered.map(\.targetLanguageID) == ["en", "en", "en", "en", "zh-Hans", "zh-Hans", "zh-Hans", "zh-Hans"])
            let aCommits = await firstDriver.committedUtterances()
            let bCommits = await secondDriver.committedUtterances()
            #expect(aCommits.map(\.utteranceID) == ["a-first", "a-second"])
            #expect(aCommits.map(\.startMonotonicNanoseconds) == [0, 62_500])
            #expect(aCommits.map(\.sourceAlias) == ["audio-1", "audio-1"])
            #expect(bCommits.map(\.utteranceID) == ["b-first", "b-second"])
            #expect(bCommits.map(\.startMonotonicNanoseconds) == [0, 62_500])
            #expect(bCommits.map(\.sourceAlias) == ["audio-2", "audio-2"])
        } catch {
            deferredError = error
        }
        for driver in bag.all() {
            await driver.releaseStartSuccessfully()
            await driver.releaseSendSuccessfully()
            await driver.releaseCommitSuccessfully()
            await driver.releaseSuspendedStop()
        }
        await coordinator.stop()
        _ = await startTask.value
        if let deferredError { throw deferredError }
    }

    @Test func stopRevokesDriverWhoseStartupIsStillSuspended() async throws {
        let bag = CoordinatorDriverBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: true)
                bag.append(driver)
                return driver
            }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        let startTask = Task {
            await coordinator.start(captures: [capture.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let driver = bag.all()[0]
        try await waitForCoordinatorCondition {
            return await driver.startInvocationCount() == 1
        }

        await coordinator.stop()
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(await driver.stopInvocationCount() >= 1)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(offerResult([1, 0], to: capture) == .closed)
    }

    @Test func removingSuspendedStartingSourceStillStartsItsSibling() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: bag.all().isEmpty)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let second = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            await coordinator.start(captures: [first.source, second.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 2 }
        let firstDriver = bag.all()[0]
        let siblingDriver = bag.all()[1]
        try await waitForCoordinatorCondition { await firstDriver.startInvocationCount() == 1 }
        try await waitForCoordinatorCondition { await siblingDriver.successfulStartCount() == 1 }

        await coordinator.removeSource(sourceID: "source-a")
        let started = await startTask.value

        #expect(started.count == 1)
        #expect(started.first?.sourceID == "source-b")
        #expect(await coordinator.activeSourceIDs() == ["source-b"])
        #expect(offerResult([1, 0], to: first) == .closed)
        try offer([2, 0], to: second)
        try await waitForCoordinatorCondition { await bag.all()[1].audioChunks().count == 1 }
        #expect(failures.all().isEmpty)
        await coordinator.stop()
    }

    @Test func removingNotYetStartedSourceTombstonesOnlyCurrentStartupGeneration() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a", "source-b"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(suspendStartUntilStop: bag.all().count < 2)
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let first = makeCoordinatorCapture(sourceID: "source-a")
        let second = makeCoordinatorCapture(sourceID: "source-b")
        let startTask = Task {
            await coordinator.start(captures: [first.source, second.source], settings: settings)
        }
        try await waitForCoordinatorCondition { bag.all().count == 2 }
        let firstDriver = bag.all()[0]
        let removedDriver = bag.all()[1]
        try await waitForCoordinatorCondition { await firstDriver.startInvocationCount() == 1 }
        try await waitForCoordinatorCondition { await removedDriver.startInvocationCount() == 1 }

        await coordinator.removeSource(sourceID: "source-b")

        #expect(offerResult([2, 0], to: second) == .closed)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(await removedDriver.stopInvocationCount() >= 1)
        await firstDriver.releaseStartSuccessfully()
        let firstRun = await startTask.value
        #expect(firstRun.count == 1)
        #expect(firstRun.first?.sourceID == "source-a")
        #expect(bag.all().count == 2)
        #expect(await coordinator.activeSourceIDs() == ["source-a"])
        #expect(failures.all().isEmpty)

        let nextGenerationCapture = makeCoordinatorCapture(sourceID: "source-b")
        let nextRun = await coordinator.start(
            captures: [nextGenerationCapture.source],
            settings: settings
        )
        #expect(nextRun.count == 1)
        #expect(nextRun.first?.sourceID == "source-b")
        #expect(nextRun[0].generation > firstRun[0].generation)
        #expect(await coordinator.activeSourceIDs() == ["source-b"])
        await coordinator.stop()
    }

    @Test func removedSourceDoesNotReportLateFailureAfterDriverStopSuspends() async throws {
        let bag = CoordinatorDriverBag()
        let failures = CoordinatorFailureBag()
        var settings = NativeRealtimeSettings.default
        settings.isEnabled = true
        settings.credentialReference = "fake-ref"
        settings.enabledSourceIDs = ["source-a"]
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: CoordinatorCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in
                let driver = CoordinatorFakeDriver(
                    sendFailure: .backpressure,
                    suspendStopUntilReleased: true
                )
                bag.append(driver)
                return driver
            },
            sourceFailureHandler: { sourceID, code in failures.append(sourceID, code) }
        )
        let capture = makeCoordinatorCapture(sourceID: "source-a")
        _ = await coordinator.start(captures: [capture.source], settings: settings)
        let driver = bag.all()[0]
        try offer([1, 0], to: capture)
        var removeTask: Task<Void, Never>?
        var deferredError: Error?
        do {
            try await requireCoordinatorCondition("first shared stop suspension") {
                let stopCount = await driver.stopInvocationCount()
                let isSuspended = await driver.isStopSuspended()
                return stopCount == 1 && isSuspended
            }
            #expect(await coordinator.audioFailureReportPendingForTesting(sourceID: "source-a"))
            removeTask = Task { await coordinator.removeSource(sourceID: "source-a") }
            try await requireCoordinatorCondition("removal revokes pending audio failure") {
                !(await coordinator.audioFailureReportPendingForTesting(sourceID: "source-a"))
            }
            #expect(failures.all().isEmpty)
            await driver.releaseSuspendedStop()
            await removeTask?.value
            await coordinator.waitForAudioFailureReportTasksForTesting()
            #expect(await coordinator.activeSourceIDs().isEmpty)
            #expect(failures.all().isEmpty)
        } catch {
            deferredError = error
        }
        await driver.releaseSuspendedStop()
        await removeTask?.value
        await coordinator.stop()
        if let deferredError { throw deferredError }
    }
}

private struct CoordinatorCaptureFixture {
    let source: NativeRealtimeCaptureSource
    let fanout: RealtimePCM16AudioFanout
    let sampleClock: CoordinatorSampleClock
}

private final class CoordinatorSampleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSample: Int64 = 0

    func reserve(frameCount: Int, explicit: Range<Int64>?) -> Range<Int64> {
        lock.lock()
        defer { lock.unlock() }
        guard frameCount > 0, let sampleCount = Int64(exactly: frameCount) else {
            return nextSample..<nextSample
        }
        if let explicit {
            if explicit.lowerBound >= 0, explicit.upperBound > nextSample {
                nextSample = explicit.upperBound
            }
            return explicit
        }
        let (upperBound, overflow) = nextSample.addingReportingOverflow(sampleCount)
        guard !overflow else { return nextSample..<nextSample }
        let interval = nextSample..<upperBound
        nextSample = upperBound
        return interval
    }
}

private func makeCoordinatorCapture(
    sourceID: String,
    maximumBufferedFrames: Int = 32_000
) -> CoordinatorCaptureFixture {
    let token = UUID()
    let fanout = RealtimePCM16AudioFanout(
        sourceToken: token,
        generation: 3,
        maximumBufferedFrames: maximumBufferedFrames
    )
    let input = fanout.makeInput()!
    return CoordinatorCaptureFixture(
        source: NativeRealtimeCaptureSource(
            sourceID: sourceID,
            role: .microphone,
            input: input
        ),
        fanout: fanout,
        sampleClock: CoordinatorSampleClock()
    )
}

private func offer(
    _ bytes: [UInt8],
    to capture: CoordinatorCaptureFixture,
    sampleInterval: Range<Int64>? = nil,
    captureTimestampNanoseconds: UInt64? = nil
) throws {
    let result = offerResult(
        bytes,
        to: capture,
        sampleInterval: sampleInterval,
        captureTimestampNanoseconds: captureTimestampNanoseconds
    )
    guard result == .enqueued else { throw CoordinatorFixtureError.offerRejected }
}

private func offerResult(
    _ bytes: [UInt8],
    to capture: CoordinatorCaptureFixture,
    sampleInterval: Range<Int64>? = nil,
    captureTimestampNanoseconds: UInt64? = nil
) -> RealtimePCM16AudioOfferResult {
    let frameCount = bytes.count / 2
    let reservedInterval = capture.sampleClock.reserve(frameCount: frameCount, explicit: sampleInterval)
    return capture.fanout.offer(
        pcm16LE: Data(bytes),
        frameCount: frameCount,
        sampleInterval: reservedInterval,
        sourceToken: capture.source.input.sourceToken,
        generation: capture.source.input.generation,
        captureTimestampNanoseconds: captureTimestampNanoseconds ?? (bytes.first == 1 ? 101 : 202)
    )
}

private func waitForCoordinatorCondition(
    _ label: String = "coordinator reader",
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    guard try await coordinatorConditionIsMet(condition) else {
        Issue.record("Timed out waiting for \(label)")
        return
    }
}

private func requireCoordinatorCondition(
    _ label: String,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    guard try await coordinatorConditionIsMet(condition) else {
        throw CoordinatorFixtureError.conditionTimedOut(label)
    }
}

private func coordinatorConditionIsMet(
    _ condition: @escaping @Sendable () async -> Bool
) async throws -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private enum CoordinatorFixtureError: Error {
    case offerRejected
    case conditionTimedOut(String)
}

private actor CoordinatorCredentialBackend: RealtimeCredentialBackend {
    private let secret: String?
    private var lookupCountStorage = 0

    init(secret: String?) { self.secret = secret }

    func put(reference: String, secret: String) async throws {}
    func get(reference: String) async throws -> String? {
        lookupCountStorage += 1
        return secret
    }
    func remove(reference: String) async throws {}
    func lookupCount() -> Int { lookupCountStorage }
}

private actor SuspendingCoordinatorCredentialBackend: RealtimeCredentialBackend {
    private var lookupCountStorage = 0
    private var lookupContinuation: CheckedContinuation<String?, any Error>?

    func put(reference: String, secret: String) async throws {}
    func get(reference: String) async throws -> String? {
        lookupCountStorage += 1
        return try await withCheckedThrowingContinuation { continuation in
            lookupContinuation = continuation
        }
    }
    func remove(reference: String) async throws {}
    func lookupCount() -> Int { lookupCountStorage }

    func releaseLookup(with secret: String?) {
        guard let continuation = lookupContinuation else { return }
        lookupContinuation = nil
        continuation.resume(returning: secret)
    }
}

private final class CoordinatorDriverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [CoordinatorFakeDriver] = []

    func append(_ driver: CoordinatorFakeDriver) {
        lock.lock()
        drivers.append(driver)
        lock.unlock()
    }

    func all() -> [CoordinatorFakeDriver] {
        lock.lock()
        defer { lock.unlock() }
        return drivers
    }
}

private final class CoordinatorFailureBag: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [(String, RealtimeFailureCode)] = []

    func append(_ sourceID: String, _ code: RealtimeFailureCode) {
        lock.lock()
        failures.append((sourceID, code))
        lock.unlock()
    }

    func all() -> [(String, RealtimeFailureCode)] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

private final class CoordinatorCaptionDispositionBag: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [(RealtimeAcceptedCaptionMetadata, RealtimeCaptionSubmissionDisposition)] = []

    func append(
        _ metadata: RealtimeAcceptedCaptionMetadata,
        _ disposition: RealtimeCaptionSubmissionDisposition
    ) {
        lock.lock()
        results.append((metadata, disposition))
        lock.unlock()
    }

    func all() -> [(metadata: RealtimeAcceptedCaptionMetadata, disposition: RealtimeCaptionSubmissionDisposition)] {
        lock.lock()
        defer { lock.unlock() }
        return results.map { (metadata: $0.0, disposition: $0.1) }
    }
}

private final class CoordinatorCaptionEventBag: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RealtimeCaptionEventEnvelope] = []

    func append(_ event: RealtimeCaptionEventEnvelope) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func all() -> [RealtimeCaptionEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor CoordinatorCompletionFlag {
    private var completed = false

    func markComplete() { completed = true }
    func hasCompleted() -> Bool { completed }
}

private final class CoordinatorTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.lock()
        signaled = true
        lock.unlock()
    }

    func isSignaled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

private actor CoordinatorReleaseGate {
    private var didRelease = false
    private var suspensionCount = 0
    private var suspensionContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        guard !didRelease else { return }
        suspensionCount += 1
        await withCheckedContinuation { continuation in
            suspensionContinuations.append(continuation)
        }
    }

    func hasSuspended() -> Bool {
        suspensionCount > 0 && !didRelease
    }

    func resume() {
        didRelease = true
        let continuations = suspensionContinuations
        suspensionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor CoordinatorFakeDriver: RealtimeSessionDriving {
    private let startFailure: Bool
    private let sendFailure: RealtimeFailureCode?
    private let suspendSendUntilStop: Bool
    private var shouldSuspendSendUntilReleased: Bool
    private var shouldSuspendCommitUntilReleased: Bool
    private let suspendStartUntilStop: Bool
    private let stopReleasesStart: Bool
    private let suspendFirstStopUntilSecondCall: Bool
    private let suspendStopUntilReleased: Bool
    private let factoryEnabledSourceIDs: [String]
    private var receivedAudio: [RealtimeAudioChunk] = []
    private var receivedUtterances: [RealtimeUtterance] = []
    private var eventContinuation: AsyncStream<RealtimeProviderEvent>.Continuation?
    private var didStop = false
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var sendContinuation: CheckedContinuation<Void, any Error>?
    private var commitContinuation: CheckedContinuation<RealtimeFailureCode?, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var explicitlySuspendedStopContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasReleasedExplicitStop = false
    private var startInvocationCountStorage = 0
    private var successfulStartCountStorage = 0
    private var sendInvocationCountStorage = 0
    private var commitInvocationCountStorage = 0
    private var stopInvocationCountStorage = 0
    private var didCompleteStartStorage = false
    private var postStartResultStopCountStorage = 0

    init(
        startFailure: Bool = false,
        sendFailure: RealtimeFailureCode? = nil,
        suspendSendUntilStop: Bool = false,
        suspendSendUntilReleased: Bool = false,
        suspendCommitUntilReleased: Bool = false,
        suspendStartUntilStop: Bool = false,
        stopReleasesStart: Bool = true,
        suspendFirstStopUntilSecondCall: Bool = false,
        suspendStopUntilReleased: Bool = false,
        factoryEnabledSourceIDs: [String] = []
    ) {
        self.startFailure = startFailure
        self.sendFailure = sendFailure
        self.suspendSendUntilStop = suspendSendUntilStop
        self.shouldSuspendSendUntilReleased = suspendSendUntilReleased
        self.shouldSuspendCommitUntilReleased = suspendCommitUntilReleased
        self.suspendStartUntilStop = suspendStartUntilStop
        self.stopReleasesStart = stopReleasesStart
        self.suspendFirstStopUntilSecondCall = suspendFirstStopUntilSecondCall
        self.suspendStopUntilReleased = suspendStopUntilReleased
        self.factoryEnabledSourceIDs = factoryEnabledSourceIDs
    }

    func start(sourceAlias: String, generation: Int) async throws {
        startInvocationCountStorage += 1
        defer { didCompleteStartStorage = true }
        if suspendStartUntilStop {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        }
        if startFailure { throw RealtimeFailureCode.connectionFailed }
        successfulStartCountStorage += 1
    }

    func releaseStartSuccessfully() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume()
    }
    func isStartSuspended() -> Bool { startContinuation != nil }
    func successfulStartCount() -> Int { successfulStartCountStorage }
    func postStartResultStopCount() -> Int { postStartResultStopCountStorage }
    func isSendSuspended() -> Bool { sendContinuation != nil }
    func releaseSendSuccessfully() {
        shouldSuspendSendUntilReleased = false
        guard let continuation = sendContinuation else { return }
        sendContinuation = nil
        continuation.resume()
    }
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws {
        sendInvocationCountStorage += 1
        if shouldSuspendSendUntilReleased || suspendSendUntilStop {
            try await withCheckedThrowingContinuation { continuation in
                sendContinuation = continuation
            }
        }
        if let sendFailure { throw sendFailure }
        receivedAudio.append(chunk)
    }
    func commit(_ utterance: RealtimeUtterance) async throws {
        commitInvocationCountStorage += 1
        if shouldSuspendCommitUntilReleased {
            shouldSuspendCommitUntilReleased = false
            let failure = await withCheckedContinuation { continuation in
                commitContinuation = continuation
            }
            if let failure { throw failure }
        }
        receivedUtterances.append(utterance)
    }
    func commitInvocationCount() -> Int { commitInvocationCountStorage }
    func isCommitSuspended() -> Bool { commitContinuation != nil }
    func releaseCommitSuccessfully() {
        shouldSuspendCommitUntilReleased = false
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: nil)
    }
    func releaseCommitFailure(_ failure: RealtimeFailureCode) {
        shouldSuspendCommitUntilReleased = false
        let continuation = commitContinuation
        commitContinuation = nil
        continuation?.resume(returning: failure)
    }
    func sendVideoFrame(_ frame: RealtimeVideoFrame) async throws {}
    func revokeVideoPermission() async {}
    func events() async -> AsyncStream<RealtimeProviderEvent> {
        AsyncStream { continuation in
            if didStop {
                continuation.finish()
            } else {
                eventContinuation = continuation
            }
        }
    }
    func yieldEvent(_ event: RealtimeProviderEvent) {
        eventContinuation?.yield(event)
    }
    func hasEventSubscriber() -> Bool { eventContinuation != nil }
    func finishEvents() {
        let continuation = eventContinuation
        eventContinuation = nil
        continuation?.finish()
    }
    func stop() async {
        stopInvocationCountStorage += 1
        didStop = true
        finishEvents()
        if didCompleteStartStorage { postStartResultStopCountStorage += 1 }
        if stopReleasesStart, let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: RealtimeFailureCode.connectionFailed)
        }
        if !shouldSuspendSendUntilReleased, let continuation = sendContinuation {
            sendContinuation = nil
            continuation.resume(throwing: RealtimeFailureCode.connectionFailed)
        }
        if suspendStopUntilReleased, !hasReleasedExplicitStop {
            await withCheckedContinuation { continuation in
                explicitlySuspendedStopContinuations.append(continuation)
            }
        } else if suspendFirstStopUntilSecondCall, stopInvocationCountStorage == 1 {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        } else if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }
    }
    func audioChunks() -> [RealtimeAudioChunk] { receivedAudio }
    func committedUtterances() -> [RealtimeUtterance] { receivedUtterances }
    func sendInvocationCount() -> Int { sendInvocationCountStorage }
    func startInvocationCount() -> Int { startInvocationCountStorage }
    func stopInvocationCount() -> Int { stopInvocationCountStorage }
    func isStopSuspended() -> Bool {
        stopContinuation != nil || explicitlySuspendedStopContinuations.isEmpty == false
    }
    func releaseSuspendedStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
        let continuations = explicitlySuspendedStopContinuations
        explicitlySuspendedStopContinuations.removeAll()
        hasReleasedExplicitStop = true
        continuations.forEach { $0.resume() }
    }
    func factorySettingsEnabledSources() -> [String] { factoryEnabledSourceIDs }
}
