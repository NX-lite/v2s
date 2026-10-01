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
            pcm16LEData: Data([1, 0]),
            sampleRate: 16_000
        )])
        #expect(secondChunks == [RealtimeAudioChunk(
            sourceAlias: "audio-2",
            generation: started[1].generation,
            capturedAtMonotonicNanoseconds: 202,
            pcm16LEData: Data([2, 0]),
            sampleRate: 16_000
        )])
        await coordinator.stop()
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
        await backend.releaseLookup(with: "fake-secret")
        let started = await startTask.value

        #expect(started.isEmpty)
        #expect(bag.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().count == 1)
        #expect(failures.all().first?.0 == "source-a")
        #expect(failures.all().first?.1 == .backpressure)
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
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let firstDriver = bag.all()[0]
        try await waitForCoordinatorCondition { await firstDriver.startInvocationCount() == 1 }

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
        try await waitForCoordinatorCondition { bag.all().count == 1 }
        let firstDriver = bag.all()[0]
        try await waitForCoordinatorCondition { await firstDriver.startInvocationCount() == 1 }

        await coordinator.removeSource(sourceID: "source-b")

        #expect(offerResult([2, 0], to: second) == .closed)
        await firstDriver.releaseStartSuccessfully()
        let firstRun = await startTask.value
        #expect(firstRun.count == 1)
        #expect(firstRun.first?.sourceID == "source-a")
        #expect(bag.all().count == 1)
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
                    suspendFirstStopUntilSecondCall: true
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
        try await waitForCoordinatorCondition { await driver.stopInvocationCount() == 1 }

        await coordinator.removeSource(sourceID: "source-a")

        #expect(await coordinator.activeSourceIDs().isEmpty)
        #expect(failures.all().isEmpty)
    }
}

private struct CoordinatorCaptureFixture {
    let source: NativeRealtimeCaptureSource
    let fanout: RealtimePCM16AudioFanout
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
        fanout: fanout
    )
}

private func offer(_ bytes: [UInt8], to capture: CoordinatorCaptureFixture) throws {
    let result = offerResult(bytes, to: capture)
    guard result == .enqueued else { throw CoordinatorFixtureError.offerRejected }
}

private func offerResult(
    _ bytes: [UInt8],
    to capture: CoordinatorCaptureFixture
) -> RealtimePCM16AudioOfferResult {
    capture.fanout.offer(
        pcm16LE: Data(bytes),
        frameCount: bytes.count / 2,
        sourceToken: capture.source.input.sourceToken,
        generation: capture.source.input.generation,
        captureTimestampNanoseconds: bytes.first == 1 ? 101 : 202
    )
}

private func waitForCoordinatorCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for coordinator reader")
}

private enum CoordinatorFixtureError: Error {
    case offerRejected
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

private actor CoordinatorFakeDriver: RealtimeSessionDriving {
    private let startFailure: Bool
    private let sendFailure: RealtimeFailureCode?
    private let suspendSendUntilStop: Bool
    private let suspendStartUntilStop: Bool
    private let suspendFirstStopUntilSecondCall: Bool
    private let factoryEnabledSourceIDs: [String]
    private var receivedAudio: [RealtimeAudioChunk] = []
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var sendContinuation: CheckedContinuation<Void, any Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startInvocationCountStorage = 0
    private var sendInvocationCountStorage = 0
    private var stopInvocationCountStorage = 0

    init(
        startFailure: Bool = false,
        sendFailure: RealtimeFailureCode? = nil,
        suspendSendUntilStop: Bool = false,
        suspendStartUntilStop: Bool = false,
        suspendFirstStopUntilSecondCall: Bool = false,
        factoryEnabledSourceIDs: [String] = []
    ) {
        self.startFailure = startFailure
        self.sendFailure = sendFailure
        self.suspendSendUntilStop = suspendSendUntilStop
        self.suspendStartUntilStop = suspendStartUntilStop
        self.suspendFirstStopUntilSecondCall = suspendFirstStopUntilSecondCall
        self.factoryEnabledSourceIDs = factoryEnabledSourceIDs
    }

    func start(sourceAlias: String, generation: Int) async throws {
        startInvocationCountStorage += 1
        if suspendStartUntilStop {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        }
        if startFailure { throw RealtimeFailureCode.connectionFailed }
    }

    func releaseStartSuccessfully() {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume()
    }
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws {
        sendInvocationCountStorage += 1
        if suspendSendUntilStop {
            try await withCheckedThrowingContinuation { continuation in
                sendContinuation = continuation
            }
        }
        if let sendFailure { throw sendFailure }
        receivedAudio.append(chunk)
    }
    func commit(_ utterance: RealtimeUtterance) async throws {}
    func sendVideoFrame(_ frame: RealtimeVideoFrame) async throws {}
    func revokeVideoPermission() async {}
    func events() async -> AsyncStream<RealtimeProviderEvent> { AsyncStream { _ in } }
    func stop() async {
        stopInvocationCountStorage += 1
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: RealtimeFailureCode.connectionFailed)
        }
        if let continuation = sendContinuation {
            sendContinuation = nil
            continuation.resume(throwing: RealtimeFailureCode.connectionFailed)
        }
        if suspendFirstStopUntilSecondCall, stopInvocationCountStorage == 1 {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        } else if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume()
        }
    }
    func audioChunks() -> [RealtimeAudioChunk] { receivedAudio }
    func sendInvocationCount() -> Int { sendInvocationCountStorage }
    func startInvocationCount() -> Int { startInvocationCountStorage }
    func stopInvocationCount() -> Int { stopInvocationCountStorage }
    func factorySettingsEnabledSources() -> [String] { factoryEnabledSourceIDs }
}
