import AVFoundation
import Foundation
import Testing
@testable import v2s

@MainActor
@Suite struct AppModelCorrectionIntegrationTests {
    @Test func unrelatedAppModelPersistencePreservesNativeRealtimeConfiguration() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let store = SettingsStore(fileURL: settingsURL)
        var settings = AppSettings.default
        settings.nativeRealtime.isEnabled = true
        settings.nativeRealtime.enabledSourceIDs = ["mic-1"]
        settings.nativeRealtime.profile = .qwenOmniFlash
        settings.nativeRealtime.region = .singapore
        settings.nativeRealtime.qwenWorkspaceID = "workspace-123"
        store.save(settings)

        let model = AppModel(
            settingsStore: store,
            sourceCatalogService: TestSourceCatalogService(microphones: [microphoneSource])
        )
        #expect(model.nativeRealtimeSettings == settings.nativeRealtime)
        model.glossary = ["hello": "world"]
        #expect(store.load().nativeRealtime == settings.nativeRealtime)
    }

    @Test func persistedNativeProfileCannotStartWithoutSessionOnlyDisclosureAuthorization() async throws {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        var settings = makeAppSettings(correction: .default)
        settings.selectedSourceIDs = [microphoneSource.id]
        settings.nativeRealtime.isEnabled = true
        settings.nativeRealtime.enabledSourceIDs = [microphoneSource.id]
        settings.nativeRealtime.credentialReference = "test-native-key"
        let store = SettingsStore(fileURL: settingsURL)
        store.save(settings)

        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let model = AppModel(
            settingsStore: store,
            sourceCatalogService: TestSourceCatalogService(microphones: [microphoneSource]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        model.selectedSourceIDs = [microphoneSource.id]
        model.setSessionResourcePreparationOperationForTesting {}
        var createdSessions: [LiveTranscriptionSession] = []
        model.setLiveTranscriptionSessionFactoryForTesting {
            let session = LiveTranscriptionSession()
            session.setStartOperationForTesting {
                await session.beginRecognitionSessionForTesting()
            }
            createdSessions.append(session)
            return session
        }

        await model.startSession()

        #expect(model.sessionState == .running)
        #expect(model.registeredLiveSessionForTesting(sourceID: microphoneSource.id) === createdSessions.first)
        #expect(drivers.all().isEmpty)
        #expect(await credentials.lookupCount() == 0)
        model.stopSession()

        model.acknowledgeNativeRealtimeDisclosureForNextSession()
        await model.startSession()

        #expect(model.sessionState == .running)
        #expect(drivers.all().count == 1)
        #expect(await credentials.lookupCount() == 1)
        model.stopSession()
        await coordinator.stop()
    }

    @Test func acceptedLegacyFinalDuringInstalledInputRegistrationGapTransfersExactProvenance() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translationGate = AsyncTestGate()
        fixture.model.pauseCaptionTranslationForTesting {
            await translationGate.suspend()
        }
        let registrationGate = fixture.model.pauseNextNativeCoordinatorRegistrationForTesting()
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            await registrationGate.release()
            await startTask.value
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            for task in translationTasks + transferTasks { task.cancel() }
            displayTask?.cancel()
            fixture.model.stopSession()
            await translationGate.resume()
            for task in translationTasks { await task.value }
            for task in transferTasks { await task.value }
            await displayTask?.value
            await coordinator.stop()
            await startTask.value
        }

        do {
            try await registrationGate.waitUntilReached(timeoutNanoseconds: 8_000_000_000)
            await session.resetCorrectionAudioCapture(enabled: false)
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "registration gap final",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)],
                promotionSegmentID: UUID()
            ))
            #expect(fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === session)
            await session.deliverQueuedCommittedEmissionForTesting()
            #expect(fixture.model.acceptedFinalDeliveryCountForTesting == 1)
            #expect(fixture.model.transcriptEntries.contains { $0.sourceText == "registration gap final" })
            try await translationGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)

            await registrationGate.release()
            await startTask.value
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.0 == 1)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.2 == 1)
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            try await waitUntil {
                fixture.model.transcriptEntries.contains { $0.sourceText == "registration gap final" }
            }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sourceID == fixture.microphone.id)
            #expect(accepted.captionID == fixture.model.transcriptEntries.first?.id)
            #expect(accepted.sourceLanguageID == "en")
            #expect(accepted.targetLanguageID == "en")
            #expect(accepted.sampleInterval == 0..<2)
            #expect(UUID(uuidString: accepted.utteranceID) != nil)
            fixture.model.deliverNativeCaptureRegistrationForTesting(RealtimeCaptureRegistration(
                sourceID: accepted.sourceID,
                sourceToken: accepted.sourceToken,
                captureGeneration: accepted.captureGeneration &- 1
            ))
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.0 == 1)
            #expect(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: accepted.sourceID) == accepted)

            var legacySettings = fixture.model.correction.settings
            legacySettings.apiKey = "edited legacy key"
            legacySettings.baseURL = "https://legacy.example/v1"
            legacySettings.model = "legacy-model"
            legacySettings.isEnabled = true
            legacySettings.disabledSourceIDs = [fixture.microphone.id]
            legacySettings.isolatedContextSourceIDs = [fixture.microphone.id]
            fixture.model.correction.settings = legacySettings
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "after legacy configuration edit",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            #expect(fixture.model.acceptedFinalDeliveryCountForTesting == 2)
            #expect(fixture.model.pendingCaptionCountForTesting > 0)
            let acceptedBindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID)
            #expect(acceptedBindings.count == 2)
            #expect(acceptedBindings.last?.sampleInterval == 2..<4)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func nativeCorrectionAppliedWhileOriginalTranslationIsHeldSurvivesQueueWrite() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translationTasks + correctionTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in translationTasks + correctionTasks + transferTasks { await task.value }
            await displayTask?.value
        }

        var stage = "trusted-ready callback"
        do {
            try await waitUntil {
                fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil
            }
            stage = "actual accepted final"
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "original-A",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sourceToken == ready.sourceToken)
            #expect(accepted.captureGeneration == ready.captureGeneration)
            stage = "original translation held"
            try await waitUntil { await translations.hasRequest(text: "original-A") }
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                    == "original-A"
            }
            let originalEntryBeforeCorrection = try #require(
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })
            )
            #expect(originalEntryBeforeCorrection.id == accepted.captionID)
            #expect(originalEntryBeforeCorrection.sourceText == "original-A")
            #expect(originalEntryBeforeCorrection.localSourceText == "original-A")
            stage = "driver subscribed and commit succeeded"
            try await waitUntil {
                guard let driver = drivers.all().first else { return false }
                let committedCount = await driver.committedUtteranceCount()
                let listening = await driver.isListeningForEvents()
                return committedCount == 1 && listening
            }
            let driver = try #require(drivers.all().first)
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "corrected-A"
            ))
            stage = "corrected translation requested by AppModel"
            try await waitUntil { await translations.hasRequest(text: "corrected-A") }
            await translations.release(text: "corrected-A", result: "translated-corrected-A")
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText == "corrected-A"
            }
            await translations.release(text: "original-A", result: "translated-original-A")
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localTranslatedText == "translated-original-A"
            }
            let entry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(entry.sourceText == "corrected-A")
            #expect(entry.translatedText == "translated-corrected-A")
            #expect(entry.localSourceText == "original-A")
            #expect(entry.localTranslatedText == "translated-original-A")
            #expect(fixture.model.overlayState?.sourceText == "corrected-A")
            #expect(fixture.model.overlayState?.translatedText == "translated-corrected-A")

            stage = "native pending suppresses the existing local target fallback"
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "corrected-A-pending"
            ))
            try await waitUntil { await translations.hasRequest(text: "corrected-A-pending") }
            let pendingEntry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(pendingEntry.localTranslatedText == "translated-original-A")
            #expect(pendingEntry.translatedText.isEmpty)
            #expect(fixture.model.overlayState?.translatedText.isEmpty == true)
            await translations.release(text: "corrected-A-pending", result: nil)
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .failed
            }
            let failedEntry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(failedEntry.localTranslatedText == "translated-original-A")
            #expect(failedEntry.translatedText.isEmpty)
            #expect(fixture.model.overlayState?.translatedText.isEmpty == true)

            stage = "clear transcript revokes a held native correction"
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "corrected-A-cleared"
            ))
            try await waitUntil { await translations.hasRequest(text: "corrected-A-cleared") }
            let heldCorrectionTask = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            fixture.model.clearTranscript()
            #expect(fixture.model.transcriptEntries.isEmpty)
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil)
            await translations.release(text: "corrected-A-cleared", result: "must-not-resurrect")
            await heldCorrectionTask.value
            #expect(fixture.model.transcriptEntries.isEmpty)
            #expect(fixture.model.overlayState?.translatedText.isEmpty == true)
        } catch {
            print("nativeCorrection RED stage: \(stage); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func finishedInputFencesHeldNativeCorrectionAndStaleEventBeforeFailureCallback() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            if text == "input dead accepted correction" || text == "stale event after input death" {
                return try await translations.translate(text, source: source, target: target)
            }
            return "local translation for \(text)"
        }
        let startTask = Task { await fixture.model.startSession() }
        var heldCorrectionTask: Task<Void, Never>?
        func cleanup() async {
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            heldCorrectionTask?.cancel()
            (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await translations.releaseAll()
            if let driver = drivers.all().first { await driver.resumeStop() }
            fixture.model.finishNativeCaptureInputForTesting(
                sourceID: fixture.microphone.id,
                error: .sourceSuperseded
            )
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in correctionTasks + translationTasks + transferTasks { await task.value }
            await heldCorrectionTask?.value
            await displayTask?.value
        }

        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            await startTask.value
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "input dead original accepted caption",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            let driver = try #require(drivers.all().first)
            try await waitUntil { await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID) }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "input dead accepted correction"
            ))
            try await waitUntil { await translations.hasRequest(text: "input dead accepted correction") }
            let savedCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            heldCorrectionTask = savedCorrectionTask
            let acceptedSource = fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.sourceText
            #expect(acceptedSource == "input dead accepted correction")

            await driver.suspendNextStop()
            fixture.model.finishNativeCaptureInputForTesting(
                sourceID: accepted.sourceID,
                error: .invalidAudioChunk
            )
            try await waitUntil { await driver.isStopSuspended() }
            let inputState = try #require(fixture.model.nativeCaptureInputStateForTesting(sourceID: accepted.sourceID))
            #expect(inputState.isConsumed)
            #expect(inputState.terminationError == .invalidAudioChunk)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.0 == 1)
            #expect(fixture.model.nativeReadyIdentityForTesting(sourceID: accepted.sourceID) == ready)
            #expect(heldCorrectionTask?.isCancelled == false)

            await translations.release(text: "input dead accepted correction", result: "late translation after input death")
            await heldCorrectionTask?.value
            let afterHeldResult = try #require(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID))
            #expect(afterHeldResult.sourceText == "input dead accepted correction")
            #expect(afterHeldResult.state == .pending)
            #expect(afterHeldResult.translatedText == nil)

            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: accepted.sourceID,
                sourceToken: accepted.sourceToken,
                captureGeneration: accepted.captureGeneration,
                sourceAlias: ready.alias,
                driverGeneration: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                sourceLanguageID: accepted.sourceLanguageID,
                targetLanguageID: accepted.targetLanguageID,
                kind: .correctedText("stale event after input death")
            ))
            let staleEventRequestCount = await translations.requestCount(text: "stale event after input death")
            #expect(staleEventRequestCount == 0)
            let afterDeadInput = try #require(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID))
            #expect(afterDeadInput.sourceText == "input dead accepted correction")
            #expect(afterDeadInput.state == .pending)
            #expect(afterDeadInput.translatedText == nil)

            await driver.resumeStop()
            try await waitUntil(timeout: .seconds(5)) {
                fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID).isEmpty
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func terminalNativeEventLeavesAcceptedCorrectionTranslationRunning() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            if text == "terminal native correction" {
                return try await translations.translate(text, source: source, target: target)
            }
            return "local translation for \(text)"
        }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in correctionTasks + translationTasks + transferTasks { await task.value }
            await displayTask?.value
        }

        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "terminal original local caption",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            let driver = try #require(drivers.all().first)
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID)
            }

            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "terminal native correction"
            ))
            try await waitUntil { await translations.hasRequest(text: "terminal native correction") }
            let correctionTask = try #require(fixture.model.nativeCorrectionTasksSnapshotForTesting().first)
            await driver.emit(.utteranceCompleted(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID
            ))
            try await waitUntil { fixture.model.nativeTerminalEventReceivedForTesting(captionID: accepted.captionID) }
            #expect(correctionTask.isCancelled == false)
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .pending)
            await translations.release(text: "terminal native correction", result: "terminal correction translation")
            await correctionTask.value
            let snapshot = try #require(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID))
            #expect(snapshot.state == .ready)
            #expect(snapshot.translatedText == "terminal correction translation")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func deinitializingAppCancelsHeldNativeCorrectionTranslation() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        var fixture: CorrectionFixture? = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator,
            refreshLanguageCatalogs: false,
            sourceLanguageOverrides: [microphoneSource.id: "en"],
            sourceOutputLanguageOverrides: [microphoneSource.id: "zh-Hans"]
        )
        let settingsURL = fixture!.settingsURL
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let weakModel = IntegrationWeakAppModelReference(fixture!.model)
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture!.model.selectedSourceIDs = [fixture!.microphone.id]
        fixture!.model.setSessionResourcePreparationOperationForTesting {}
        fixture!.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture!.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture!.model.setTranslationOperationForTesting { text, source, target in
            if text == "deinit held native correction" {
                return try await translations.translate(text, source: source, target: target)
            }
            return "local translation for \(text)"
        }
        var startModel: AppModel? = fixture!.model
        let startTask = Task { await startModel?.startSession() }
        var correctionTask: Task<Void, Never>?
        var stage = "ready and accepted input"

        do {
            try await waitUntil { fixture!.model.nativeReadyIdentityForTesting(sourceID: fixture!.microphone.id) != nil }
            let ready = try #require(fixture!.model.nativeReadyIdentityForTesting(sourceID: fixture!.microphone.id))
            await startTask.value
            startModel = nil
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "deinit native original",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture!.model.nativeAcceptedMetadataForTesting(sourceID: fixture!.microphone.id) != nil }
            let accepted = try #require(await fixture!.model.nativeAcceptedMetadataForTesting(sourceID: fixture!.microphone.id))
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID)
            }
            stage = "original local translation and display tasks complete"
            try await waitUntil {
                fixture!.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                    == "deinit native original"
            }
            do {
                let localTranslationTasks = fixture!.model.captionTranslationTasksSnapshotForTesting()
                let localDisplayTask = fixture!.model.captionDisplayTaskSnapshotForTesting()
                for task in localTranslationTasks { await task.value }
                await localDisplayTask?.value
                let archiveTask = fixture!.model.committedCaptionArchiveTaskSnapshotForTesting()
                fixture!.model.cancelCommittedCaptionArchiveForTesting()
                await archiveTask?.value
            }
            let driver = try #require(drivers.all().first)
            stage = "native corrected translation held"
            let readyTask = fixture!.model.nativeSourceReadyTaskSnapshotForTesting(sourceID: fixture!.microphone.id)
            let transferTasks = fixture!.model.nativeCaptionTransferTasksSnapshotForTesting()
            for task in transferTasks { await task.value }
            await readyTask?.value
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "deinit held native correction"
            ))
            try await waitUntil { await translations.hasRequest(text: "deinit held native correction") }
            let savedCorrectionTask: Task<Void, Never> = try #require(
                fixture!.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            correctionTask = savedCorrectionTask
            #expect(correctionTask?.isCancelled == false)
            #expect(fixture!.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .pending)

            stage = "model deinit cancels held correction task"
            fixture = nil
            try await waitUntil(timeout: .seconds(5)) { weakModel.value == nil }
            #expect(correctionTask?.isCancelled == true)
            await translations.release(text: "deinit held native correction", result: "must-not-complete-after-deinit")
            await correctionTask?.value
            #expect(weakModel.value == nil)
            #expect(correctionTask?.isCancelled == true)
        } catch {
            print("native correction deinit stage: \(stage); weak model alive=\(weakModel.value != nil), cancelled=\(correctionTask?.isCancelled ?? false)")
            correctionTask?.cancel()
            await translations.releaseAll()
            if let model = fixture?.model {
                let correctionTasks = model.nativeCorrectionTasksSnapshotForTesting()
                let translationTasks = model.captionTranslationTasksSnapshotForTesting()
                let transferTasks = model.nativeCaptionTransferTasksSnapshotForTesting()
                let displayTask = model.captionDisplayTaskSnapshotForTesting()
                (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
                displayTask?.cancel()
                model.stopSession()
                await coordinator.stop()
                await startTask.value
                for task in correctionTasks + translationTasks + transferTasks { await task.value }
                await displayTask?.value
            }
            await correctionTask?.value
            throw error
        }
        await translations.releaseAll()
        await coordinator.stop()
        await correctionTask?.value
    }

    @Test func nativeCorrectionReadyBeforeFirstQueueWriteSurvivesBothWrites() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let queueGate = AsyncTestGate()
        fixture.model.pauseBeforeNextCaptionQueueInitialWriteForTesting {
            await queueGate.suspend()
        }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translationTasks + correctionTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await queueGate.resume()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in translationTasks + correctionTasks + transferTasks { await task.value }
            await displayTask?.value
        }

        var stage = "queue before first write"
        var acceptedCaptionID: UUID?
        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "original-before-upsert",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await queueGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            try await waitUntil { await translations.hasRequest(text: "original-before-upsert") }
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            acceptedCaptionID = accepted.captionID
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sourceToken == ready.sourceToken)
            #expect(accepted.captureGeneration == ready.captureGeneration)
            #expect(fixture.model.transcriptEntries.contains { $0.id == accepted.captionID } == false)
            let driver = try #require(drivers.all().first)
            try await waitUntil {
                let committedCount = await driver.committedUtteranceCount()
                let listening = await driver.isListeningForEvents()
                return committedCount == 1 && listening
            }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "corrected-before-upsert"
            ))
            stage = "corrected translation ready before first write"
            try await waitUntil { await translations.hasRequest(text: "corrected-before-upsert") }
            await translations.release(text: "corrected-before-upsert", result: "translated-before-upsert")
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .ready
            }
            #expect(fixture.model.transcriptEntries.contains { $0.id == accepted.captionID } == false)
            stage = "first queue write uses native correction"
            await queueGate.resume()
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText
                    == "corrected-before-upsert"
            }
            stage = "original translation second write"
            await translations.release(text: "original-before-upsert", result: "translated-original-before-upsert")
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localTranslatedText
                    == "translated-original-before-upsert"
            }
            let entry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(entry.translatedText == "translated-before-upsert")
            #expect(entry.localSourceText == "original-before-upsert")
            #expect(entry.localTranslatedText == "translated-original-before-upsert")
            #expect(fixture.model.overlayState?.sourceText == "corrected-before-upsert")
            #expect(fixture.model.overlayState?.translatedText == "translated-before-upsert")
        } catch {
            let entry = acceptedCaptionID.flatMap { id in fixture.model.transcriptEntries.first(where: { $0.id == id }) }
            print("nativeCorrection pre-upsert stage: \(stage); entry=\(String(describing: entry)); overlay=\(String(describing: fixture.model.overlayState?.sourceText))/\(String(describing: fixture.model.overlayState?.translatedText)); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func clearingTranscriptWhileOriginalNativeCaptionTranslationIsHeldPreservesAcceptedOverlay() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        var originalTask: Task<Void, Never>?
        var displayTask: Task<Void, Never>?
        func cleanup() async {
            let localTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            (localTasks + correctionTasks + transferTasks).forEach { $0.cancel() }
            display?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in localTasks + correctionTasks + transferTasks { await task.value }
            await originalTask?.value
            await displayTask?.value
            await display?.value
        }

        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            await startTask.value
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "clear-window original accepted caption",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            let savedOriginalTask: Task<Void, Never> = try #require(
                fixture.model.captionTranslationTaskForTesting(captionID: accepted.captionID)
            )
            originalTask = savedOriginalTask
            try await waitUntil { await translations.hasRequest(text: "clear-window original accepted caption") }
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                    == "clear-window original accepted caption"
            }
            try await waitUntil { await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID) }
            let driver = try #require(drivers.all().first)
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "clear-window accepted corrected source"
            ))
            try await waitUntil { await translations.hasRequest(text: "clear-window accepted corrected source") }
            await translations.release(text: "clear-window accepted corrected source", result: "clear-window accepted translation")
            await fixture.model.nativeCorrectionTasksSnapshotForTesting().first?.value
            try await waitUntil {
                fixture.model.overlayState?.committedCaptionID == accepted.captionID
                    && fixture.model.overlayState?.sourceText == "clear-window accepted corrected source"
            }
            let acceptedOverlaySource = fixture.model.overlayState?.sourceText
            let acceptedOverlayTranslation = fixture.model.overlayState?.translatedText
            fixture.model.clearTranscript()
            #expect(fixture.model.transcriptEntries.isEmpty)
            #expect(fixture.model.overlayState?.sourceText == acceptedOverlaySource)
            #expect(fixture.model.overlayState?.translatedText == acceptedOverlayTranslation)

            displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            await translations.release(text: "clear-window original accepted caption", result: "late original translation")
            await originalTask?.value
            try await waitUntil(timeout: .seconds(8)) {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localTranslatedText
                    == "late original translation"
            }
            let lateEntry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(lateEntry.sourceText == "clear-window accepted corrected source")
            #expect(lateEntry.translatedText == "clear-window accepted translation")
            #expect(fixture.model.overlayState?.committedCaptionID == accepted.captionID)
            #expect(fixture.model.overlayState?.sourceText == "clear-window accepted corrected source")
            #expect(fixture.model.overlayState?.translatedText == "clear-window accepted translation")
            await displayTask?.value

            await driver.emit(.utteranceCompleted(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID
            ))
            try await waitUntil { await coordinator.inFlightCaptionIDForTesting(sourceID: accepted.sourceID) == nil }
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "clear-window pending original caption",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID).count == 1 }
            let pendingAccepted = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID).last)
            let savedPendingOriginalTask: Task<Void, Never> = try #require(
                fixture.model.captionTranslationTaskForTesting(captionID: pendingAccepted.captionID)
            )
            originalTask = savedPendingOriginalTask
            try await waitUntil { await translations.hasRequest(text: "clear-window pending original caption") }
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == pendingAccepted.captionID })?.localSourceText
                    == "clear-window pending original caption"
            }
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: pendingAccepted.captionID)
            }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: pendingAccepted.captionID,
                utteranceID: pendingAccepted.utteranceID,
                text: "clear-window pending corrected source"
            ))
            try await waitUntil { await translations.hasRequest(text: "clear-window pending corrected source") }
            let savedPendingCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: pendingAccepted.captionID)?.state == .pending)
            fixture.model.clearTranscript()
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID).isEmpty)
            #expect(savedPendingCorrectionTask.isCancelled)
            #expect(fixture.model.overlayState?.sourceText == "clear-window pending corrected source")
            #expect(fixture.model.overlayState?.translatedText.isEmpty == true)
            await translations.release(text: "clear-window pending corrected source", result: "must not resurrect")
            await savedPendingCorrectionTask.value
            displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            await translations.release(text: "clear-window pending original caption", result: "late pending original translation")
            await savedPendingOriginalTask.value
            try await waitUntil(timeout: .seconds(8)) {
                fixture.model.transcriptEntries.first(where: { $0.id == pendingAccepted.captionID })?.localTranslatedText
                    == "late pending original translation"
            }
            let pendingLateEntry = try #require(
                fixture.model.transcriptEntries.first(where: { $0.id == pendingAccepted.captionID })
            )
            #expect(pendingLateEntry.sourceText == "clear-window pending corrected source")
            #expect(pendingLateEntry.translatedText.isEmpty)
            #expect(pendingLateEntry.nativeCorrectedTranslationState == .failed)
            #expect(fixture.model.overlayState?.sourceText == "clear-window pending corrected source")
            #expect(fixture.model.overlayState?.translatedText.isEmpty == true)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func preReadyNativeEventsFlushAgainstTrustedIdentityAndShareSourceBound() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let readyGate = AsyncTestGate()
        fixture.model.pauseNextNativeSourceReadyHandlingForTesting { await readyGate.suspend() }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            startTask.cancel()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            let readyTask = fixture.model.nativeSourceReadyTaskSnapshotForTesting(sourceID: fixture.microphone.id)
            (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            readyTask?.cancel()
            await readyGate.resume()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            await readyTask?.value
            for task in correctionTasks + translationTasks + transferTasks { await task.value }
            await displayTask?.value
        }

        var stage = "app ready callback held"
        var captionIDs: [UUID] = []
        do {
            try await readyGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            #expect(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) == nil)
            await startTask.value
            try await waitUntil { fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === session }
            let driver = try #require(drivers.all().first)
            try await waitUntil { await driver.isListeningForEvents() }
            let alias = try #require(await driver.startedAliases().first)
            let generation = try #require(await driver.startedGenerations().first)

            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "pre-ready original A",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let first = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            captionIDs.append(first.captionID)
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "a completely separate second utterance about tomorrow",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { fixture.model.nativeAcceptedBindingsForTesting(sourceID: first.sourceID).count == 2 }
            let second = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: first.sourceID).last)
            captionIDs.append(second.captionID)
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(sourceID: first.sourceID, captionID: first.captionID)
            }
            #expect(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: first.captionID) == nil)

            stage = "real provider corrected event arrives before App trusted-ready callback"
            await driver.emit(.correctedText(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                text: "pre-ready corrected A"
            ))
            try await waitUntil { fixture.model.nativeEarlyEventCountForTesting(sourceID: first.sourceID) == 1 }
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: "different-source-id",
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong source identity")
            ))
            #expect(fixture.model.nativeEarlyEventCountForTesting(sourceID: first.sourceID) == 1)
            let wrongAliasEvent = RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: "untrusted-wrong-alias",
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("must be ignored")
            )
            fixture.model.deliverNativeCaptionEventForTesting(wrongAliasEvent)
            let wrongGenerationTerminal = RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation &+ 1,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .utteranceCompleted
            )
            fixture.model.deliverNativeCaptionEventForTesting(wrongGenerationTerminal)
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: UUID(),
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong token")
            ))
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration &+ 1,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong capture generation")
            ))
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: "wrong-utterance-id",
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong utterance")
            ))
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: "fr",
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong source language")
            ))
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: "ja",
                kind: .correctedText("wrong target language")
            ))
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: first.sourceID,
                sourceToken: first.sourceToken,
                captureGeneration: first.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: second.captionID,
                utteranceID: first.utteranceID,
                sourceLanguageID: first.sourceLanguageID,
                targetLanguageID: first.targetLanguageID,
                kind: .correctedText("wrong caption identity")
            ))
            for index in 0..<5 {
                fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                    sourceID: first.sourceID,
                    sourceToken: first.sourceToken,
                    captureGeneration: first.captureGeneration,
                    sourceAlias: alias,
                    driverGeneration: generation,
                    captionID: first.captionID,
                    utteranceID: first.utteranceID,
                    sourceLanguageID: first.sourceLanguageID,
                    targetLanguageID: first.targetLanguageID,
                    kind: .suggestion("suggestion-\(index)")
                ))
            }
            try await waitUntil { fixture.model.nativeEarlyEventCountForTesting(sourceID: first.sourceID) == 8 }
            #expect(fixture.model.transcriptEntries.first(where: { $0.id == first.captionID })?.sourceText
                == "pre-ready original A")

            stage = "valid terminal frees coordinator FIFO but cannot exceed early-event cap"
            await driver.emit(.utteranceCompleted(
                sourceAlias: alias,
                generation: generation,
                captionID: first.captionID,
                utteranceID: first.utteranceID
            ))
            try await waitUntil {
                await coordinator.inFlightCaptionIDForTesting(sourceID: first.sourceID) != first.captionID
            }
            #expect(fixture.model.nativeEarlyEventCountForTesting(sourceID: first.sourceID) == 8)

            stage = "source-wide cap rejects a ninth event for the sibling caption"
            fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                sourceID: second.sourceID,
                sourceToken: second.sourceToken,
                captureGeneration: second.captureGeneration,
                sourceAlias: alias,
                driverGeneration: generation,
                captionID: second.captionID,
                utteranceID: second.utteranceID,
                sourceLanguageID: second.sourceLanguageID,
                targetLanguageID: second.targetLanguageID,
                kind: .correctedText("ninth event must be dropped")
            ))
            #expect(fixture.model.nativeEarlyEventCountForTesting(sourceID: first.sourceID) == 8)
            let secondBeforeReady = fixture.model.nativeCorrectionSnapshotForTesting(captionID: second.captionID)
            #expect(secondBeforeReady?.state == NativeCorrectedTranslationState.none)
            #expect(secondBeforeReady?.sourceText == nil)

            stage = "trusted-ready callback flushes and revalidates each stored identity"
            let readyTask = try #require(
                fixture.model.nativeSourceReadyTaskSnapshotForTesting(sourceID: first.sourceID)
            )
            await readyGate.resume()
            await readyTask.value
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: first.sourceID) != nil }
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == first.captionID })?.sourceText
                    == "pre-ready corrected A"
            }
            #expect(fixture.model.nativeTerminalEventReceivedForTesting(captionID: first.captionID) == false)
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: second.sourceID)
                .contains(where: { $0.captionID == second.captionID }))
            let secondAfterReady = fixture.model.nativeCorrectionSnapshotForTesting(captionID: second.captionID)
            #expect(secondAfterReady?.state == NativeCorrectedTranslationState.none)
            #expect(secondAfterReady?.sourceText == nil)
        } catch {
            print("pre-ready native event stage: \(stage); ids=\(captionIDs); early=\(fixture.model.nativeEarlyEventCountForTesting(sourceID: fixture.microphone.id)); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test(arguments: [false, true])
    func refreshTranslationPreservesNativeEffectiveCaptionAfterSourceRevocation(
        clearTranscriptAfterRevocation: Bool
    ) async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        var heldRefreshTask: Task<Void, Never>?
        var heldCorrectionTask: Task<Void, Never>?
        func cleanup() async {
            startTask.cancel()
            heldRefreshTask?.cancel()
            heldCorrectionTask?.cancel()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let refreshTask = fixture.model.captionRefreshTaskSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            (translationTasks + correctionTasks + transferTasks).forEach { $0.cancel() }
            refreshTask?.cancel()
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in translationTasks + correctionTasks + transferTasks { await task.value }
            await heldRefreshTask?.value
            await heldCorrectionTask?.value
            await refreshTask?.value
            await displayTask?.value
        }

        var stage = "trusted-ready and accepted caption"
        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "refresh original live utterance",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID)
            }
            let driver = try #require(drivers.all().first)
            let ready = try #require(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: accepted.captionID))

            stage = "complete initial local translation and display"
            try await waitUntil { await translations.hasRequest(text: "refresh original live utterance") }
            await translations.release(text: "refresh original live utterance", result: "old target translation")
            try await waitUntil { fixture.model.overlayState?.committedCaptionID == accepted.captionID }

            stage = "accept native correction and its local translation"
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "refresh corrected live utterance"
            ))
            try await waitUntil { await translations.hasRequest(text: "refresh corrected live utterance") }
            let savedCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            heldCorrectionTask = savedCorrectionTask
            await translations.release(text: "refresh corrected live utterance", result: "corrected target translation")
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.translatedText
                    == "corrected target translation"
            }
            #expect(fixture.model.overlayState?.translatedText == "corrected target translation")

            stage = "hold refresh translation before source revocation"
            let previousCount = await translations.requestCount(text: "refresh original live utterance")
            fixture.model.refreshCaptionTranslationsForTesting()
            try await waitUntil {
                await translations.requestCount(text: "refresh original live utterance") > previousCount
            }
            let savedRefreshTask: Task<Void, Never> = try #require(
                fixture.model.captionRefreshTaskSnapshotForTesting()
            )
            heldRefreshTask = savedRefreshTask
            var settings = fixture.model.nativeRealtimeSettings
            settings.enabledSourceIDs = []
            fixture.model.nativeRealtimeSettings = settings
            try await waitUntil {
                fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: accepted.captionID) == nil
            }
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil)
            if clearTranscriptAfterRevocation {
                fixture.model.clearTranscript()
                #expect(fixture.model.transcriptEntries.isEmpty)
                #expect(fixture.model.overlayState?.committedCaptionID == accepted.captionID)
                #expect(fixture.model.overlayState?.sourceText == "refresh corrected live utterance")
                #expect(fixture.model.overlayState?.translatedText == "corrected target translation")
            }
            await translations.release(text: "refresh original live utterance", result: "pending-list refresh target")
            await translations.release(text: "refresh original live utterance", result: "stale refresh target")
            await heldRefreshTask?.value
            let entry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(entry.sourceText == "refresh corrected live utterance")
            #expect(entry.translatedText == "corrected target translation")
            if clearTranscriptAfterRevocation {
                #expect(entry.nativeCorrectedTranslationState == .ready)
                #expect(entry.localSourceText == "refresh original live utterance")
                #expect(entry.localTranslatedText == "stale refresh target")
            }
            #expect(fixture.model.overlayState?.committedCaptionID == accepted.captionID)
            #expect(fixture.model.overlayState?.sourceText == "refresh corrected live utterance")
            #expect(fixture.model.overlayState?.translatedText == "corrected target translation")
        } catch {
            print("refresh native caption stage: \(stage); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func revokedNativeCorrectionKeepsExactHistoryWhenOriginalTranslationArrivesLate() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        var revokedCorrectionTask: Task<Void, Never>?
        var heldOriginalTranslationTask: Task<Void, Never>?
        func cleanup() async {
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            revokedCorrectionTask?.cancel()
            heldOriginalTranslationTask?.cancel()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in correctionTasks + translationTasks + transferTasks { await task.value }
            await revokedCorrectionTask?.value
            await heldOriginalTranslationTask?.value
            await displayTask?.value
        }

        var stage = "trusted ready and first original translation held"
        var firstCaptionID: UUID?
        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            await startTask.value
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "revoked-original-A",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await translations.hasRequest(text: "revoked-original-A") }
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            firstCaptionID = accepted.captionID
            let savedOriginalTranslationTask: Task<Void, Never> = try #require(
                fixture.model.captionTranslationTaskForTesting(captionID: accepted.captionID)
            )
            heldOriginalTranslationTask = savedOriginalTranslationTask
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                    == "revoked-original-A"
            }
            let driver = try #require(drivers.all().first)
            try await waitUntil {
                let count = await driver.committedUtteranceCount()
                let listening = await driver.isListeningForEvents()
                return count == 1 && listening
            }
            stage = "native corrected source accepted with its translation pending"
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "revoked-corrected-A"
            ))
            try await waitUntil { await translations.hasRequest(text: "revoked-corrected-A") }
            let savedRevokedCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            revokedCorrectionTask = savedRevokedCorrectionTask
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .pending)

            stage = "source revocation preserves accepted correction identity facts"
            var settings = fixture.model.nativeRealtimeSettings
            settings.enabledSourceIDs = []
            fixture.model.nativeRealtimeSettings = settings
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil
            }
            #expect(revokedCorrectionTask?.isCancelled == true)
            #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText
                == "revoked-corrected-A")

            stage = "next caption advances queue and archives exact first caption"
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "revoked-next-caption-B",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil(timeout: .seconds(5)) {
                guard let id = fixture.model.overlayState?.committedCaptionID,
                      let firstCaptionID else { return false }
                return id != firstCaptionID
            }
            try await waitUntil {
                fixture.model.overlayState?.history.contains(where: { $0.id == accepted.captionID }) == true
            }
            let currentBeforeLateResult = try #require(fixture.model.overlayState)
            let currentCaptionBeforeLateResult = try #require(
                fixture.model.transcriptEntries.first(where: { $0.id == currentBeforeLateResult.committedCaptionID })
            )
            let historyBeforeClear = try #require(
                currentBeforeLateResult.history.first(where: { $0.id == accepted.captionID })
            )
            #expect(historyBeforeClear.sourceText == "revoked-corrected-A")
            #expect(historyBeforeClear.translatedText.isEmpty)

            stage = "clear keeps the current overlay and exact corrected history source"
            fixture.model.clearTranscript()
            #expect(fixture.model.transcriptEntries.isEmpty)
            let overlayAfterClear = try #require(fixture.model.overlayState)
            #expect(overlayAfterClear.committedCaptionID == currentBeforeLateResult.committedCaptionID)
            #expect(overlayAfterClear.captionEpoch == currentBeforeLateResult.captionEpoch)
            #expect(overlayAfterClear.sourceText == currentBeforeLateResult.sourceText)
            #expect(overlayAfterClear.translatedText == currentBeforeLateResult.translatedText)
            let historyAfterClear = try #require(
                overlayAfterClear.history.first(where: { $0.id == accepted.captionID })
            )
            #expect(historyAfterClear.sourceText == "revoked-corrected-A")
            #expect(historyAfterClear.translatedText.isEmpty)

            stage = "original translation arrives after clear without corrupting retained native history"
            await translations.release(text: "revoked-original-A", result: "local-original-translation-A")
            await heldOriginalTranslationTask?.value
            let history = try #require(fixture.model.overlayState?.history.first(where: { $0.id == accepted.captionID }))
            #expect(history.sourceText == "revoked-corrected-A")
            #expect(history.translatedText.isEmpty)
            let currentAfterLateResult = try #require(fixture.model.overlayState)
            #expect(fixture.model.transcriptEntries.isEmpty)
            #expect(currentAfterLateResult.committedCaptionID == currentBeforeLateResult.committedCaptionID)
            #expect(currentAfterLateResult.captionEpoch == currentBeforeLateResult.captionEpoch)
            #expect(currentAfterLateResult.sourceText == currentBeforeLateResult.sourceText)
            #expect(currentAfterLateResult.translatedText == currentBeforeLateResult.translatedText)
            #expect(currentCaptionBeforeLateResult.id == currentBeforeLateResult.committedCaptionID)
        } catch {
            let entry = firstCaptionID.flatMap { id in fixture.model.transcriptEntries.first(where: { $0.id == id }) }
            print("revoked native late translation stage: \(stage); entry=\(String(describing: entry)); history=\(String(describing: fixture.model.overlayState?.history)); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func latestNativeCorrectionRevisionWinsWhenTranslationsReturnInReverseOrder() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        var staleTranslationTask: Task<Void, Never>?
        func cleanup() async {
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translationTasks + correctionTasks + transferTasks).forEach { $0.cancel() }
            staleTranslationTask?.cancel()
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in translationTasks + correctionTasks + transferTasks { await task.value }
            await staleTranslationTask?.value
            await displayTask?.value
        }

        var stage = "original translation held after first upsert"
        var acceptedCaptionID: UUID?
        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "original-revision-test",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            acceptedCaptionID = accepted.captionID
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sourceToken == ready.sourceToken)
            #expect(accepted.captureGeneration == ready.captureGeneration)
            try await waitUntil { await translations.hasRequest(text: "original-revision-test") }
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                    == "original-revision-test"
            }
            let driver = try #require(drivers.all().first)
            try await waitUntil {
                let committedCount = await driver.committedUtteranceCount()
                let listening = await driver.isListeningForEvents()
                return committedCount == 1 && listening
            }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "correction-revision-A"
            ))
            try await waitUntil { await translations.hasRequest(text: "correction-revision-A") }
            staleTranslationTask = fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "correction-revision-B"
            ))
            stage = "revision B translation ready before A"
            try await waitUntil { await translations.hasRequest(text: "correction-revision-B") }
            await translations.release(text: "correction-revision-B", result: "translation-revision-B")
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.translatedText
                    == "translation-revision-B"
            }
            await translations.release(text: "correction-revision-A", result: "translation-revision-A")
            await staleTranslationTask?.value
            stage = "revision A released last"
            let snapshot = try #require(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID))
            #expect(snapshot.sourceText == "correction-revision-B")
            #expect(snapshot.translatedText == "translation-revision-B")
            #expect(snapshot.state == .ready)
            let entry = try #require(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID }))
            #expect(entry.sourceText == "correction-revision-B")
            #expect(entry.translatedText == "translation-revision-B")
            #expect(entry.localSourceText == "original-revision-test")
        } catch {
            let entry = acceptedCaptionID.flatMap { id in fixture.model.transcriptEntries.first(where: { $0.id == id }) }
            print("native correction revision stage: \(stage); entry=\(String(describing: entry)); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func restartCancelsHeldNativeCorrectionBeforeOldDriverStopCompletes() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        var sessions: [LiveTranscriptionSession] = []
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            let session = LiveTranscriptionSession()
            session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
            sessions.append(session)
            return session
        }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translations.translate(text, source: source, target: target)
        }
        let startTask = Task { await fixture.model.startSession() }
        var restartTask: Task<Void, Never>?
        var heldDriver: IntegrationNativeRealtimeDriver?
        var correctionTask: Task<Void, Never>?
        func cleanup() async {
            startTask.cancel()
            restartTask?.cancel()
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let localTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            (correctionTasks + localTasks + transferTasks).forEach { $0.cancel() }
            correctionTask?.cancel()
            displayTask?.cancel()
            await heldDriver?.resumeStop()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            await restartTask?.value
            for task in correctionTasks + localTasks + transferTasks { await task.value }
            await correctionTask?.value
            await displayTask?.value
        }

        var stage = "first trusted ready source"
        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            await startTask.value
            let session = try #require(sessions.first)
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "restart-original-held",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            let driver = try #require(drivers.all().first)
            try await waitUntil {
                let count = await driver.committedUtteranceCount()
                let listening = await driver.isListeningForEvents()
                return count == 1 && listening
            }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "restart-correction-held"
            ))
            try await waitUntil { await translations.hasRequest(text: "restart-correction-held") }
            let savedCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            correctionTask = savedCorrectionTask
            #expect(!correctionTask!.isCancelled)
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID)?.state == .pending)

            stage = "restart blocks while stopping the old driver"
            await driver.suspendNextStop()
            heldDriver = driver
            restartTask = Task { await fixture.model.startSession() }
            try await waitUntil { await driver.isStopSuspended() }
            #expect(correctionTask!.isCancelled)
            #expect(fixture.model.nativeCorrectionTasksSnapshotForTesting().isEmpty)
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil)
            await translations.release(text: "restart-correction-held", result: "must-not-resurrect-after-restart")
            await correctionTask?.value
            await heldDriver?.resumeStop()
            await restartTask?.value
            #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil)
        } catch {
            print("native stop cancellation stage: \(stage); error: \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func acceptedFinalBeforeNativeInputCreationStaysLocalAndIsNotReplayed() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        let localStartGate = AsyncTestGate()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
            await localStartGate.suspend()
        }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            await localStartGate.resume()
            await startTask.value
            let translations = fixture.model.captionTranslationTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translations + transfers).forEach { $0.cancel() }
            display?.cancel()
            fixture.model.stopSession()
            for task in translations { await task.value }
            for task in transfers { await task.value }
            await display?.value
            await coordinator.stop()
            await startTask.value
        }

        do {
            try await localStartGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            await session.resetCorrectionAudioCapture(enabled: false)
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "pre-input final",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            #expect(fixture.model.acceptedFinalDeliveryCountForTesting == 1)

            await localStartGate.resume()
            await startTask.value
            try await waitUntil {
                fixture.model.transcriptEntries.contains { $0.sourceText == "pre-input final" }
            }
            #expect(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) == nil)
            #expect(fixture.model.transcriptEntries.contains { $0.sourceText == "pre-input final" })
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func delayedLegacyFinalBeforeConsumerFloorRemainsLocalAfterInputInstall() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let session = LiveTranscriptionSession()
        let localStartGate = AsyncTestGate()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
            await localStartGate.suspend()
        }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            await localStartGate.resume()
            await startTask.value
            let translations = fixture.model.captionTranslationTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translations + transfers).forEach { $0.cancel() }
            display?.cancel()
            fixture.model.stopSession()
            await display?.value
            for task in translations + transfers { await task.value }
            await coordinator.stop()
            await startTask.value
        }

        do {
            try await localStartGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            await session.resetCorrectionAudioCapture(enabled: false)
            await session.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "delayed no-consumer final",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))

            await localStartGate.resume()
            try await waitUntil { fixture.model.nativeAcceptedBindingStateForTesting.2 == 1 }
            #expect(fixture.model.nativeCaptureIdentitiesForTesting[fixture.microphone.id] != nil)
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                fixture.model.transcriptEntries.contains { $0.sourceText == "delayed no-consumer final" }
            }
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).isEmpty)
            #expect(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) == nil)

            #expect(await session.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "post-install final",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 1 }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sampleInterval == 2..<4)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test @available(macOS 26.0, *) func registeredCaptionTransfersStayBelowPerSourcePendingLimitWhileLocalCaptionsContinue() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        let transferGate = AsyncTestGate()
        fixture.model.pauseNativeCaptionTransfersForTesting { await transferGate.suspend() }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            for task in transferTasks + translationTasks { task.cancel() }
            displayTask?.cancel()
            await transferGate.resume()
            fixture.model.stopSession()
            for task in transferTasks + translationTasks { await task.value }
            await displayTask?.value
            await coordinator.stop()
            await startTask.value
        }

        do {
            await startTask.value
            let analyzerInputs = await session.installModernAnalyzerInputStreamForTesting()
            var iterator = analyzerInputs.makeAsyncIterator()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            let sentences = [
                "Apple trees bloom beside the quiet river.",
                "Weather forecasts say rain arrives tomorrow.",
                "Trains leave the station before sunrise each day.",
                "Small birds gather along the garden fence.",
                "Coffee cools slowly on the wooden table.",
                "Cloud shadows cross the mountain in spring.",
                "Children read stories beside the library window.",
                "Blue bicycles lean against the brick wall.",
                "Morning buses turn carefully around the market."
            ]
            for index in 0..<9 {
                let lower = Int64(index * 2)
                await session.appendCapturedAudioBufferForTesting(inputPCM)
                let analyzerInput = try #require(await iterator.next())
                let bufferStart = try #require(analyzerInput.bufferStartTime)
                let duration = CMTime(value: 2, timescale: 16_000)
                let provenance = try #require(await session.modernAudioProvenanceForTesting(
                    CMTimeRange(start: bufferStart, duration: duration)
                ))
                #expect(provenance.sampleInterval == lower..<(lower + 2))
                let text = sentences[index]
                session.deliverRecognizedSentenceForTesting(RecognizedSentence(
                    text: text,
                    audioProvenance: provenance
                ))
                #expect(fixture.model.acceptedFinalDeliveryCountForTesting == index + 1)
                try await waitUntil(timeout: .seconds(5)) {
                    fixture.model.transcriptEntries.contains { $0.sourceText == text }
                }
                #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == min(index + 1, 8))
            }
            try await transferGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            #expect(fixture.model.acceptedFinalDeliveryCountForTesting == 9)
            #expect(fixture.model.localCaptionWasEnqueuedForTesting(sentences[8]))
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.1 == 8)
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 8)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func clearTranscriptRevokesAnUnadmittedAcceptedTransferWithoutStoppingCapture() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        let transferGate = AsyncTestGate()
        fixture.model.pauseNativeCaptionTransfersForTesting { await transferGate.suspend() }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup(_ capturedTasks: [Task<Void, Never>] = []) async {
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting() + capturedTasks
            let translations = fixture.model.captionTranslationTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            (transfers + translations).forEach { $0.cancel() }
            display?.cancel()
            await transferGate.resume()
            fixture.model.stopSession()
            for task in transfers + translations { await task.value }
            await display?.value
            await coordinator.stop()
            await startTask.value
        }

        var capturedTasks: [Task<Void, Never>] = []
        do {
            await startTask.value
            await session.resetCorrectionAudioCapture(enabled: false)
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "a caption cleared before transfer admission",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await transferGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
            let firstBinding = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
            capturedTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            #expect(capturedTasks.count == 1)

            fixture.model.clearTranscript()
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).isEmpty)
            let allTransfersCancelled = capturedTasks.allSatisfy { task in task.isCancelled }
            #expect(allTransfersCancelled)
            await transferGate.resume()
            for task in capturedTasks { await task.value }
            #expect(await coordinator.acceptedCaptionMetadataForTesting(sourceID: fixture.microphone.id) == nil)
            #expect(fixture.model.sessionState == .running)

            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 2..<4)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "a later caption continues on the same capture",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 1
            }
            let later = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
            #expect(later.captionID != firstBinding.captionID)
            try await waitUntil {
                fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: later.captionID) == .queued
            }
            #expect(await coordinator.acceptedCaptionMetadataForTesting(sourceID: fixture.microphone.id) != nil)
        } catch {
            await cleanup(capturedTasks)
            throw error
        }
        await cleanup(capturedTasks)
    }

    @Test @available(macOS 26.0, *) func acceptedNativeRecordLimitProtectsCoordinatorQueuedCaptionsAndDegradesLocally() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let driver = IntegrationNativeRealtimeDriver()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in driver }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        let translationGate = AsyncTestGate()
        fixture.model.pauseCaptionTranslationForTesting { await translationGate.suspend() }
        let nativeTranslations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            if text == "capacity active correction first record" {
                return try await nativeTranslations.translate(text, source: source, target: target)
            }
            return "native translated: \(text)"
        }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translationTasks + transferTasks).forEach { $0.cancel() }
            display?.cancel()
            fixture.model.stopSession()
            await translationGate.resume()
            for task in translationTasks { await task.value }
            for task in transferTasks { await task.value }
            await display?.value
            await coordinator.stop()
            await startTask.value
        }

        func captionText(_ index: Int) -> String {
            var state = UInt64(index) &+ 0x9E37_79B9_7F4A_7C15
            var letters: [Character] = []
            for _ in 0..<64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var mixed = state
                mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
                mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
                mixed ^= mixed >> 31
                letters.append(Character(UnicodeScalar(97 + Int(mixed % 26))!))
            }
            return stride(from: 0, to: letters.count, by: 8).map {
                String(letters[$0..<($0 + 8)])
            }.joined(separator: " ")
        }

        var activeCaptionIndex = -1
        var activeCaptionID: UUID?
        var activePhase = "starting"
        do {
            await startTask.value
            let analyzerInputs = await session.installModernAnalyzerInputStreamForTesting()
            var iterator = analyzerInputs.makeAsyncIterator()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            try await waitUntil(timeout: .seconds(5)) { await driver.isListeningForEvents() }
            var firstBinding: RealtimeAcceptedCaptionMetadata?
            var firstEightBindings: [RealtimeAcceptedCaptionMetadata] = []
            var firstTerminalWithoutCorrection: RealtimeAcceptedCaptionMetadata?
            var activeCorrectionTask: Task<Void, Never>?
            var firstProvenance: RecognizedAudioProvenance?
            var firstEvictableBinding: RealtimeAcceptedCaptionMetadata?
            for index in 0...128 {
                activeCaptionIndex = index
                activePhase = "audio and final callback"
                let text = captionText(index)
                let lower = Int64(index * 2)
                let provenance: RecognizedAudioProvenance
                if index < 8 {
                    await session.appendCapturedAudioBufferForTesting(pcm)
                    let analyzerInput = try #require(await iterator.next())
                    let bufferStart = try #require(analyzerInput.bufferStartTime)
                    let duration = CMTime(value: 2, timescale: 16_000)
                    provenance = try #require(await session.modernAudioProvenanceForTesting(
                        CMTimeRange(start: bufferStart, duration: duration)
                    ))
                    #expect(provenance.sampleInterval == lower..<(lower + 2))
                    if index == 0 { firstProvenance = provenance }
                } else {
                    provenance = try #require(firstProvenance)
                }
                session.deliverRecognizedSentenceForTesting(RecognizedSentence(text: text, audioProvenance: provenance))
                #expect(fixture.model.acceptedFinalDeliveryCountForTesting == index + 1)
                try await waitUntil(timeout: .seconds(5)) {
                    fixture.model.localCaptionWasEnqueuedForTesting(text)
                }
                activePhase = "binding admission"
                var bindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id)
                if index < 128 {
                    try await waitUntil(timeout: .seconds(5)) {
                        fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == index + 1
                    }
                    let binding = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
                    activeCaptionID = binding.captionID
                    if index < 8 {
                        activePhase = "coordinator transfer disposition"
                        try await waitUntil(timeout: .seconds(5)) {
                            fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: binding.captionID) == .queued
                        }
                        let ready = try #require(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: binding.captionID))
                        activePhase = "driver commit"
                        try await waitUntil(timeout: .seconds(5)) { await driver.committedUtteranceCount() == index + 1 }
                        activePhase = "coordinator commit acceptance"
                        try await waitUntil(timeout: .seconds(5)) {
                            await coordinator.captionCommitSucceededForTesting(
                                sourceID: fixture.microphone.id,
                                captionID: binding.captionID
                            )
                        }
                        if index == 0 {
                            await driver.emit(.correctedText(
                                sourceAlias: ready.alias,
                                generation: ready.driverGeneration,
                                captionID: binding.captionID,
                                utteranceID: binding.utteranceID,
                                text: "capacity active correction first record"
                            ))
                            try await waitUntil(timeout: .seconds(5)) {
                                await nativeTranslations.hasRequest(text: "capacity active correction first record")
                            }
                            activeCorrectionTask = fixture.model.nativeCorrectionTasksSnapshotForTesting().first
                            #expect(activeCorrectionTask?.isCancelled == false)
                        }
                        await driver.emit(.utteranceCompleted(
                            sourceAlias: ready.alias,
                            generation: ready.driverGeneration,
                            captionID: binding.captionID,
                            utteranceID: binding.utteranceID
                        ))
                        activePhase = "trusted provider completion delivery"
                        try await waitUntil(timeout: .seconds(5)) {
                            fixture.model.nativeTerminalEventReceivedForTesting(captionID: binding.captionID)
                        }
                        try await waitUntil(timeout: .seconds(5)) {
                            await coordinator.inFlightCaptionIDForTesting(sourceID: fixture.microphone.id) == nil
                        }
                        firstEightBindings.append(binding)
                        if index == 0 { firstBinding = binding }
                        if index == 1 { firstTerminalWithoutCorrection = binding }
                    } else {
                        activePhase = "local-only coordinator disposition"
                        try await waitUntil(timeout: .seconds(5)) {
                            fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: binding.captionID) != nil
                        }
                        let disposition = fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: binding.captionID)
                        guard case .localOnly? = disposition else {
                            Issue.record("expected stale-interval caption to stay local, got \(String(describing: disposition))")
                            break
                        }
                        if index == 8 { firstEvictableBinding = binding }
                    }
                    fixture.model.finalizePendingLocalCaptionForTesting(captionID: binding.captionID, translation: "")
                } else {
                    let latestCaptionID = try #require(fixture.model.localCaptionIDForTesting(sourceText: text))
                    try await waitUntil(timeout: .seconds(5)) {
                        let latest = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id)
                        return latest.count == 128 && latest.last?.captionID == latestCaptionID
                    }
                    bindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id)
                    #expect(bindings.count == 128)
                    #expect(firstBinding.map { bindings.contains($0) } == true)
                    #expect(firstEightBindings.dropFirst(2).allSatisfy { bindings.contains($0) })
                    #expect(firstTerminalWithoutCorrection.map { !bindings.contains($0) } == true)
                    #expect(firstEvictableBinding.map { bindings.contains($0) } == true)
                    #expect(activeCorrectionTask?.isCancelled == false)
                    #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: firstBinding!.captionID)?.state == .pending)
                    #expect(fixture.model.localCaptionWasEnqueuedForTesting(text))
                }
            }
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 128)
        } catch {
            let transferDisposition = activeCaptionID.flatMap {
                fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: $0)
            }
            let admittedRanges = await coordinator.admittedAudioRangeCountForTesting(sourceID: fixture.microphone.id)
            let committedCount = await driver.committedUtteranceCount()
            let inFlight = await coordinator.inFlightCaptionIDForTesting(sourceID: fixture.microphone.id)
            let appBindingState = fixture.model.nativeAcceptedBindingStateForTesting
            let sourceBindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count
            let captureIdentity = fixture.model.nativeCaptureIdentitiesForTesting[fixture.microphone.id]
            Issue.record("accepted native record limit stopped at caption index \(activeCaptionIndex) during \(activePhase), disposition \(String(describing: transferDisposition)), admitted ranges \(admittedRanges), commits \(committedCount), in flight \(String(describing: inFlight)), app state \(appBindingState), source bindings \(sourceBindings), capture identity present \(captureIdentity != nil): \(error)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test @available(macOS 26.0, *) func pendingCaptionDropAtIndexOneRevokesUnadmittedNativeAndTranslationTasks() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        let translationGate = AsyncTestGate()
        let transferGate = AsyncTestGate()
        fixture.model.pauseCaptionTranslationForTesting { await translationGate.suspend() }
        fixture.model.pauseNativeCaptionTransfersForTesting { await transferGate.suspend() }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup(
            translationTasks: [Task<Void, Never>] = [],
            transferTasks: [Task<Void, Never>] = []
        ) async {
            let allTranslationTasks = fixture.model.captionTranslationTasksSnapshotForTesting() + translationTasks
            let allTransferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting() + transferTasks
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            for task in allTranslationTasks + allTransferTasks { task.cancel() }
            displayTask?.cancel()
            fixture.model.stopSession()
            await translationGate.resume()
            await transferGate.resume()
            for task in allTranslationTasks + allTransferTasks { await task.value }
            await displayTask?.value
            await coordinator.stop()
            await startTask.value
        }

        var translationTasks: [Task<Void, Never>] = []
        var transferTasks: [Task<Void, Never>] = []
        do {
            await startTask.value
            let stream = await session.installModernAnalyzerInputStreamForTesting()
            var iterator = stream.makeAsyncIterator()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            let texts = [
                "The orchard rests beside the river at sunrise.",
                "A bright lantern guides travelers through the valley.",
                "Fresh bread cools beside the open kitchen window.",
                "Blue boats return quietly to the harbor at dusk."
            ]
            var droppedCaptionID: UUID?
            var droppedTranslationTask: Task<Void, Never>?
            var droppedTransferTask: Task<Void, Never>?
            for index in texts.indices {
                await session.appendCapturedAudioBufferForTesting(pcm)
                let input = try #require(await iterator.next())
                let start = try #require(input.bufferStartTime)
                let provenance = try #require(await session.modernAudioProvenanceForTesting(
                    CMTimeRange(start: start, duration: CMTime(value: 2, timescale: 16_000))
                ))
                session.deliverRecognizedSentenceForTesting(RecognizedSentence(
                    text: texts[index],
                    audioProvenance: provenance
                ))
                #expect(fixture.model.acceptedFinalDeliveryCountForTesting == index + 1)
                try await waitUntil(timeout: .seconds(5)) {
                    fixture.model.localCaptionWasEnqueuedForTesting(texts[index])
                }
                let bindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id)
                if index < 3 {
                    try await waitUntil(timeout: .seconds(5)) { bindings.count == index + 1 }
                    if index == 0 {
                        try await translationGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
                        try await transferGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
                    }
                    if index == 1 {
                        let dropped = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
                        droppedCaptionID = dropped.captionID
                        droppedTranslationTask = fixture.model.captionTranslationTaskForTesting(captionID: dropped.captionID)
                        droppedTransferTask = fixture.model.nativeCaptionTransferTaskForTesting(captionID: dropped.captionID)
                        #expect(droppedTranslationTask != nil)
                        #expect(droppedTransferTask != nil)
                    }
                }
            }
            let droppedID = try #require(droppedCaptionID)
            translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let bindings = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id)
            #expect(bindings.count == 3)
            #expect(bindings.contains(where: { $0.captionID == droppedID }) == false)
            #expect(droppedTranslationTask?.isCancelled == true)
            #expect(droppedTransferTask?.isCancelled == true)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.1 == 3)
            #expect(fixture.model.pendingCaptionCountForTesting == 3)
            #expect(fixture.model.localCaptionWasEnqueuedForTesting(texts[3]))
        } catch {
            await cleanup(translationTasks: translationTasks, transferTasks: transferTasks)
            throw error
        }
        await cleanup(translationTasks: translationTasks, transferTasks: transferTasks)
    }

    @Test @available(macOS 26.0, *) func unregisteredNativeCaptionStagingIsCappedPerSourceAndKeepsLocalCaptions() async throws {
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: IntegrationNativeCredentialBackend(secret: "fake-secret")),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let registrationGate = fixture.model.pauseNextNativeCoordinatorRegistrationForTesting()
        let translationGate = AsyncTestGate()
        fixture.model.pauseCaptionTranslationForTesting { await translationGate.suspend() }
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            await registrationGate.release()
            await startTask.value
            let translations = fixture.model.captionTranslationTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            (translations + transfers).forEach { $0.cancel() }
            display?.cancel()
            fixture.model.stopSession()
            await translationGate.resume()
            translations.forEach { $0.cancel() }
            for task in translations + transfers { await task.value }
            await display?.value
            await coordinator.stop()
        }
        var activeCaptionIndex = -1
        do {
            try await registrationGate.waitUntilReached(timeoutNanoseconds: 8_000_000_000)
            let stream = await session.installModernAnalyzerInputStreamForTesting()
            var iterator = stream.makeAsyncIterator()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            let texts = [
                "A red kite circles above the quiet meadow.",
                "Fresh oranges fill a basket beside the doorway.",
                "The silver train crosses the bridge before dawn.",
                "Warm rain taps softly against the garden roof.",
                "A small candle glows inside the stone cottage.",
                "Green turtles rest along the sandy shoreline.",
                "The baker stacks warm rolls beside the window.",
                "Two bright planets appear above the mountain.",
                "A wooden sailboat drifts beyond the harbor wall."
            ]
            for index in texts.indices {
                activeCaptionIndex = index
                await session.appendCapturedAudioBufferForTesting(pcm)
                let input = try #require(await iterator.next())
                let start = try #require(input.bufferStartTime)
                let provenance = try #require(await session.modernAudioProvenanceForTesting(
                    CMTimeRange(start: start, duration: CMTime(value: 2, timescale: 16_000))
                ))
                session.deliverRecognizedSentenceForTesting(RecognizedSentence(text: texts[index], audioProvenance: provenance))
                #expect(fixture.model.acceptedFinalDeliveryCountForTesting == index + 1)
                let expectedStagedCount = min(index + 1, 8)
                try await waitUntil(timeout: .seconds(5)) {
                    fixture.model.nativeAcceptedBindingStateForTesting.0 >= expectedStagedCount
                }
                #expect(fixture.model.nativeAcceptedBindingStateForTesting.0 == expectedStagedCount)
                #expect(fixture.model.nativeAcceptedBindingStateForTesting.1 == expectedStagedCount)
                try await waitUntil(timeout: .seconds(5)) { fixture.model.localCaptionWasEnqueuedForTesting(texts[index]) }
                if index == 0 {
                    try await translationGate.waitUntilSuspended(timeoutNanoseconds: 8_000_000_000)
                }
                if let metadata = fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last {
                    fixture.model.finalizePendingLocalCaptionForTesting(captionID: metadata.captionID, translation: "")
                }
            }
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 8)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.0 == 8)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.1 == 8)
            #expect(fixture.model.nativeAcceptedBindingStateForTesting.2 == 0)
            #expect(fixture.model.localCaptionWasEnqueuedForTesting(texts[8]))
        } catch {
            Issue.record("unregistered staging stopped at index \(activeCaptionIndex), bindings/staged/registered \(fixture.model.nativeAcceptedBindingStateForTesting), pending captions \(fixture.model.pendingCaptionCountForTesting)")
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test @available(macOS 26.0, *) func acceptedModernTimedFinalTransfersMappedCaptureIdentity() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in IntegrationNativeRealtimeDriver() }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let registrationGate = fixture.model.pauseNextNativeCoordinatorRegistrationForTesting()
        let startTask = Task { await fixture.model.startSession() }
        func cleanup() async {
            await registrationGate.release()
            await startTask.value
            let translations = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            (translations + transfers).forEach { $0.cancel() }
            display?.cancel()
            fixture.model.stopSession()
            for task in translations + transfers { await task.value }
            await display?.value
            await coordinator.stop()
        }

        do {
            try await registrationGate.waitUntilReached(timeoutNanoseconds: 8_000_000_000)
            let analyzerInputs = await session.installModernAnalyzerInputStreamForTesting()
            await session.appendCapturedAudioBufferForTesting(
                try integrationRealtimeBuffer(samples: [0.25, -0.25])
            )
            var iterator = analyzerInputs.makeAsyncIterator()
            let analyzerInput = try #require(await iterator.next())
            let bufferStartTime = try #require(analyzerInput.bufferStartTime)
            let duration = CMTime(value: 2, timescale: 16_000)
            let provenance = try #require(await session.modernAudioProvenanceForTesting(
                CMTimeRange(start: bufferStartTime, duration: duration)
            ))
            let installedIdentity = try #require(fixture.model.nativeCaptureIdentitiesForTesting[fixture.microphone.id])
            #expect(provenance.sourceToken == installedIdentity.0)
            #expect(provenance.captureGeneration == installedIdentity.1)
            #expect(provenance.sampleInterval == 0..<2)

            session.deliverRecognizedSentenceForTesting(RecognizedSentence(
                text: "modern timed final",
                audioProvenance: provenance
            ))
            #expect(fixture.model.acceptedFinalDeliveryCountForTesting == 1)
            await registrationGate.release()
            await startTask.value
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            let metadata = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            #expect(metadata.sourceID == fixture.microphone.id)
            #expect(metadata.captionID == fixture.model.transcriptEntries.first?.id)
            #expect(metadata.sampleInterval == provenance.sampleInterval)
            #expect(metadata.sourceToken == provenance.sourceToken)
            #expect(metadata.captureGeneration == provenance.captureGeneration)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func nativeConfigurationChangeDuringStartupInvalidatesThePendingDisclosureAuthorization() async throws {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        var settings = makeAppSettings(correction: .default)
        settings.selectedSourceIDs = [microphoneSource.id]
        settings.nativeRealtime = configuredNativeRealtimeSettings(
            enabledSourceIDs: [microphoneSource.id]
        )
        let store = SettingsStore(fileURL: settingsURL)
        store.save(settings)
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let model = AppModel(
            settingsStore: store,
            sourceCatalogService: TestSourceCatalogService(microphones: [microphoneSource]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        let resourceGate = AsyncTestGate()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        model.selectedSourceIDs = [microphoneSource.id]
        model.acknowledgeNativeRealtimeDisclosureForNextSession()
        model.setSessionResourcePreparationOperationForTesting {
            await resourceGate.suspend()
        }
        model.setLiveTranscriptionSessionFactoryForTesting { session }

        let startTask = Task { @MainActor in
            await model.startSession()
        }
        await resourceGate.waitUntilSuspended()
        var changedSettings = model.nativeRealtimeSettings
        changedSettings.profile = .openAI
        model.nativeRealtimeSettings = changedSettings
        await resourceGate.resume()
        await startTask.value

        #expect(model.sessionState == .running)
        #expect(drivers.all().isEmpty)
        #expect(await credentials.lookupCount() == 0)
        model.stopSession()

        // The same acknowledgement must also be invalidated before a session is
        // started, rather than only while a start is suspended.
        model.acknowledgeNativeRealtimeDisclosureForNextSession()
        var beforeStartSettings = model.nativeRealtimeSettings
        beforeStartSettings.credentialReference = "changed-native-key"
        model.nativeRealtimeSettings = beforeStartSettings
        let secondSession = LiveTranscriptionSession()
        secondSession.setStartOperationForTesting {
            await secondSession.beginRecognitionSessionForTesting()
        }
        model.setSessionResourcePreparationOperationForTesting {}
        model.setLiveTranscriptionSessionFactoryForTesting { secondSession }

        await model.startSession()

        #expect(model.sessionState == .running)
        #expect(drivers.all().isEmpty)
        #expect(await credentials.lookupCount() == 0)
        model.stopSession()
        await coordinator.stop()
    }

    @Test func nativeRealtimeStartsOnlyForSuccessfullyStartedOptedInSources() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id, applicationSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}

        let failedApplicationSession = LiveTranscriptionSession()
        failedApplicationSession.setStartOperationForTesting {
            throw IntegrationNativeLiveStartFailure()
        }
        let healthyMicrophoneSession = LiveTranscriptionSession()
        healthyMicrophoneSession.setStartOperationForTesting {
            await healthyMicrophoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [failedApplicationSession, healthyMicrophoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        await fixture.model.startSession()

        #expect(fixture.model.sessionState == .running)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        #expect(fixture.model.registeredLiveSessionForTesting(sourceID: applicationSource.id) == nil)
        #expect(fixture.model.registeredLiveSessionForTesting(sourceID: microphoneSource.id) === healthyMicrophoneSession)
        #expect(await failedApplicationSession.stopInvocationCountForTesting() == 1)
        #expect(await credentials.lookupCount() == 1)
        #expect(drivers.all().count == 1)

        let driver = try #require(drivers.all().first)
        let buffer = try integrationRealtimeBuffer(samples: [0.5, -0.5])
        await healthyMicrophoneSession.appendRealtimePCM16AudioForTesting(buffer)
        try await waitUntil { await driver.audioChunks().count == 1 }
        let chunks = await driver.audioChunks()
        let generation = try #require(await driver.startedGenerations().first)
        #expect(await driver.startedAliases() == ["audio-1"])
        #expect(chunks == [RealtimeAudioChunk(
            sourceAlias: "audio-1",
            generation: generation,
            capturedAtMonotonicNanoseconds: chunks[0].capturedAtMonotonicNanoseconds,
            startMonotonicNanoseconds: 0,
            endMonotonicNanoseconds: 125_000,
            pcm16LEData: Data([0x00, 0x40, 0x00, 0xc0]),
            sampleRate: 16_000
        )])
        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func readySiblingCaptionTransfersWhileFirstNativeDriverStartIsHeld() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, role in drivers.makeDriver(holdingRole: .applicationAudio, role: role) }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [applicationSource.id, microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.selectedSourceIDs = [fixture.application.id, fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.application.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.application.id] = "en"
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translationHarness = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            try await translationHarness.translate(text, source: source, target: target)
        }
        let applicationSession = LiveTranscriptionSession()
        let microphoneSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        let completion = IntegrationAsyncSignal()
        let startTask = Task {
            await fixture.model.startSession()
            await completion.resolve()
        }
        func cleanup() async {
            let allDrivers = drivers.all()
            for driver in allDrivers { await driver.resumeStart() }
            await startTask.value
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transfers = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let display = fixture.model.captionDisplayTaskSnapshotForTesting()
            (translationTasks + transfers).forEach { $0.cancel() }
            display?.cancel()
            await translationHarness.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            for task in translationTasks + transfers { await task.value }
            await display?.value
        }

        do {
            try await waitUntil { await drivers.driver(for: .applicationAudio)?.isStartSuspended() == true }
            try await waitUntil {
                fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil
            }
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            #expect(ready.sourceID == fixture.microphone.id)
            #expect(await completion.isResolved() == false)
            #expect(fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === microphoneSession)

            await microphoneSession.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await microphoneSession.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await microphoneSession.queueLegacyCommittedEmissionForTesting(
                text: "ready sibling final",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await microphoneSession.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            #expect(accepted.sourceToken == ready.sourceToken)
            #expect(accepted.captureGeneration == ready.captureGeneration)
            #expect(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: accepted.captionID) == ready)
            #expect(await completion.isResolved() == false)
            let microphoneDriver = try #require(drivers.driver(for: .microphone))
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(
                    sourceID: fixture.microphone.id,
                    captionID: accepted.captionID
                )
            }
            await microphoneDriver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "ready sibling corrected"
            ))
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText
                    == "ready sibling corrected"
            }
            #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.localSourceText
                == "ready sibling final")
            #expect(await translationHarness.requestCount(text: "ready sibling corrected") == 0)
            #expect(await completion.isResolved() == false)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func optingOutNativeSourceAWhileSourceBRemainsRunningPreservesBMetadata() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, role in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver, for: role)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [applicationSource.id, microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.selectedSourceIDs = [fixture.application.id, fixture.microphone.id]
        for sourceID in [fixture.application.id, fixture.microphone.id] {
            fixture.model.sourceLanguageOverrides[sourceID] = "en"
            fixture.model.sourceOutputLanguageOverrides[sourceID] = sourceID == fixture.microphone.id ? "zh-Hans" : "en"
        }
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            if text == "microphone correction across sibling opt-out" {
                return try await translations.translate(text, source: source, target: target)
            }
            return "local translation for \(text)"
        }
        let applicationSession = LiveTranscriptionSession()
        let microphoneSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting { await applicationSession.beginRecognitionSessionForTesting() }
        microphoneSession.setStartOperationForTesting { await microphoneSession.beginRecognitionSessionForTesting() }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }
        var heldApplicationDriver: IntegrationNativeRealtimeDriver?
        var heldSiblingCorrectionTask: Task<Void, Never>?
        func cleanup() async {
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let translationTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            (correctionTasks + translationTasks + transferTasks).forEach { $0.cancel() }
            heldSiblingCorrectionTask?.cancel()
            displayTask?.cancel()
            await heldApplicationDriver?.resumeStop()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            for task in correctionTasks + translationTasks + transferTasks { await task.value }
            await heldSiblingCorrectionTask?.value
            await displayTask?.value
        }
        do {
            await fixture.model.startSession()
            let applicationDriver = try #require(drivers.driver(for: .applicationAudio))
            await microphoneSession.beginLegacySampleMappingForTesting()
            let inputPCM = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await microphoneSession.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 0..<2)
            #expect(await microphoneSession.queueLegacyCommittedEmissionForTesting(
                text: "microphone caption before application opt-out",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await microphoneSession.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil
            }
            let beforeOptOut = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
            let microphoneDriver = try #require(drivers.driver(for: .microphone))
            try await waitUntil {
                await coordinator.captionCommitSucceededForTesting(
                    sourceID: fixture.microphone.id,
                    captionID: beforeOptOut.captionID
                )
            }
            let ready = try #require(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: beforeOptOut.captionID))
            await microphoneDriver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: beforeOptOut.captionID,
                utteranceID: beforeOptOut.utteranceID,
                text: "microphone correction across sibling opt-out"
            ))
            try await waitUntil { await translations.hasRequest(text: "microphone correction across sibling opt-out") }
            let savedSiblingCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            heldSiblingCorrectionTask = savedSiblingCorrectionTask
            await applicationDriver.suspendNextStop()
            heldApplicationDriver = applicationDriver
            var settings = fixture.model.nativeRealtimeSettings
            settings.enabledSourceIDs = [fixture.microphone.id]
            fixture.model.nativeRealtimeSettings = settings

            try await waitUntil { await applicationDriver.isStopSuspended() }
            #expect(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil)
            #expect(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).contains(beforeOptOut))
            #expect(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: beforeOptOut.captionID)?.sourceID == fixture.microphone.id)
            #expect(heldSiblingCorrectionTask?.isCancelled == false)
            await translations.release(
                text: "microphone correction across sibling opt-out",
                result: "healthy microphone translated correction"
            )
            try await waitUntil {
                fixture.model.nativeCorrectionSnapshotForTesting(captionID: beforeOptOut.captionID)?.translatedText
                    == "healthy microphone translated correction"
            }
            #expect(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: beforeOptOut.captionID)?.sourceID == fixture.microphone.id)
            #expect(await microphoneSession.appendLegacyNormalizedBufferForTesting(inputPCM, preservesIdentity: true) == 2..<4)
            #expect(await microphoneSession.queueLegacyCommittedEmissionForTesting(
                text: "healthy microphone after application opt-out",
                segments: [LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 2.0 / 16_000)]
            ))
            await microphoneSession.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil {
                fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).count == 2
            }
            let accepted = try #require(fixture.model.nativeAcceptedBindingsForTesting(sourceID: fixture.microphone.id).last)
            try await waitUntil {
                fixture.model.nativeAcceptedTransferDispositionForTesting(captionID: accepted.captionID) == .queued
            }
            #expect(accepted.sampleInterval == 2..<4)
            #expect(fixture.model.nativeAcceptedReadyIdentityForTesting(captionID: accepted.captionID)?.sourceID == fixture.microphone.id)
            #expect(fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === microphoneSession)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func missingNativeCredentialReportsSourceStatusAndKeepsLocalSessionRunning() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: nil)
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials)
        )
        let fixture = makeFixture(
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }

        await fixture.model.startSession()

        #expect(fixture.model.sessionState == .running)
        try await waitUntil {
            fixture.model.nativeRealtimeSourceStatuses[microphoneSource.id] != nil
        }
        let sourceStatus = try #require(fixture.model.nativeRealtimeSourceStatuses[microphoneSource.id])
        #expect(sourceStatus.contains(microphoneSource.name))
        #expect(sourceStatus == fixture.model.localized(
            .nativeRealtimeCredentialUnavailableFormat,
            microphoneSource.name
        ))
        #expect(!sourceStatus.contains("test-native-key"))
        #expect(!sourceStatus.contains("fake-secret"))
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Local caption remains available",
            translation: "本地字幕仍可用",
            audioWAVData: nil
        )
        #expect(fixture.model.transcriptEntries.first?.sourceText == "Local caption remains available")

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func nativeAcceptedCaptionOriginalTranslationDoesNotBecomeLegacyCorrectionAfterModeSwitch() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        let translations = IntegrationNativeTranslationHarness()
        fixture.model.setTranslationOperationForTesting { text, source, target in
            if text == "native mode caption held before local translation" || text == "native corrected for legacy switch" {
                return try await translations.translate(text, source: source, target: target)
            }
            return "local translation for \(text)"
        }
        let startTask = Task { await fixture.model.startSession() }
        var heldOriginalTask: Task<Void, Never>?
        var heldCorrectionTask: Task<Void, Never>?
        var originalDisplayTask: Task<Void, Never>?
        func cleanup() async {
            let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
            let localTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
            let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
            let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
            heldOriginalTask?.cancel()
            heldCorrectionTask?.cancel()
            (correctionTasks + localTasks + transferTasks).forEach { $0.cancel() }
            displayTask?.cancel()
            await translations.releaseAll()
            fixture.model.stopSession()
            await coordinator.stop()
            await startTask.value
            for task in correctionTasks + localTasks + transferTasks { await task.value }
            await heldOriginalTask?.value
            await heldCorrectionTask?.value
            await originalDisplayTask?.value
            await displayTask?.value
        }

        do {
            try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
            let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
            await startTask.value
            await session.beginLegacySampleMappingForTesting()
            let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
            #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
            #expect(await session.queueLegacyCommittedEmissionForTesting(
                text: "native mode caption held before local translation",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ))
            await session.deliverQueuedCommittedEmissionForTesting()
            try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
            let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
            try await waitUntil { await translations.hasRequest(text: "native mode caption held before local translation") }
            let savedOriginalTask: Task<Void, Never> = try #require(
                fixture.model.captionTranslationTaskForTesting(captionID: accepted.captionID)
            )
            heldOriginalTask = savedOriginalTask
            let driver = try #require(drivers.all().first)
            try await waitUntil { await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID) }
            await driver.emit(.correctedText(
                sourceAlias: ready.alias,
                generation: ready.driverGeneration,
                captionID: accepted.captionID,
                utteranceID: accepted.utteranceID,
                text: "native corrected for legacy switch"
            ))
            try await waitUntil { await translations.hasRequest(text: "native corrected for legacy switch") }
            let savedCorrectionTask: Task<Void, Never> = try #require(
                fixture.model.nativeCorrectionTasksSnapshotForTesting().first
            )
            heldCorrectionTask = savedCorrectionTask
            await translations.release(text: "native corrected for legacy switch", result: "native corrected translation")
            await heldCorrectionTask?.value
            #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText
                == "native corrected for legacy switch")

            var nativeSettings = fixture.model.nativeRealtimeSettings
            nativeSettings.enabledSourceIDs = []
            fixture.model.nativeRealtimeSettings = nativeSettings
            try await waitUntil { fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil }
            fixture.model.correction.settings = configuredCorrectionSettings()
            try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }

            let savedDisplayTask: Task<Void, Never> = try #require(
                fixture.model.captionDisplayTaskSnapshotForTesting()
            )
            originalDisplayTask = savedDisplayTask
            await translations.release(text: "native mode caption held before local translation", result: "late original translation")
            await heldOriginalTask?.value
            try await waitUntil(timeout: .seconds(8)) {
                !fixture.model.pendingCaptionIDsForTesting.contains(accepted.captionID)
            }
            await originalDisplayTask?.value
            #expect(!fixture.model.submittedCorrectionCaptionIDsForTesting.contains(accepted.captionID))
            let legacyCorrectionCallCount = await fixture.responder.callCount()
            #expect(legacyCorrectionCallCount == 0)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func switchingNativeSourceToLegacyWaitsForNativeStopWithoutBlockingSibling() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let applicationSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        let microphoneSession = LiveTranscriptionSession()
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        await fixture.model.startSession()
        let driver = try #require(drivers.all().first)
        await driver.suspendNextStop()
        var legacySettings = fixture.model.nativeRealtimeSettings
        legacySettings.enabledSourceIDs = []
        fixture.model.nativeRealtimeSettings = legacySettings

        // The native reader must be stopped before this source can enter the legacy
        // provider, while the sibling application source continues independently.
        try await waitUntil { await driver.isStopSuspended() }
        fixture.model.correction.settings = configuredCorrectionSettings()
        try await waitUntil {
            let microphoneEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
            let applicationEnabled = await applicationSession.correctionAudioCaptureEnabledForTesting()
            return !microphoneEnabled && applicationEnabled
        }
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Transition caption must wait",
            translation: "切换中的字幕应等待",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "Sibling continues",
            translation: "另一个来源继续",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id])

        await driver.resumeStop()
        try await waitUntil {
            await microphoneSession.correctionAudioCaptureEnabledForTesting()
        }
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Legacy mode now safe",
            translation: "现在可以安全使用传统模式",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }
        #expect(await fixture.responder.startedSourceIDs().sorted() == [
            fixture.application.id,
            fixture.microphone.id
        ].sorted())

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func repeatedNativeToLegacyChangesKeepLegacyAudioRevokedUntilTheFirstStopFinishes() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(isEnabled: false),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let applicationSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        let microphoneSession = LiveTranscriptionSession()
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        await fixture.model.startSession()
        let driver = try #require(drivers.all().first)
        await driver.suspendNextStop()

        var legacySettings = fixture.model.nativeRealtimeSettings
        legacySettings.enabledSourceIDs = []
        fixture.model.nativeRealtimeSettings = legacySettings
        try await waitUntil { await driver.isStopSuspended() }

        fixture.model.correction.settings = configuredCorrectionSettings()
        var nativeAgainSettings = legacySettings
        nativeAgainSettings.enabledSourceIDs = [microphoneSource.id]
        fixture.model.nativeRealtimeSettings = nativeAgainSettings
        fixture.model.nativeRealtimeSettings = legacySettings
        try await waitForQuiescence()

        #expect(await microphoneSession.correctionAudioCaptureEnabledForTesting() == false)
        #expect(await applicationSession.correctionAudioCaptureEnabledForTesting())
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Repeated switch must not release legacy audio",
            translation: "重复切换不能释放传统音频",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "Sibling legacy correction continues",
            translation: "兄弟来源传统校正继续",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id])

        await driver.resumeStop()
        try await waitUntil { await microphoneSession.correctionAudioCaptureEnabledForTesting() }
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Legacy capture resumes only after stop",
            translation: "传统采集仅在停止后恢复",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func switchingLegacySourceToNativeMidSessionRequiresFreshDisclosureAndLeavesSibling() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(nativeRealtimeSessionCoordinator: coordinator)
        defer { fixture.removeSettingsFile() }
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let applicationSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        let microphoneSession = LiveTranscriptionSession()
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        await fixture.model.startSession()
        let microphoneInitiallyEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
        let applicationInitiallyEnabled = await applicationSession.correctionAudioCaptureEnabledForTesting()
        #expect(microphoneInitiallyEnabled)
        #expect(applicationInitiallyEnabled)

        fixture.model.nativeRealtimeSettings = configuredNativeRealtimeSettings(
            enabledSourceIDs: [microphoneSource.id]
        )
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Native mode is pending a fresh disclosure",
            translation: "原生模式等待重新披露",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "Sibling remains in legacy mode",
            translation: "另一个来源仍使用传统模式",
            audioWAVData: sampleWAV
        )

        try await waitUntil {
            let callCount = await fixture.responder.callCount()
            let microphoneEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
            return callCount == 1 && !microphoneEnabled
        }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id])
        #expect(await credentials.lookupCount() == 0)
        #expect(drivers.all().isEmpty)
        #expect(fixture.model.sessionState == .running)
        #expect(Set(fixture.model.transcriptEntries.map(\.sourceID)) == [
            fixture.microphone.id,
            fixture.application.id
        ])

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func nativeConfigurationEditsRevokeHeldAcceptedCorrectionAndOldEvents() async throws {
        enum Setting: String, CaseIterable {
            case profile
            case region
            case credentialReference
            case qwenWorkspaceID
        }

        func verify(_ setting: Setting) async throws {
            let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
            let drivers = IntegrationNativeDriverBag()
            let coordinator = NativeRealtimeSessionCoordinator(
                credentialStore: RealtimeCredentialStore(backend: credentials),
                driverFactory: { _, _, _ in
                    let driver = IntegrationNativeRealtimeDriver()
                    drivers.append(driver)
                    return driver
                }
            )
            let fixture = makeFixture(
                correctionSettings: configuredCorrectionSettings(isEnabled: false),
                nativeRealtimeSettings: configuredNativeRealtimeSettings(enabledSourceIDs: [microphoneSource.id]),
                nativeRealtimeSessionCoordinator: coordinator
            )
            defer { fixture.removeSettingsFile() }
            let session = LiveTranscriptionSession()
            session.setStartOperationForTesting { await session.beginRecognitionSessionForTesting() }
            fixture.model.selectedSourceIDs = [fixture.microphone.id]
            fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
            fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "zh-Hans"
            fixture.model.setSessionResourcePreparationOperationForTesting {}
            fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
            fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
            let translations = IntegrationNativeTranslationHarness()
            let correctionText = "config-held correction for \(setting.rawValue)"
            let staleEventText = "config-stale event for \(setting.rawValue)"
            fixture.model.setTranslationOperationForTesting { text, source, target in
                if text == correctionText || text == staleEventText {
                    return try await translations.translate(text, source: source, target: target)
                }
                return "local translation for \(text)"
            }
            let startTask = Task { await fixture.model.startSession() }
            var capturedCorrectionTask: Task<Void, Never>?
            func cleanup() async {
                startTask.cancel()
                let correctionTasks = fixture.model.nativeCorrectionTasksSnapshotForTesting()
                let localTasks = fixture.model.captionTranslationTasksSnapshotForTesting()
                let transferTasks = fixture.model.nativeCaptionTransferTasksSnapshotForTesting()
                let displayTask = fixture.model.captionDisplayTaskSnapshotForTesting()
                (correctionTasks + localTasks + transferTasks).forEach { $0.cancel() }
                displayTask?.cancel()
                await translations.releaseAll()
                fixture.model.stopSession()
                await coordinator.stop()
                await startTask.value
                for task in correctionTasks + localTasks + transferTasks { await task.value }
                await capturedCorrectionTask?.value
                await displayTask?.value
            }

            do {
                try await waitUntil { fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id) != nil }
                let ready = try #require(fixture.model.nativeReadyIdentityForTesting(sourceID: fixture.microphone.id))
                await startTask.value
                await session.beginLegacySampleMappingForTesting()
                let pcm = try integrationRealtimeBuffer(samples: [0.25, -0.25])
                #expect(await session.appendLegacyNormalizedBufferForTesting(pcm, preservesIdentity: true) == 0..<2)
                let originalText = "config original caption for \(setting.rawValue)"
                #expect(await session.queueLegacyCommittedEmissionForTesting(
                    text: originalText,
                    segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
                ))
                await session.deliverQueuedCommittedEmissionForTesting()
                try await waitUntil { await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id) != nil }
                let accepted = try #require(await fixture.model.nativeAcceptedMetadataForTesting(sourceID: fixture.microphone.id))
                try await waitUntil { await coordinator.captionCommitSucceededForTesting(sourceID: accepted.sourceID, captionID: accepted.captionID) }
                let driver = try #require(drivers.all().first)
                await driver.emit(.correctedText(
                    sourceAlias: ready.alias,
                    generation: ready.driverGeneration,
                    captionID: accepted.captionID,
                    utteranceID: accepted.utteranceID,
                    text: correctionText
                ))
                try await waitUntil { await translations.hasRequest(text: correctionText) }
                let savedCorrectionTask: Task<Void, Never> = try #require(
                    fixture.model.nativeCorrectionTasksSnapshotForTesting().first
                )
                capturedCorrectionTask = savedCorrectionTask
                #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText == correctionText)

                var settings = fixture.model.nativeRealtimeSettings
                switch setting {
                case .profile: settings.profile = .openAI
                case .region: settings.region = .singapore
                case .credentialReference: settings.credentialReference = "replacement-native-key"
                case .qwenWorkspaceID: settings.qwenWorkspaceID = "replacement-workspace"
                }
                fixture.model.nativeRealtimeSettings = settings
                #expect(capturedCorrectionTask?.isCancelled == true)
                try await waitUntil { fixture.model.nativeAcceptedBindingsForTesting(sourceID: accepted.sourceID).isEmpty }
                await translations.release(text: correctionText, result: "stale corrected translation")
                await capturedCorrectionTask?.value
                fixture.model.deliverNativeCaptionEventForTesting(RealtimeCaptionEventEnvelope(
                    sourceID: accepted.sourceID,
                    sourceToken: accepted.sourceToken,
                    captureGeneration: accepted.captureGeneration,
                    sourceAlias: ready.alias,
                    driverGeneration: ready.driverGeneration,
                    captionID: accepted.captionID,
                    utteranceID: accepted.utteranceID,
                    sourceLanguageID: accepted.sourceLanguageID,
                    targetLanguageID: accepted.targetLanguageID,
                    kind: .correctedText(staleEventText)
                ))
                #expect(await translations.requestCount(text: staleEventText) == 0)
                #expect(fixture.model.nativeCorrectionSnapshotForTesting(captionID: accepted.captionID) == nil)
                #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.sourceText == correctionText)
                #expect(fixture.model.transcriptEntries.first(where: { $0.id == accepted.captionID })?.translatedText.isEmpty == true)
                #expect(await credentials.lookupCount() == 1)
                #expect(await driver.startedAliases().count == 1)
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }

        for setting in Setting.allCases {
            try await verify(setting)
        }
    }

    @Test func nativeProfileChangeDuringCredentialLookupRevokesUndisclosedStartup() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.selectedSourceIDs = [microphoneSource.id]
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }
        await credentials.suspendNextLookup()

        let startTask = Task { await fixture.model.startSession() }
        try await waitUntil { await credentials.isLookupSuspended() }
        var updatedSettings = fixture.model.nativeRealtimeSettings
        updatedSettings.profile = .openAI
        fixture.model.nativeRealtimeSettings = updatedSettings
        await credentials.resumeLookup()
        await startTask.value

        #expect(fixture.model.sessionState == .running)
        #expect(fixture.model.registeredLiveSessionForTesting(sourceID: microphoneSource.id) === session)
        #expect(await credentials.lookupCount() == 1)
        #expect(drivers.all().isEmpty)
        #expect(await coordinator.activeSourceIDs().isEmpty)
        try await waitForQuiescence()
        #expect(fixture.model.nativeRealtimeSourceStatuses.isEmpty)
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Local capture survived profile change",
            translation: "本地采集不受配置切换影响",
            audioWAVData: nil
        )
        #expect(fixture.model.transcriptEntries.first?.sourceText == "Local capture survived profile change")

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func nativeRealtimeModeSuppressesLegacyRequestsOnlyForThatSource() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}

        let applicationSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        let microphoneSession = LiveTranscriptionSession()
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }

        await fixture.model.startSession()

        try await waitUntil {
            let microphoneEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
            let applicationEnabled = await applicationSession.correctionAudioCaptureEnabledForTesting()
            return !microphoneEnabled && applicationEnabled
        }
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Native source local caption",
            translation: "本地字幕",
            audioWAVData: sampleWAV
        )
        try await waitForQuiescence()

        #expect(await fixture.responder.callCount() == 0)
        #expect(fixture.model.transcriptEntries.first?.sourceID == fixture.microphone.id)

        fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "Legacy source caption",
            translation: "传统字幕",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id])

        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func localCaptionDisplaysBeforeCorrectionAndBackfillsByID() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "helo world",
            translation: "你好 世界",
            audioWAVData: sampleWAV
        )

        #expect(fixture.model.overlayState?.sourceText == "helo world")
        #expect(fixture.model.overlayState?.translatedText == "你好 世界")
        #expect(fixture.model.transcriptEntries.first?.sourceText == "helo world")
        #expect(fixture.model.transcriptEntries.first?.translatedText == "你好 世界")
        try await waitUntil { await fixture.responder.callCount() == 1 }
        let epoch = fixture.model.overlayState?.captionEpoch

        try await releaseHeldCorrection(
            fixture.responder,
            captionID: captionID,
            output: .init(correctedOriginal: "hello world", correctedTranslation: "你好，世界")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first?.sourceText == "hello world"
        }

        #expect(fixture.model.overlayState?.sourceText == "hello world")
        #expect(fixture.model.overlayState?.translatedText == "你好，世界")
        #expect(fixture.model.overlayState?.captionEpoch == epoch)
        #expect(fixture.model.transcriptEntries.first?.localSourceText == "helo world")
        #expect(fixture.model.transcriptEntries.first?.localTranslatedText == "你好 世界")
    }

    @Test func identicalAcceptedFinalsFromDifferentSourcesAreNotDeduplicated() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let microphoneSession = LiveTranscriptionSession()
        let applicationSession = LiveTranscriptionSession()
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceLanguageOverrides[fixture.application.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.application.id] = "en"
        fixture.model.registerSuccessfulLiveSessionForTesting(
            microphoneSession,
            source: fixture.microphone,
            deliverRecognizedSentences: true
        )
        fixture.model.registerSuccessfulLiveSessionForTesting(
            applicationSession,
            source: fixture.application,
            deliverRecognizedSentences: true
        )
        microphoneSession.deliverRecognizedSentenceForTesting(
            RecognizedSentence(text: "same final", promotionSegmentID: nil, audioWAVData: nil)
        )
        applicationSession.deliverRecognizedSentenceForTesting(
            RecognizedSentence(text: "same final", promotionSegmentID: nil, audioWAVData: nil)
        )

        #expect(fixture.model.pendingCaptionCountForTesting == 2)
    }

    @Test func textOnlyResultChangesOnlyTranslationAndPreservesLocalOriginal() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "local original",
            translation: "local translation",
            audioWAVData: nil
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: captionID,
            output: .init(correctedOriginal: "must be ignored", correctedTranslation: "corrected translation")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first?.translatedText == "corrected translation"
        }

        let entry = try #require(fixture.model.transcriptEntries.first)
        #expect(entry.sourceText == "local original")
        #expect(entry.localSourceText == "local original")
        #expect(entry.correctedSourceText == nil)
        #expect(fixture.model.overlayState?.sourceText == "local original")
    }

    @Test func lateResultBackfillsHistoryButNeverReplacesNewerCurrentCaptionOrReplaysEntrance() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let firstID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "first local",
            translation: "first translation",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        _ = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "second local",
            translation: "second translation",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        let epoch = fixture.model.overlayState?.captionEpoch

        try await releaseHeldCorrection(
            fixture.responder,
            captionID: firstID,
            output: .init(correctedOriginal: "first corrected", correctedTranslation: "first corrected translation")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first(where: { $0.id == firstID })?.sourceText == "first corrected"
        }

        #expect(fixture.model.overlayState?.sourceText == "second local")
        #expect(fixture.model.overlayState?.translatedText == "second translation")
        #expect(fixture.model.overlayState?.captionEpoch == epoch)
        #expect(fixture.model.overlayState?.history.first(where: { $0.id == firstID })?.sourceText == "first corrected")
        #expect(fixture.model.overlayState?.history.first(where: { $0.id == firstID })?.translatedText == "first corrected translation")
    }

    @Test func staleCorrectionSessionGenerationCannotMutateNewSession() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()
        let oldGeneration = fixture.model.correction.sessionGeneration

        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "old local",
            translation: "old translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        fixture.model.beginCorrectionSessionForTesting()
        #expect(fixture.model.correction.sessionGeneration > oldGeneration)

        try await releaseHeldCorrection(
            fixture.responder,
            captionID: captionID,
            output: .init(correctedOriginal: "stale corrected", correctedTranslation: "stale translation")
        )
        try await waitForQuiescence()

        #expect(fixture.model.transcriptEntries.first?.sourceText == "old local")
        #expect(fixture.model.transcriptEntries.first?.translatedText == "old translation")
    }

    @Test func unknownCurrentGenerationCorrectionResultIsStrictNoOp() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()
        let unknownCaptionID = UUID()
        let overlayBefore = fixture.model.overlayState
        let transcriptBefore = fixture.model.transcriptEntries

        fixture.model.correction.enqueue(CorrectionJob(
            captionID: unknownCaptionID,
            sessionGeneration: fixture.model.correction.sessionGeneration,
            capturedAt: Date(),
            sourceID: fixture.microphone.id,
            sourceName: fixture.microphone.name,
            sourceLanguageID: "en",
            targetLanguageID: "zh-Hans",
            localOriginal: "unknown local original",
            localTranslation: "unknown local translation",
            audioWAVData: nil
        ))
        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(fixture.model.correctedCaptionCountForTesting == 0)
        let receiptCount = fixture.model.correctionResultReceiptCountForTesting

        try await releaseHeldCorrection(
            fixture.responder,
            captionID: unknownCaptionID,
            output: .init(
                correctedOriginal: nil,
                correctedTranslation: "unknown corrected translation"
            )
        )
        try await waitUntil {
            fixture.model.correctionResultReceiptCountForTesting == receiptCount + 1
        }

        #expect(fixture.model.correctedCaptionCountForTesting == 0)
        #expect(fixture.model.overlayState == overlayBefore)
        #expect(fixture.model.transcriptEntries == transcriptBefore)
    }

    @Test func heldResponderRejectsUnknownCaptionIDBeforeReleasingBoundRequest() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()
        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "bound request",
            translation: "bound translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await fixture.responder.associateNextCall(with: captionID)

        let releasedUnknownCaption = await fixture.responder.release(
            captionID: UUID(),
            output: .init(correctedOriginal: "wrong", correctedTranslation: "wrong")
        )
        #expect(releasedUnknownCaption == false)
        let releasedBoundCaption = await fixture.responder.release(
            captionID: captionID,
            output: .init(correctedOriginal: "bound corrected", correctedTranslation: "bound corrected translation")
        )
        #expect(releasedBoundCaption)
        try await waitUntil {
            fixture.model.transcriptEntries.first?.sourceText == "bound corrected"
        }
        #expect(fixture.model.submittedCorrectionCaptionIDsForTesting.isEmpty)
    }

    @Test func correctedCaptionTrackingPrunesAfterTranscriptClearAndHistoryEviction() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()
        let historyLimit = fixture.model.overlayHistoryLimitForTesting

        for index in 0 ..< historyLimit + 2 {
            let captionID = fixture.model.commitLocalCaptionForTesting(
                source: fixture.microphone,
                original: "local \(index)",
                translation: "translation \(index)",
                audioWAVData: sampleWAV
            )
            try await waitUntil { await fixture.responder.callCount() == index + 1 }
            try await releaseHeldCorrection(
                fixture.responder,
                captionID: captionID,
                output: .init(
                    correctedOriginal: "corrected \(index)",
                    correctedTranslation: "corrected translation \(index)"
                )
            )
            try await waitUntil {
                fixture.model.transcriptEntries.first(where: { $0.id == captionID })?.sourceText
                    == "corrected \(index)"
            }
            fixture.model.clearTranscript()
        }

        #expect(fixture.model.overlayState?.history.count == historyLimit)
        #expect(fixture.model.correctedCaptionCountForTesting == historyLimit + 1)
    }

    @Test func submittedTrackingPrunesEvictedFailureButRetainsActiveHistoryCaption() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let failedCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "failed local",
            translation: "failed translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await fixture.responder.associateNextCall(with: failedCaptionID)
        fixture.responder.cancelAll()
        try await waitUntil {
            if case .warning = fixture.model.correction.status {
                return true
            }
            return false
        }

        let activeCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "active local",
            translation: "active translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }
        try await fixture.responder.associateNextCall(with: activeCaptionID)
        fixture.model.clearTranscript()
        fixture.model.setCorrectionEnabled(false, for: fixture.microphone)

        for index in 0 ..< fixture.model.overlayHistoryLimitForTesting {
            fixture.model.commitLocalCaptionForTesting(
                source: fixture.microphone,
                original: "local \(index)",
                translation: "translation \(index)",
                audioWAVData: sampleWAV
            )
            fixture.model.clearTranscript()
        }

        #expect(fixture.model.overlayState?.history.contains(where: { $0.id == failedCaptionID }) == false)
        #expect(fixture.model.overlayState?.history.contains(where: { $0.id == activeCaptionID }) == true)
        #expect(fixture.model.submittedCorrectionCaptionIDsForTesting == [activeCaptionID])

        #expect(await fixture.responder.release(
            captionID: activeCaptionID,
            output: .init(
                correctedOriginal: "active corrected",
                correctedTranslation: "active corrected translation"
            )
        ))
        try await waitUntil {
            fixture.model.overlayState?.history.first(where: { $0.id == activeCaptionID })?.sourceText
                == "active corrected"
        }
        #expect(fixture.model.submittedCorrectionCaptionIDsForTesting.isEmpty)
    }

    @Test func disabledPoliciesDoNotSubmitWhileEnabledSiblingStillDoes() async throws {
        let globallyDisabled = makeFixture(correctionSettings: configuredCorrectionSettings(isEnabled: false))
        defer { globallyDisabled.removeSettingsFile() }
        globallyDisabled.model.beginCorrectionSessionForTesting()
        _ = globallyDisabled.model.commitLocalCaptionForTesting(
            source: globallyDisabled.microphone,
            original: "global local",
            translation: "global translation",
            audioWAVData: sampleWAV
        )
        try await waitForQuiescence()
        #expect(await globallyDisabled.responder.callCount() == 0)
        #expect(globallyDisabled.model.overlayState?.sourceText == "global local")

        let sourceDisabled = makeFixture(
            correctionSettings: configuredCorrectionSettings(disabledSourceIDs: ["mic-1"])
        )
        defer { sourceDisabled.removeSettingsFile() }
        sourceDisabled.model.beginCorrectionSessionForTesting()
        _ = sourceDisabled.model.commitLocalCaptionForTesting(
            source: sourceDisabled.microphone,
            original: "disabled source",
            translation: "disabled translation",
            audioWAVData: sampleWAV
        )
        let siblingID = sourceDisabled.model.commitLocalCaptionForTesting(
            source: sourceDisabled.application,
            original: "enabled sibling",
            translation: "enabled translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await sourceDisabled.responder.callCount() == 1 }
        #expect(await sourceDisabled.responder.startedSourceIDs() == ["app-1"])
        try await releaseHeldCorrection(
            sourceDisabled.responder,
            captionID: siblingID,
            output: .init(correctedOriginal: "corrected sibling", correctedTranslation: "corrected enabled translation")
        )
        try await waitUntil {
            sourceDisabled.model.transcriptEntries.first(where: { $0.id == siblingID })?.sourceText == "corrected sibling"
        }
    }

    @Test func isolatedSourcePolicyReachesCoordinatorContextSelection() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let micFirst = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "mic first",
            translation: "mic translated",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: micFirst,
            output: .init(correctedOriginal: "mic corrected", correctedTranslation: "mic corrected translation")
        )
        try await waitUntil { fixture.model.transcriptEntries.first?.sourceText == "mic corrected" }

        let appFirst = fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "app first",
            translation: "app translated",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: appFirst,
            output: .init(correctedOriginal: "app corrected", correctedTranslation: "app corrected translation")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first(where: { $0.id == appFirst })?.sourceText == "app corrected"
        }

        fixture.model.correction.settings.isolatedContextSourceIDs = [fixture.microphone.id]
        _ = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "mic second",
            translation: "mic second translated",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 3)
        )
        try await waitUntil { await fixture.responder.callCount() == 3 }

        #expect(await fixture.responder.contextSourceIDs(call: 2) == ["mic-1"])
    }

    @Test func emptyLocalTranslationStillSubmitsExactlyOnce() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        _ = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "needs translation",
            translation: "",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }

        #expect(await fixture.responder.currentLocalTranslations() == [""])
        #expect(fixture.model.transcriptEntries.first?.localTranslatedText == "")
    }

    @Test func sourceDisableThenReenableCannotSubmitPreviouslyCapturedPendingAudio() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()
        let captionID = fixture.model.enqueuePendingLocalCaptionForTesting(
            source: fixture.microphone,
            original: "pending local",
            audioWAVData: sampleWAV,
            capturedAt: Date(timeIntervalSince1970: 7)
        )

        fixture.model.correction.settings.disabledSourceIDs = [fixture.microphone.id]
        fixture.model.correction.settings.disabledSourceIDs = []
        fixture.model.finalizePendingLocalCaptionForTesting(
            captionID: captionID,
            translation: "pending translation"
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }

        #expect(await fixture.responder.audioPresence() == [false])
    }

    @Test func laterLocalTranslationBackfillRetainsLocalValueWithoutResubmissionOrCorrectedDisplayOverwrite() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "local original",
            translation: "",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: captionID,
            output: .init(correctedOriginal: "corrected original", correctedTranslation: "corrected translation")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first?.translatedText == "corrected translation"
        }

        fixture.model.applyLocalTranslationForTesting("late local translation", captionID: captionID)

        let entry = try #require(fixture.model.transcriptEntries.first)
        #expect(await fixture.responder.callCount() == 1)
        #expect(entry.localTranslatedText == "late local translation")
        #expect(entry.translatedText == "corrected translation")
        #expect(fixture.model.overlayState?.translatedText == "corrected translation")
    }

    @Test func assistantSnapshotUsesCorrectedEffectiveValuesWithSourceAndLanguageMetadata() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        fixture.model.beginCorrectionSessionForTesting()

        let captionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "app local original",
            translation: "app local translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: captionID,
            output: .init(correctedOriginal: "app corrected original", correctedTranslation: "app corrected translation")
        )
        try await waitUntil {
            fixture.model.transcriptEntries.first?.sourceText == "app corrected original"
        }

        let entry = try #require(fixture.model.assistantTranscriptSnapshot().entries.first)
        #expect(entry.sourceText == "app corrected original")
        #expect(entry.translatedText == "app corrected translation")
        #expect(entry.sourceName == "Conference App")
        #expect(entry.sourceLanguageID == "en")
        #expect(entry.targetLanguageID == "zh-Hans")
        #expect(entry.sourceLanguageName == fixture.model.languageName(for: "en"))
        #expect(entry.targetLanguageName == fixture.model.languageName(for: "zh-Hans"))
    }

    @Test func stopFatalAndFullStartupFailureEndCorrectionAndClearEveryLiveAudioBuffer() async throws {
        try await verifyTerminalCleanup { $0.stopSession() }
        try await verifyTerminalCleanup { $0.failLiveSessionForTesting() }
        try await verifyTerminalCleanup { $0.completeFullStartupFailureForTesting() }
    }

    @Test func stopDuringResourcePreparationCannotResumeStaleSessionStart() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let resourceGate = AsyncTestGate()
        var createdSessions: [LiveTranscriptionSession] = []
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {
            await resourceGate.suspend()
        }
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            let session = LiveTranscriptionSession()
            session.setStartOperationForTesting {}
            createdSessions.append(session)
            return session
        }

        let startTask = Task { @MainActor in
            await fixture.model.startSession()
        }
        await resourceGate.waitUntilSuspended()

        fixture.model.stopSession()
        let terminalCorrectionGeneration = fixture.model.correction.sessionGeneration
        await resourceGate.resume()
        await startTask.value

        #expect(createdSessions.isEmpty)
        #expect(fixture.model.correction.sessionGeneration == terminalCorrectionGeneration)
        #expect(fixture.model.correctionSessionIsActiveForTesting == false)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 0)
        #expect(fixture.model.sessionState == .idle)
    }

    @Test func stopDuringSourceStartStopsOnlyTheStaleLocalSession() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let sourceStartGate = AsyncTestGate()
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await sourceStartGate.suspend()
        }
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting { session }

        let startTask = Task { @MainActor in
            await fixture.model.startSession()
        }
        await sourceStartGate.waitUntilSuspended()

        fixture.model.stopSession()
        let terminalCorrectionGeneration = fixture.model.correction.sessionGeneration
        await sourceStartGate.resume()
        await startTask.value

        #expect(await session.stopInvocationCountForTesting() == 1)
        #expect(fixture.model.correction.sessionGeneration == terminalCorrectionGeneration)
        #expect(fixture.model.correctionSessionIsActiveForTesting == false)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 0)
        #expect(fixture.model.sessionState == .idle)
    }

    @Test func olderStartCannotOverwriteASecondSuccessfulSession() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let firstStartGate = AsyncTestGate()
        let firstSession = LiveTranscriptionSession()
        firstSession.setStartOperationForTesting {
            await firstStartGate.suspend()
        }
        let secondSession = LiveTranscriptionSession()
        secondSession.setStartOperationForTesting {}
        var factoryCallCount = 0
        fixture.model.selectedSourceIDs = [fixture.microphone.id]
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { factoryCallCount += 1 }
            return factoryCallCount == 0 ? firstSession : secondSession
        }

        let firstStartTask = Task { @MainActor in
            await fixture.model.startSession()
        }
        await firstStartGate.waitUntilSuspended()

        await fixture.model.startSession()
        let currentCorrectionGeneration = fixture.model.correction.sessionGeneration
        #expect(fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === secondSession)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        #expect(fixture.model.sessionState == .running)

        await firstStartGate.resume()
        await firstStartTask.value

        #expect(await firstSession.stopInvocationCountForTesting() == 1)
        #expect(await secondSession.stopInvocationCountForTesting() == 0)
        #expect(fixture.model.correction.sessionGeneration == currentCorrectionGeneration)
        #expect(fixture.model.correctionSessionIsActiveForTesting)
        #expect(fixture.model.registeredLiveSessionForTesting(sourceID: fixture.microphone.id) === secondSession)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        #expect(fixture.model.sessionState == .running)
    }

    @Test func appModelTeardownEndsCorrectionAndClearsEveryLiveAudioBuffer() async throws {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let store = SettingsStore(fileURL: settingsURL)
        store.save(makeAppSettings(correction: configuredCorrectionSettings()))
        let responder = IntegrationHeldCorrectionResponder()
        let coordinator = RealtimeCorrectionCoordinator(
            settings: configuredCorrectionSettings(),
            responder: responder
        )
        let source = microphoneSource
        let session = LiveTranscriptionSession()
        weak var weakModel: AppModel?
        var model: AppModel? = AppModel(
            settingsStore: store,
            sourceCatalogService: TestSourceCatalogService(microphones: [source]),
            correction: coordinator,
            refreshLanguageCatalogs: false
        )
        weakModel = model
        model?.beginCorrectionSessionForTesting()
        model?.registerSuccessfulLiveSessionForTesting(session, source: source)
        try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }
        try await fillAudioBuffer(session)
        let activeGeneration = coordinator.sessionGeneration

        model = nil
        try await waitUntil {
            let captureEnabled = await session.correctionAudioCaptureEnabledForTesting()
            let frameCount = await session.correctionAudioFrameCountForTesting()
            return weakModel == nil
                && coordinator.sessionGeneration > activeGeneration
                && !captureEnabled
                && frameCount == 0
        }
    }

    @Test func appModelDeinitStopsNativeDriverAndFinishesItsCapture() async throws {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        var settings = makeAppSettings(correction: configuredCorrectionSettings())
        settings.selectedSourceIDs = [microphoneSource.id]
        settings.nativeRealtime = configuredNativeRealtimeSettings(
            enabledSourceIDs: [microphoneSource.id]
        )
        let store = SettingsStore(fileURL: settingsURL)
        store.save(settings)
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let session = LiveTranscriptionSession()
        session.setStartOperationForTesting {
            await session.beginRecognitionSessionForTesting()
        }
        weak var weakModel: AppModel?
        let driver: IntegrationNativeRealtimeDriver
        do {
            let model = AppModel(
                settingsStore: store,
                sourceCatalogService: TestSourceCatalogService(microphones: [microphoneSource]),
                nativeRealtimeSessionCoordinator: coordinator,
                refreshLanguageCatalogs: false
            )
            weakModel = model
            model.selectedSourceIDs = [microphoneSource.id]
            model.acknowledgeNativeRealtimeDisclosureForNextSession()
            model.setSessionResourcePreparationOperationForTesting {}
            model.setLiveTranscriptionSessionFactoryForTesting { session }
            await model.startSession()
            driver = try #require(drivers.all().first)
        }

        #expect(weakModel == nil, "The model must release when its owning scope ends")
        try await waitUntil { weakModel == nil }
        try await waitUntil {
            let stopCount = await driver.stopInvocationCount()
            let activeSourceIDs = await coordinator.activeSourceIDs()
            return stopCount > 0 && activeSourceIDs.isEmpty
        }
    }

    @Test func partialStartupControlsOnlySuccessfulSourceUsingCurrentPolicy() async throws {
        let settings = configuredCorrectionSettings(disabledSourceIDs: ["mic-1"])
        let fixture = makeFixture(correctionSettings: settings)
        defer { fixture.removeSettingsFile() }
        let successful = LiveTranscriptionSession()
        let failed = LiveTranscriptionSession()

        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(successful, source: fixture.application)
        try await waitUntil { await successful.correctionAudioCaptureEnabledForTesting() }

        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        #expect(await successful.correctionAudioCaptureEnabledForTesting())
        #expect(await failed.correctionAudioCaptureEnabledForTesting() == false)
    }

    @Test(arguments: CorrectionProviderIdentityField.allCases)
    func providerIdentityChangeDropsPendingWAVBeforeSubmittingLocalText(
        _ field: CorrectionProviderIdentityField
    ) async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(session, source: fixture.microphone)
        try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }

        let captionID = fixture.model.enqueuePendingLocalCaptionForTesting(
            source: fixture.microphone,
            original: "pending before provider change",
            audioWAVData: sampleWAV
        )
        var replacementSettings = fixture.model.correction.settings
        field.replace(in: &replacementSettings)
        fixture.model.correction.settings = replacementSettings
        fixture.model.finalizePendingLocalCaptionForTesting(
            captionID: captionID,
            translation: "local after provider change"
        )

        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(await fixture.responder.requestSettings(call: 0) == replacementSettings)
        #expect(await fixture.responder.audioPresence() == [false])
        #expect(await fixture.responder.requestModes() == [.textOnly])
        #expect(await fixture.responder.currentLocalTranslations() == ["local after provider change"])
    }

    @Test(arguments: CorrectionProviderIdentityField.allCases)
    func providerIdentityChangeClearsAndRearmsLiveSentenceAudioWithoutReplacingSession(
        _ field: CorrectionProviderIdentityField
    ) async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(session, source: fixture.microphone)
        try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }
        try await fillAudioBuffer(session)

        var replacementSettings = fixture.model.correction.settings
        field.replace(in: &replacementSettings)
        fixture.model.correction.settings = replacementSettings

        try await waitUntil {
            let enabled = await session.correctionAudioCaptureEnabledForTesting()
            let frameCount = await session.correctionAudioFrameCountForTesting()
            return enabled && frameCount == 0
        }
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        #expect(await session.correctionAudioCaptureEnabledForTesting())
    }

    @Test func providerResetUsesCurrentNativeAndRevocationPoliciesWhileRearmingOnlyLegacySibling() async throws {
        let credentials = IntegrationNativeCredentialBackend(secret: "fake-secret")
        let drivers = IntegrationNativeDriverBag()
        let coordinator = NativeRealtimeSessionCoordinator(
            credentialStore: RealtimeCredentialStore(backend: credentials),
            driverFactory: { _, _, _ in
                let driver = IntegrationNativeRealtimeDriver()
                drivers.append(driver)
                return driver
            }
        )
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(
                disabledSourceIDs: [localOnlySource.id]
            ),
            nativeRealtimeSettings: configuredNativeRealtimeSettings(
                enabledSourceIDs: [microphoneSource.id]
            ),
            nativeRealtimeSessionCoordinator: coordinator
        )
        defer { fixture.removeSettingsFile() }
        fixture.model.acknowledgeNativeRealtimeDisclosureForNextSession()
        fixture.model.setSessionResourcePreparationOperationForTesting {}
        let applicationSession = LiveTranscriptionSession()
        applicationSession.setStartOperationForTesting {
            await applicationSession.beginRecognitionSessionForTesting()
        }
        let microphoneSession = LiveTranscriptionSession()
        microphoneSession.setStartOperationForTesting {
            await microphoneSession.beginRecognitionSessionForTesting()
        }
        var nextSessionIndex = 0
        let sessions = [applicationSession, microphoneSession]
        fixture.model.setLiveTranscriptionSessionFactoryForTesting {
            defer { nextSessionIndex += 1 }
            return sessions[nextSessionIndex]
        }
        await fixture.model.startSession()

        let localOnlySession = LiveTranscriptionSession()
        let nativePolicyOnlySession = LiveTranscriptionSession()
        fixture.model.registerSuccessfulLiveSessionForTesting(
            localOnlySession,
            source: localOnlySource
        )
        fixture.model.registerSuccessfulLiveSessionForTesting(
            nativePolicyOnlySession,
            source: nativePolicyOnlySource
        )
        let driver = try #require(drivers.all().first)
        await driver.suspendNextStop()

        var replacementNativeSettings = fixture.model.nativeRealtimeSettings
        replacementNativeSettings.enabledSourceIDs = [nativePolicyOnlySource.id]
        fixture.model.nativeRealtimeSettings = replacementNativeSettings
        try await waitUntil { await driver.isStopSuspended() }
        var replacementCorrectionSettings = fixture.model.correction.settings
        replacementCorrectionSettings.model = "replacement-provider-model"
        fixture.model.correction.settings = replacementCorrectionSettings

        try await waitUntil {
            fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: fixture.microphone.id) == false
                && fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: fixture.application.id) == false
                && fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: localOnlySource.id) == false
                && fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: nativePolicyOnlySource.id) == false
        }
        #expect(await microphoneSession.correctionAudioCaptureEnabledForTesting() == false)
        #expect(await nativePolicyOnlySession.correctionAudioCaptureEnabledForTesting() == false)
        #expect(await localOnlySession.correctionAudioCaptureEnabledForTesting() == false)
        #expect(await applicationSession.correctionAudioCaptureEnabledForTesting())

        fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "Revoking native source must not reach legacy correction",
            translation: "撤销中的原生来源不得到达传统校正",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: nativePolicyOnlySource,
            original: "Native policy source must not reach legacy correction",
            translation: "原生策略来源不得到达传统校正",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: localOnlySource,
            original: "Local-only source must not reach legacy correction",
            translation: "仅本地来源不得到达传统校正",
            audioWAVData: sampleWAV
        )
        fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "Legacy sibling rearmed after provider reset",
            translation: "传统兄弟来源在提供者重置后重新启用",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id])
        #expect(await fixture.responder.audioPresence() == [true])

        await driver.resumeStop()
        fixture.model.stopSession()
        await coordinator.stop()
    }

    @Test func providerResetBarrierFencesDeferredOldWAVAndRearmsFreshAudio() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        fixture.model.sourceLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.sourceOutputLanguageOverrides[fixture.microphone.id] = "en"
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.pauseNextProviderAudioTransitionResetForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(
            session,
            source: fixture.microphone,
            deliverRecognizedSentences: true
        )
        try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }
        try await fillAudioBuffer(session)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Old."
        )

        var replacementSettings = fixture.model.correction.settings
        replacementSettings.model = "barrier-replacement-model"
        fixture.model.correction.settings = replacementSettings
        try await waitUntil {
            fixture.model.pausedProviderAudioTransitionResetCountForTesting == 1
        }

        await session.deliverQueuedCommittedEmissionForTesting()
        try await waitUntil(timeout: .seconds(5)) {
            await fixture.responder.callCount() == 1
        }
        #expect(await fixture.responder.requestSettings(call: 0) == replacementSettings)
        #expect(await fixture.responder.audioPresence() == [false])
        #expect(await fixture.responder.requestModes() == [.textOnly])

        let oldCaptionID = try #require(fixture.model.submittedCorrectionCaptionIDsForTesting.first)
        try await releaseHeldCorrection(
            fixture.responder,
            captionID: oldCaptionID,
            output: .init(correctedOriginal: nil, correctedTranslation: "Old.")
        )
        fixture.model.resumeOldestProviderAudioTransitionResetForTesting()
        try await waitUntil {
            let captureEnabled = await session.correctionAudioCaptureEnabledForTesting()
            return fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: fixture.microphone.id) == false
                && captureEnabled
        }
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 1)
        try await waitUntil(timeout: .seconds(5)) {
            fixture.model.pendingCaptionCountForTesting == 0
        }

        try await fillAudioBuffer(session)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Fresh."
        )
        await session.deliverQueuedCommittedEmissionForTesting()
        try await waitUntil(timeout: .seconds(8)) {
            await fixture.responder.callCount() == 2
        }
        #expect(await fixture.responder.audioPresence() == [false, true])
        #expect(await fixture.responder.requestModes() == [.textOnly, .audio])
    }

    @Test func olderProviderResetTaskCannotClearNewerTransition() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let session = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(session, source: fixture.microphone)
        try await waitUntil { await session.correctionAudioCaptureEnabledForTesting() }
        fixture.model.pauseNextProviderAudioTransitionResetForTesting()
        fixture.model.pauseNextProviderAudioTransitionResetForTesting()

        fixture.model.correction.settings.model = "first-replacement-model"
        try await waitUntil {
            fixture.model.pausedProviderAudioTransitionResetCountForTesting == 1
        }
        fixture.model.correction.settings.model = "second-replacement-model"
        try await waitUntil {
            fixture.model.pausedProviderAudioTransitionResetCountForTesting == 2
        }

        fixture.model.resumeOldestProviderAudioTransitionResetForTesting()
        try await waitUntil {
            fixture.model.pausedProviderAudioTransitionResetCountForTesting == 1
        }
        #expect(fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: fixture.microphone.id))

        fixture.model.resumeOldestProviderAudioTransitionResetForTesting()
        try await waitUntil {
            fixture.model.providerAudioTransitionIsActiveForTesting(sourceID: fixture.microphone.id) == false
        }
        #expect(await session.correctionAudioCaptureEnabledForTesting())
    }

    @Test func runtimePolicyChangesUpdateCaptureCancelSourceAndPreserveLocalSessions() async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let microphoneSession = LiveTranscriptionSession()
        let applicationSession = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(microphoneSession, source: fixture.microphone)
        fixture.model.registerSuccessfulLiveSessionForTesting(applicationSession, source: fixture.application)
        try await waitUntil {
            let microphoneEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
            let applicationEnabled = await applicationSession.correctionAudioCaptureEnabledForTesting()
            return microphoneEnabled && applicationEnabled
        }

        let applicationCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "app local",
            translation: "app translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 1 }
        let microphoneCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "mic local",
            translation: "mic translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }
        #expect(await fixture.responder.startedSourceIDs() == [fixture.application.id, fixture.microphone.id])
        try await fixture.responder.associateNextCall(
            with: microphoneCaptionID,
            sourceID: fixture.microphone.id
        )
        try await fixture.responder.associateNextCall(
            with: applicationCaptionID,
            sourceID: fixture.application.id
        )

        fixture.model.setCorrectionEnabled(false, for: fixture.microphone)
        try await waitUntil {
            let microphoneEnabled = await microphoneSession.correctionAudioCaptureEnabledForTesting()
            let applicationEnabled = await applicationSession.correctionAudioCaptureEnabledForTesting()
            return !microphoneEnabled && applicationEnabled
        }
        #expect(await fixture.responder.release(
            captionID: microphoneCaptionID,
            output: .init(correctedOriginal: "cancelled correction", correctedTranslation: "cancelled translation")
        ))
        #expect(await fixture.responder.release(
            captionID: applicationCaptionID,
            output: .init(correctedOriginal: "app corrected", correctedTranslation: "app corrected translation")
        ))
        try await waitUntil {
            fixture.model.transcriptEntries.first(where: { $0.id == applicationCaptionID })?.sourceText == "app corrected"
        }
        #expect(fixture.model.transcriptEntries.first(where: { $0.id == microphoneCaptionID })?.sourceText == "mic local")

        let generationBeforeDisable = fixture.model.correction.sessionGeneration
        fixture.model.correction.settings.isEnabled = false
        try await waitUntil {
            !(await applicationSession.correctionAudioCaptureEnabledForTesting())
        }
        #expect(fixture.model.correction.sessionGeneration > generationBeforeDisable)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 2)

        let generationBeforeEnable = fixture.model.correction.sessionGeneration
        fixture.model.correction.settings.isEnabled = true
        try await waitUntil {
            await applicationSession.correctionAudioCaptureEnabledForTesting()
        }
        #expect(fixture.model.correction.sessionGeneration > generationBeforeEnable)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 2)

        let generationBeforeProviderChange = fixture.model.correction.sessionGeneration
        fixture.model.correction.settings.model = "replacement-model"
        #expect(fixture.model.correction.sessionGeneration > generationBeforeProviderChange)
        #expect(fixture.model.liveTranscriptionSessionCountForTesting == 2)
    }

    @Test func successfulSourceCaptureFlagMatchesCorrectionPolicyAndDisabledBehaviorStaysLocalOnly() async throws {
        let fixture = makeFixture(
            correctionSettings: configuredCorrectionSettings(disabledSourceIDs: ["mic-1"])
        )
        defer { fixture.removeSettingsFile() }
        let microphoneSession = LiveTranscriptionSession()
        let applicationSession = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(microphoneSession, source: fixture.microphone)
        fixture.model.registerSuccessfulLiveSessionForTesting(applicationSession, source: fixture.application)
        try await waitUntil { await applicationSession.correctionAudioCaptureEnabledForTesting() }

        #expect(await microphoneSession.correctionAudioCaptureEnabledForTesting() == false)
        #expect(await applicationSession.correctionAudioCaptureEnabledForTesting())

        _ = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "unchanged original",
            translation: "unchanged translation",
            audioWAVData: sampleWAV
        )
        try await waitForQuiescence()
        #expect(await fixture.responder.callCount() == 0)
        #expect(fixture.model.overlayState?.sourceText == "unchanged original")
        #expect(fixture.model.overlayState?.translatedText == "unchanged translation")
        #expect(fixture.model.transcriptEntries.first?.sourceText == "unchanged original")
        #expect(fixture.model.transcriptEntries.first?.translatedText == "unchanged translation")
    }

    private func verifyTerminalCleanup(
        action: (AppModel) -> Void
    ) async throws {
        let fixture = makeFixture()
        defer { fixture.removeSettingsFile() }
        let firstSession = LiveTranscriptionSession()
        let secondSession = LiveTranscriptionSession()
        fixture.model.beginCorrectionSessionForTesting()
        fixture.model.registerSuccessfulLiveSessionForTesting(firstSession, source: fixture.microphone)
        fixture.model.registerSuccessfulLiveSessionForTesting(secondSession, source: fixture.application)
        try await waitUntil {
            let firstEnabled = await firstSession.correctionAudioCaptureEnabledForTesting()
            let secondEnabled = await secondSession.correctionAudioCaptureEnabledForTesting()
            return firstEnabled && secondEnabled
        }
        try await fillAudioBuffer(firstSession)
        try await fillAudioBuffer(secondSession)
        let activeGeneration = fixture.model.correction.sessionGeneration

        action(fixture.model)
        try await waitUntil {
            let firstEnabled = await firstSession.correctionAudioCaptureEnabledForTesting()
            let secondEnabled = await secondSession.correctionAudioCaptureEnabledForTesting()
            let firstFrames = await firstSession.correctionAudioFrameCountForTesting()
            let secondFrames = await secondSession.correctionAudioFrameCountForTesting()
            return fixture.model.correction.sessionGeneration > activeGeneration
                && fixture.model.liveTranscriptionSessionCountForTesting == 0
                && !firstEnabled
                && !secondEnabled
                && firstFrames == 0
                && secondFrames == 0
        }
    }
}

@MainActor
private struct CorrectionFixture {
    let settingsURL: URL
    let model: AppModel
    let responder: IntegrationHeldCorrectionResponder
    let microphone: InputSource
    let application: InputSource

    func removeSettingsFile() {
        responder.cancelAll()
        try? FileManager.default.removeItem(at: settingsURL)
    }
}

@MainActor
private final class IntegrationWeakAppModelReference {
    weak var value: AppModel?

    init(_ model: AppModel) {
        value = model
    }
}

@MainActor
private func makeFixture(
    correctionSettings: CorrectionSettings = configuredCorrectionSettings(),
    nativeRealtimeSettings: NativeRealtimeSettings = .default,
    nativeRealtimeSessionCoordinator: NativeRealtimeSessionCoordinator? = nil,
    refreshLanguageCatalogs: Bool = true,
    sourceLanguageOverrides: [String: String] = [:],
    sourceOutputLanguageOverrides: [String: String] = [:]
) -> CorrectionFixture {
    let settingsURL = makeSettingsURL()
    let store = SettingsStore(fileURL: settingsURL)
    var appSettings = makeAppSettings(correction: correctionSettings)
    appSettings.nativeRealtime = nativeRealtimeSettings
    appSettings.sourceLanguageOverrides = sourceLanguageOverrides
    appSettings.sourceOutputLanguageOverrides = sourceOutputLanguageOverrides
    store.save(appSettings)
    let responder = IntegrationHeldCorrectionResponder()
    let correction = RealtimeCorrectionCoordinator(settings: correctionSettings, responder: responder)
    let microphone = microphoneSource
    let application = applicationSource
    let model = AppModel(
        settingsStore: store,
        sourceCatalogService: TestSourceCatalogService(
            applications: [application],
            microphones: [microphone]
        ),
        correction: correction,
        nativeRealtimeSessionCoordinator: nativeRealtimeSessionCoordinator,
        refreshLanguageCatalogs: refreshLanguageCatalogs
    )
    return CorrectionFixture(
        settingsURL: settingsURL,
        model: model,
        responder: responder,
        microphone: microphone,
        application: application
    )
}

private actor IntegrationNativeCredentialBackend: RealtimeCredentialBackend {
    private let secret: String?
    private var lookupCountStorage = 0
    private var shouldSuspendNextLookup = false
    private var lookupContinuation: CheckedContinuation<Void, Never>?

    init(secret: String?) { self.secret = secret }

    func put(reference: String, secret: String) async throws {}
    func get(reference: String) async throws -> String? {
        lookupCountStorage += 1
        if shouldSuspendNextLookup {
            shouldSuspendNextLookup = false
            await withCheckedContinuation { continuation in
                lookupContinuation = continuation
            }
        }
        return secret
    }
    func remove(reference: String) async throws {}
    func lookupCount() -> Int { lookupCountStorage }
    func suspendNextLookup() { shouldSuspendNextLookup = true }
    func isLookupSuspended() -> Bool { lookupContinuation != nil }
    func resumeLookup() {
        let continuation = lookupContinuation
        lookupContinuation = nil
        continuation?.resume()
    }
}

private final class IntegrationNativeDriverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var drivers: [IntegrationNativeRealtimeDriver] = []
    private var microphoneDriver: IntegrationNativeRealtimeDriver?
    private var applicationAudioDriver: IntegrationNativeRealtimeDriver?

    func append(_ driver: IntegrationNativeRealtimeDriver) {
        lock.lock()
        drivers.append(driver)
        lock.unlock()
    }

    func makeDriver(holdingFirstStart: Bool) -> IntegrationNativeRealtimeDriver {
        lock.lock()
        let driver = IntegrationNativeRealtimeDriver(holdStart: holdingFirstStart && drivers.isEmpty)
        drivers.append(driver)
        lock.unlock()
        return driver
    }

    func makeDriver(
        holdingRole: RealtimeAudioSourceRole,
        role: RealtimeAudioSourceRole
    ) -> IntegrationNativeRealtimeDriver {
        lock.lock()
        let driver = IntegrationNativeRealtimeDriver(holdStart: role == holdingRole)
        drivers.append(driver)
        if role == .applicationAudio { applicationAudioDriver = driver } else { microphoneDriver = driver }
        lock.unlock()
        return driver
    }

    func append(_ driver: IntegrationNativeRealtimeDriver, for role: RealtimeAudioSourceRole) {
        lock.lock()
        drivers.append(driver)
        if role == .applicationAudio { applicationAudioDriver = driver } else { microphoneDriver = driver }
        lock.unlock()
    }

    func driver(for role: RealtimeAudioSourceRole) -> IntegrationNativeRealtimeDriver? {
        lock.lock()
        defer { lock.unlock() }
        return role == .applicationAudio ? applicationAudioDriver : microphoneDriver
    }

    func all() -> [IntegrationNativeRealtimeDriver] {
        lock.lock()
        defer { lock.unlock() }
        return drivers
    }
}

private actor IntegrationAsyncSignal {
    private var resolved = false
    func resolve() { resolved = true }
    func isResolved() -> Bool { resolved }
}

private actor IntegrationNativeTranslationHarness {
    private enum ReleasedResult {
        case value(String?)
    }

    private var seenRequests: [(text: String, source: String, target: String)] = []
    private var continuations: [String: [CheckedContinuation<String?, Never>]] = [:]
    private var releasedResults: [String: [ReleasedResult]] = [:]
    private var releaseAllWasCalled = false

    func translate(_ text: String, source: String, target: String) async throws -> String? {
        seenRequests.append((text, source, target))
        if releaseAllWasCalled { return nil }
        if var results = releasedResults[text], !results.isEmpty {
            let result = results.removeFirst()
            releasedResults[text] = results
            if case .value(let value) = result { return value }
        }
        return await withCheckedContinuation { continuations[text, default: []].append($0) }
    }

    func hasRequest(text: String) -> Bool { seenRequests.contains { $0.text == text } }

    func requestCount(text: String) -> Int { seenRequests.filter { $0.text == text }.count }

    func release(text: String, result: String?) {
        guard !releaseAllWasCalled else { return }
        if var pending = continuations[text], !pending.isEmpty {
            let continuation = pending.removeFirst()
            continuations[text] = pending
            continuation.resume(returning: result)
        } else {
            releasedResults[text, default: []].append(.value(result))
        }
    }

    func releaseAll() {
        releaseAllWasCalled = true
        let pending = continuations
        continuations.removeAll()
        for continuations in pending.values {
            for continuation in continuations { continuation.resume(returning: nil) }
        }
    }
}

private final class IntegrationNativeCaptionDispositionBag: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(RealtimeAcceptedCaptionMetadata, RealtimeCaptionSubmissionDisposition)] = []

    func append(_ metadata: RealtimeAcceptedCaptionMetadata, _ disposition: RealtimeCaptionSubmissionDisposition) {
        lock.lock()
        values.append((metadata, disposition))
        lock.unlock()
    }

    func all() -> [(metadata: RealtimeAcceptedCaptionMetadata, disposition: RealtimeCaptionSubmissionDisposition)] {
        lock.lock()
        defer { lock.unlock() }
        return values.map { (metadata: $0.0, disposition: $0.1) }
    }
}

private actor IntegrationNativeRealtimeDriver: RealtimeSessionDriving {
    private let holdStart: Bool
    private var audioChunksStorage: [RealtimeAudioChunk] = []
    private var committedUtterancesStorage: [RealtimeUtterance] = []
    private var startRecordsStorage: [(String, Int)] = []
    private var stopInvocationCountStorage = 0
    private var shouldSuspendNextStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startSuspended = false
    private var startReleased = false
    private var eventContinuation: AsyncStream<RealtimeProviderEvent>.Continuation?
    private var didStop = false

    init(holdStart: Bool = false) { self.holdStart = holdStart }

    func start(sourceAlias: String, generation: Int) async throws {
        startRecordsStorage.append((sourceAlias, generation))
        guard holdStart, startReleased == false else { return }
        startSuspended = true
        await withCheckedContinuation { startContinuation = $0 }
    }
    func isStartSuspended() -> Bool { startSuspended }
    func resumeStart() {
        startReleased = true
        startSuspended = false
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws {
        audioChunksStorage.append(chunk)
    }
    func commit(_ utterance: RealtimeUtterance) async throws {
        committedUtterancesStorage.append(utterance)
    }
    func committedUtteranceCount() -> Int { committedUtterancesStorage.count }
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
    func isListeningForEvents() -> Bool { eventContinuation != nil }
    func emit(_ event: RealtimeProviderEvent) { eventContinuation?.yield(event) }
    func stop() async {
        stopInvocationCountStorage += 1
        didStop = true
        let eventContinuation = self.eventContinuation
        self.eventContinuation = nil
        eventContinuation?.finish()
        guard shouldSuspendNextStop else { return }
        shouldSuspendNextStop = false
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }
    func suspendNextStop() { shouldSuspendNextStop = true }
    func isStopSuspended() -> Bool { stopContinuation != nil }
    func resumeStop() {
        shouldSuspendNextStop = false
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
    func audioChunks() -> [RealtimeAudioChunk] { audioChunksStorage }
    func startedAliases() -> [String] { startRecordsStorage.map(\.0) }
    func startedGenerations() -> [Int] { startRecordsStorage.map(\.1) }
    func stopInvocationCount() -> Int { stopInvocationCountStorage }
}

private struct IntegrationNativeLiveStartFailure: Error {}

private let microphoneSource = InputSource(
    id: "mic-1",
    name: "Desk Mic",
    detail: "Synthetic microphone",
    category: .microphone
)

private let applicationSource = InputSource(
    id: "app-1",
    name: "Conference App",
    detail: "Synthetic application",
    category: .application
)

private let localOnlySource = InputSource(
    id: "local-only-1",
    name: "Local Only App",
    detail: "Synthetic disabled application",
    category: .application
)

private let nativePolicyOnlySource = InputSource(
    id: "native-policy-1",
    name: "Native Policy App",
    detail: "Synthetic native-policy application",
    category: .application
)

private let sampleWAV = Data([
    0x52, 0x49, 0x46, 0x46, 0x26, 0x00, 0x00, 0x00,
    0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20,
    0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x80, 0x3e, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00,
    0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
])

enum CorrectionProviderIdentityField: CaseIterable, Sendable {
    case apiKey
    case baseURL
    case model

    func replace(in settings: inout CorrectionSettings) {
        switch self {
        case .apiKey:
            settings.apiKey = "replacement-placeholder-key"
        case .baseURL:
            settings.baseURL = "https://replacement.example.invalid/v1"
        case .model:
            settings.model = "replacement-model"
        }
    }
}

private func makeSettingsURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("v2s-app-model-correction-\(UUID().uuidString).json")
}

private func configuredCorrectionSettings(
    isEnabled: Bool = true,
    disabledSourceIDs: [String] = [],
    isolatedContextSourceIDs: [String] = []
) -> CorrectionSettings {
    .init(
        isEnabled: isEnabled,
        apiKey: "test-placeholder-key",
        baseURL: "https://example.invalid/v1",
        model: "test-model",
        disabledSourceIDs: disabledSourceIDs,
        isolatedContextSourceIDs: isolatedContextSourceIDs
    )
}

private func configuredNativeRealtimeSettings(
    enabledSourceIDs: [String]
) -> NativeRealtimeSettings {
    var settings = NativeRealtimeSettings.default
    settings.isEnabled = true
    settings.credentialReference = "test-native-key"
    settings.enabledSourceIDs = enabledSourceIDs
    return settings
}

private func integrationRealtimeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
        buffer.floatChannelData?[0][index] = sample
    }
    return buffer
}

private func makeAppSettings(correction: CorrectionSettings) -> AppSettings {
    var settings = AppSettings.default
    settings.selectedSourceID = microphoneSource.id
    settings.selectedSourceIDs = [microphoneSource.id, applicationSource.id]
    settings.correction = correction
    return settings
}

private func fillAudioBuffer(_ session: LiveTranscriptionSession) async throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
    buffer.frameLength = 2
    buffer.floatChannelData?[0][0] = 0.25
    buffer.floatChannelData?[0][1] = -0.25
    await session.appendCorrectionAudioBufferForTesting(buffer)
    #expect(await session.correctionAudioFrameCountForTesting() == 2)
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline {
            throw CorrectionIntegrationWaitTimeout()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForQuiescence(_ duration: Duration = .milliseconds(100)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

actor IntegrationHeldCorrectionResponder: CorrectionResponding {
    struct Call: Sendable {
        let settings: CorrectionSettings
        let prompt: CorrectionPrompt
        let audioWAVData: Data?
        let sourceID: String
        let localTranslation: String
        let contextSourceIDs: [String]
    }

    private var calls: [Call] = []
    nonisolated private let continuationRegistry = HeldCorrectionContinuationRegistry()

    nonisolated func validate(settings: CorrectionSettings) throws {
        guard settings.apiKey.isEmpty == false,
              settings.baseURL.hasPrefix("https://"),
              settings.model.isEmpty == false else {
            throw OpenAIResponsesClient.ClientError.invalidRequest
        }
    }

    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String] {
        [settings.model]
    }

    func testConnection(settings: CorrectionSettings) async throws -> String {
        "OK"
    }

    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput {
        let payload = try Self.payload(from: prompt.userContent)
        guard let current = payload["current"] as? [String: Any],
              let sourceID = current["sourceID"] as? String,
              let localTranslation = current["localTranslation"] as? String,
              let context = payload["context"] as? [[String: Any]] else {
            throw CorrectionIntegrationPromptParsingFailure()
        }
        calls.append(Call(
            settings: settings,
            prompt: prompt,
            audioWAVData: audioWAVData,
            sourceID: sourceID,
            localTranslation: localTranslation,
            contextSourceIDs: try context.map {
                guard let sourceID = $0["sourceID"] as? String else {
                    throw CorrectionIntegrationPromptParsingFailure()
                }
                return sourceID
            }
        ))
        return try await withCheckedThrowingContinuation {
            continuationRegistry.append(sourceID: sourceID, continuation: $0)
        }
    }

    func associateNextCall(with captionID: UUID, sourceID: String? = nil) throws {
        try continuationRegistry.associateNext(with: captionID, sourceID: sourceID)
    }

    @discardableResult
    func release(captionID: UUID, output: CorrectionProviderOutput) -> Bool {
        continuationRegistry.release(captionID: captionID, output: output)
    }

    nonisolated func cancelAll() {
        continuationRegistry.cancelAll()
    }

    func callCount() -> Int { calls.count }
    func startedSourceIDs() -> [String] { calls.map(\.sourceID) }
    func currentLocalTranslations() -> [String] { calls.map(\.localTranslation) }
    func audioPresence() -> [Bool] { calls.map { $0.audioWAVData?.isEmpty == false } }
    func requestModes() -> [CorrectionInputMode] { calls.map(\.prompt.mode) }
    func requestSettings(call index: Int) -> CorrectionSettings { calls[index].settings }
    func contextSourceIDs(call index: Int) -> [String] { calls[index].contextSourceIDs }

    private static func payload(from content: String) throws -> [String: Any] {
        guard let start = content.range(of: "<<<CORRECTION_PAYLOAD_JSON>>>\n")?.upperBound,
              let end = content.range(
                of: "\n<<<END_CORRECTION_PAYLOAD_JSON>>>",
                range: start ..< content.endIndex
              )?.lowerBound,
              let data = String(content[start ..< end]).data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorrectionIntegrationPromptParsingFailure()
        }
        return payload
    }
}

private final class HeldCorrectionContinuationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var unbound: [(sourceID: String, continuation: CheckedContinuation<CorrectionProviderOutput, Error>)] = []
    private var bound: [UUID: CheckedContinuation<CorrectionProviderOutput, Error>] = [:]

    deinit {
        cancelAll()
    }

    func append(sourceID: String, continuation: CheckedContinuation<CorrectionProviderOutput, Error>) {
        lock.lock()
        unbound.append((sourceID: sourceID, continuation: continuation))
        lock.unlock()
    }

    func associateNext(with captionID: UUID, sourceID: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard bound[captionID] == nil,
              let index = unbound.firstIndex(where: { sourceID == nil || $0.sourceID == sourceID }) else {
            throw IntegrationNoHeldCorrectionCall()
        }
        bound[captionID] = unbound.remove(at: index).continuation
    }

    func release(captionID: UUID, output: CorrectionProviderOutput) -> Bool {
        lock.lock()
        var continuation = bound.removeValue(forKey: captionID)
        if continuation == nil, bound.isEmpty, unbound.count == 1 {
            continuation = unbound.removeFirst().continuation
        }
        lock.unlock()
        guard let continuation else {
            return false
        }
        continuation.resume(returning: output)
        return true
    }

    func cancelAll() {
        lock.lock()
        let continuations = unbound.map(\.continuation) + Array(bound.values)
        unbound.removeAll()
        bound.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private func releaseHeldCorrection(
    _ responder: IntegrationHeldCorrectionResponder,
    captionID: UUID,
    output: CorrectionProviderOutput
) async throws {
    try await responder.associateNextCall(with: captionID)
    guard await responder.release(captionID: captionID, output: output) else {
        throw IntegrationUnknownCaptionID()
    }
}

private struct CorrectionIntegrationWaitTimeout: Error {}
private struct CorrectionIntegrationPromptParsingFailure: Error {}
private struct IntegrationUnknownCaptionID: Error {}
private struct IntegrationNoHeldCorrectionCall: Error {}

private actor AsyncTestGate {
    private var isSuspended = false
    private var released = false
    private var suspensionContinuations: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var throwingObserver: CheckedContinuation<Void, any Error>?
    private var observerTimeoutTask: Task<Void, Never>?

    func suspend() async {
        guard !released else { return }
        isSuspended = true
        let observers = observers
        self.observers.removeAll()
        for observer in observers {
            observer.resume()
        }
        observerTimeoutTask?.cancel()
        observerTimeoutTask = nil
        throwingObserver?.resume()
        throwingObserver = nil
        await withCheckedContinuation { continuation in
            suspensionContinuations.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !released else { return }
        guard isSuspended == false else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func waitUntilSuspended(timeoutNanoseconds: UInt64) async throws {
        guard !released else { return }
        guard isSuspended == false else { return }
        try await withCheckedThrowingContinuation { continuation in
            throwingObserver = continuation
            observerTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeoutObserver()
            }
        }
    }

    private func timeoutObserver() {
        guard let continuation = throwingObserver else { return }
        throwingObserver = nil
        observerTimeoutTask = nil
        continuation.resume(throwing: CorrectionIntegrationWaitTimeout())
    }

    func resume() {
        released = true
        isSuspended = false
        let continuations = suspensionContinuations
        suspensionContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
