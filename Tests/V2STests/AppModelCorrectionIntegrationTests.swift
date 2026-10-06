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

        let microphoneCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.microphone,
            original: "mic local",
            translation: "mic translation",
            audioWAVData: sampleWAV
        )
        let applicationCaptionID = fixture.model.commitLocalCaptionForTesting(
            source: fixture.application,
            original: "app local",
            translation: "app translation",
            audioWAVData: sampleWAV
        )
        try await waitUntil { await fixture.responder.callCount() == 2 }
        try await fixture.responder.associateNextCall(with: microphoneCaptionID)
        try await fixture.responder.associateNextCall(with: applicationCaptionID)

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
private func makeFixture(
    correctionSettings: CorrectionSettings = configuredCorrectionSettings(),
    nativeRealtimeSettings: NativeRealtimeSettings = .default,
    nativeRealtimeSessionCoordinator: NativeRealtimeSessionCoordinator? = nil
) -> CorrectionFixture {
    let settingsURL = makeSettingsURL()
    let store = SettingsStore(fileURL: settingsURL)
    var appSettings = makeAppSettings(correction: correctionSettings)
    appSettings.nativeRealtime = nativeRealtimeSettings
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
        nativeRealtimeSessionCoordinator: nativeRealtimeSessionCoordinator
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

    func append(_ driver: IntegrationNativeRealtimeDriver) {
        lock.lock()
        drivers.append(driver)
        lock.unlock()
    }

    func all() -> [IntegrationNativeRealtimeDriver] {
        lock.lock()
        defer { lock.unlock() }
        return drivers
    }
}

private actor IntegrationNativeRealtimeDriver: RealtimeSessionDriving {
    private var audioChunksStorage: [RealtimeAudioChunk] = []
    private var startRecordsStorage: [(String, Int)] = []
    private var stopInvocationCountStorage = 0
    private var shouldSuspendNextStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var eventContinuation: AsyncStream<RealtimeProviderEvent>.Continuation?
    private var didStop = false

    func start(sourceAlias: String, generation: Int) async throws {
        startRecordsStorage.append((sourceAlias, generation))
    }
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws {
        audioChunksStorage.append(chunk)
    }
    func commit(_ utterance: RealtimeUtterance) async throws {}
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
        return try await withCheckedThrowingContinuation { continuationRegistry.append($0) }
    }

    func associateNextCall(with captionID: UUID) throws {
        try continuationRegistry.associateNext(with: captionID)
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
    private var unbound: [CheckedContinuation<CorrectionProviderOutput, Error>] = []
    private var bound: [UUID: CheckedContinuation<CorrectionProviderOutput, Error>] = [:]

    deinit {
        cancelAll()
    }

    func append(_ continuation: CheckedContinuation<CorrectionProviderOutput, Error>) {
        lock.lock()
        unbound.append(continuation)
        lock.unlock()
    }

    func associateNext(with captionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard bound[captionID] == nil, unbound.isEmpty == false else {
            throw IntegrationNoHeldCorrectionCall()
        }
        bound[captionID] = unbound.removeFirst()
    }

    func release(captionID: UUID, output: CorrectionProviderOutput) -> Bool {
        lock.lock()
        var continuation = bound.removeValue(forKey: captionID)
        if continuation == nil, bound.isEmpty, unbound.count == 1 {
            continuation = unbound.removeFirst()
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
        let continuations = unbound + Array(bound.values)
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
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let observers = observers
        self.observers.removeAll()
        for observer in observers {
            observer.resume()
        }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard isSuspended == false else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}
