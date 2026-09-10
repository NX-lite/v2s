import Foundation
import Testing
@testable import v2s

@MainActor
@Suite struct AppModelAssistantIntegrationTests {
    @Test func snapshotCopiesTranscriptEntriesInTheirStoredOrder() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: AssistantCoordinator(settings: configuredAssistantSettings())
        )
        let first = TranscriptEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceText: "First source",
            translatedText: "First translation",
            timestamp: Date(timeIntervalSince1970: 200)
        )
        let second = TranscriptEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sourceText: "Second source",
            translatedText: "Second translation",
            timestamp: Date(timeIntervalSince1970: 100)
        )

        model.replaceTranscriptEntriesForTesting([first, second])

        let snapshot = model.assistantTranscriptSnapshot()

        #expect(snapshot.sourceName == model.selectedSourceDisplayName)
        #expect(snapshot.inputLanguageID == model.inputLanguageID)
        #expect(snapshot.inputLanguageName == model.languageName(for: model.inputLanguageID))
        #expect(snapshot.outputLanguageID == model.outputLanguageID)
        #expect(snapshot.outputLanguageName == model.languageName(for: model.outputLanguageID))
        #expect(snapshot.entries == [
            .init(timestamp: first.timestamp, sourceText: "First source", translatedText: "First translation"),
            .init(timestamp: second.timestamp, sourceText: "Second source", translatedText: "Second translation"),
        ])
    }

    @Test func transcriptUpsertPreservesTheOriginalTimestampForAnExistingIdentifier() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: AssistantCoordinator(settings: configuredAssistantSettings())
        )
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let originalTimestamp = Date(timeIntervalSince1970: 42)
        model.replaceTranscriptEntriesForTesting([
            .init(id: identifier, sourceText: "Original", translatedText: "初始", timestamp: originalTimestamp),
        ])

        model.upsertTranscriptEntryForTesting(
            id: identifier,
            sourceText: "Updated source",
            translatedText: "更新翻译"
        )

        let newIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        model.upsertTranscriptEntryForTesting(
            id: newIdentifier,
            sourceText: "New source",
            translatedText: "新翻译"
        )

        #expect(model.transcriptEntries[0].timestamp == originalTimestamp)
        #expect(model.transcriptEntries[0].sourceText == "Updated source")
        #expect(model.transcriptEntries[0].translatedText == "更新翻译")
        #expect(model.transcriptEntries[1].id == newIdentifier)
        #expect(model.transcriptEntries[1].timestamp != originalTimestamp)
    }

    @Test func changingAssistantSettingsPersistsAlongsideExistingAppSettings() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let originalAssistant = configuredAssistantSettings()
        let store = SettingsStore(fileURL: settingsURL)
        store.save(makeAppSettings(assistant: originalAssistant))
        let coordinator = AssistantCoordinator(settings: originalAssistant)
        let model = AppModel(
            settingsStore: store,
            sourceCatalogService: SourceCatalogService(),
            assistant: coordinator
        )
        model.selectedSourceID = "source:primary"
        model.selectedSourceIDs = ["source:primary", "source:secondary"]
        model.sourceLanguageOverrides = ["source:primary": "fr"]
        model.sourceOutputLanguageOverrides = ["source:secondary": "de"]

        var updatedAssistant = originalAssistant
        updatedAssistant.model = "example-model-v2"
        updatedAssistant.skills = "Use a concise interview style."
        updatedAssistant.autoDetectConversationLanguages = false
        model.assistant.settings = updatedAssistant

        let reloaded = store.load()

        #expect(reloaded.assistant == updatedAssistant)
        #expect(reloaded.selectedSourceID == model.selectedSourceID)
        #expect(reloaded.selectedSourceIDs == ["source:primary", "source:secondary"])
        #expect(reloaded.sourceLanguageOverrides == ["source:primary": "fr"])
        #expect(reloaded.sourceOutputLanguageOverrides == ["source:secondary": "de"])
        #expect(reloaded.inputLanguageID == "fr")
        #expect(reloaded.outputLanguageID == "de")
        #expect(reloaded.interfaceLanguageID == "zh-Hans")
        #expect(reloaded.overlayStyle == configuredOverlayStyle())
        #expect(reloaded.subtitleMode == .reading)
        #expect(reloaded.subtitleDisplayMode == .translatedOnly)
        #expect(reloaded.glossary == ["ETA": "预计到达时间"])
    }

    @Test func defaultCoordinatorLoadsTheNestedAssistantSettingsWithoutOverwritingThem() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        var persistedAssistant = configuredAssistantSettings()
        persistedAssistant.model = "persisted-example-model"
        persistedAssistant.skills = "Keep the original context."
        let store = SettingsStore(fileURL: settingsURL)
        store.save(makeAppSettings(assistant: persistedAssistant))

        let model = AppModel(
            settingsStore: store,
            sourceCatalogService: SourceCatalogService()
        )

        #expect(model.assistant.settings == persistedAssistant)
        #expect(store.load().assistant == persistedAssistant)
    }

    @Test func assistantActionRouteUsesTheCurrentEmptyTranscriptSnapshot() async {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let responder = HeldResponder()
        let assistant = AssistantCoordinator(
            settings: configuredAssistantSettings(),
            responder: responder,
            screenContextProvider: ReadyScreenContextProvider(),
            promptBuilder: StaticPromptBuilder()
        )
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: assistant
        )

        model.requestAssistant(.followUp)
        await waitForCall(on: responder)

        #expect(model.hasTranscript == false)
        #expect(model.assistant.requestState == .running(.followUp))
        #expect(model.assistant.replies.map(\.action) == [.followUp])

        await responder.release(text: "Empty-context follow up")
        await drainTasks()
    }

    @Test func firstAssistantReplyShowsAHiddenOverlayOnlyAfterScreenCaptureCompletes() async {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let responder = HeldResponder()
        let screen = GatedScreenContextProvider()
        let assistant = AssistantCoordinator(
            settings: configuredAssistantSettings(),
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: StaticPromptBuilder()
        )
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: assistant
        )

        #expect(model.isOverlayVisible == false)
        #expect(model.overlayState == nil)

        model.requestAssistant(.ask)
        await waitForCapture(on: screen)

        #expect(model.isOverlayVisible == false)
        #expect(model.overlayState == nil)
        #expect(model.assistant.replies.isEmpty)

        await screen.release()
        await waitForCall(on: responder)

        #expect(model.assistant.replies.map(\.content) == [.thinking])
        #expect(model.assistant.overlayMode == .assistantReplies)
        #expect(model.isOverlayVisible)
        #expect(model.overlayState == nil)

        await responder.release(text: "Answer after capture")
        await drainTasks()
    }

    @Test func invalidAssistantRequestShowsAHiddenOverlaySynchronously() {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: AssistantCoordinator()
        )

        model.requestAssistant(.ask)

        #expect(model.assistant.replies == [
            .init(id: model.assistant.replies[0].id, action: .ask, content: .failure(.invalidConfiguration)),
        ])
        #expect(model.assistant.overlayMode == .assistantReplies)
        #expect(model.isOverlayVisible)
        #expect(model.overlayState == nil)
    }

    @Test func startingANewSessionResetsAssistantRepliesAndDiscardsLateResponse() async {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let responder = HeldResponder()
        let assistant = AssistantCoordinator(
            settings: configuredAssistantSettings(),
            responder: responder,
            screenContextProvider: WarningScreenContextProvider(),
            promptBuilder: StaticPromptBuilder()
        )
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: assistant
        )

        model.requestAssistant(.ask)
        await waitForCall(on: responder, expected: 1)
        await responder.release(text: "First reply")
        await drainTasks()

        model.requestAssistant(.followUp)
        await waitForCall(on: responder, expected: 2)
        await responder.release(text: "Second reply")
        await drainTasks()

        assistant.updateReplyVisibleCount(1)
        assistant.setReplyScrollOffset(1)

        #expect(assistant.replies.count == 2)
        #expect(assistant.replyScrollOffset == 1)
        #expect(assistant.overlayMode == .assistantReplies)
        #expect(assistant.screenStatus == .permissionNeeded)

        model.requestAssistant(.ask)
        await waitForCall(on: responder, expected: 3)

        await model.startSession()

        #expect(assistant.replies.isEmpty)
        #expect(assistant.requestState == .idle)
        #expect(assistant.screenStatus == .unknown)
        #expect(assistant.replyScrollOffset == 0)
        #expect(assistant.replyVisibleCount == 0)
        #expect(assistant.overlayMode == .subtitles)
        #expect(model.isOverlayVisible == false)
        #expect(model.overlayState == nil)

        await responder.release(text: "Late reply from the old session")
        await drainTasks()

        #expect(assistant.replies.isEmpty)
        #expect(assistant.requestState == .idle)
        #expect(assistant.overlayMode == .subtitles)
    }

    @Test func stopSessionCancelsAnInFlightAssistantRequestAndIgnoresItsLateResponse() async {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let responder = HeldResponder()
        let assistant = AssistantCoordinator(
            settings: configuredAssistantSettings(),
            responder: responder,
            screenContextProvider: ReadyScreenContextProvider(),
            promptBuilder: StaticPromptBuilder()
        )
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: assistant
        )

        model.assistant.request(.ask, snapshot: model.assistantTranscriptSnapshot())
        await waitForCall(on: responder)
        #expect(model.assistant.requestState == .running(.ask))

        model.stopSession()
        #expect(model.assistant.requestState == .idle)
        #expect(model.assistant.replies.isEmpty)

        await responder.release(text: "Late response")
        await drainTasks()

        #expect(model.assistant.requestState == .idle)
        #expect(model.assistant.replies.isEmpty)
    }

    @Test func applicationTerminationCancelsAnInFlightAssistantRequest() async {
        let settingsURL = makeSettingsURL()
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let responder = HeldResponder()
        let assistant = AssistantCoordinator(
            settings: configuredAssistantSettings(),
            responder: responder,
            screenContextProvider: ReadyScreenContextProvider(),
            promptBuilder: StaticPromptBuilder()
        )
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: assistant
        )

        model.assistant.request(.followUp, snapshot: model.assistantTranscriptSnapshot())
        await waitForCall(on: responder)

        let delegate = AppDelegate(appModel: model)
        delegate.applicationWillTerminate(Notification(name: .init("test.termination")))
        #expect(model.assistant.requestState == .idle)
        #expect(model.assistant.replies.isEmpty)

        await responder.release(text: "Late termination response")
        await drainTasks()

        #expect(model.assistant.requestState == .idle)
        #expect(model.assistant.replies.isEmpty)
    }

    private func makeSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-app-model-assistant-\(UUID().uuidString).json")
    }

    private func configuredAssistantSettings() -> AssistantSettings {
        AssistantSettings(
            apiKey: "example.invalid-placeholder-key",
            baseURL: "https://example.invalid/v1",
            model: "example-model",
            skills: "Ask focused follow-up questions.",
            autoDetectConversationLanguages: true,
            followUpHotKey: .defaultFollowUp,
            askHotKey: .defaultAsk,
            switchModeHotKey: .defaultSwitchMode
        )
    }

    private func makeAppSettings(assistant: AssistantSettings) -> AppSettings {
        AppSettings(
            selectedSourceID: nil,
            selectedSourceIDs: [],
            sourceLanguageOverrides: [:],
            sourceOutputLanguageOverrides: [:],
            inputLanguageID: "fr",
            outputLanguageID: "de",
            interfaceLanguageID: "zh-Hans",
            overlayStyle: configuredOverlayStyle(),
            subtitleMode: .reading,
            subtitleDisplayMode: .translatedOnly,
            glossary: ["ETA": "预计到达时间"],
            assistant: assistant
        )
    }

    private func configuredOverlayStyle() -> OverlayStyle {
        var style = OverlayStyle.default
        style.backgroundOpacity = 0.63
        style.invisibleInRecording = true
        return style
    }

    private func waitForCall(on responder: HeldResponder, expected: Int = 1) async {
        for _ in 0..<200 {
            if await responder.callCount() == expected {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the held assistant request")
    }

    private func waitForCapture(on screen: GatedScreenContextProvider) async {
        for _ in 0..<200 {
            if await screen.hasStarted() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for screen capture")
    }

    private func drainTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private struct ReadyScreenContextProvider: AssistantScreenContextProviding {
    func current() async -> ScreenContext {
        ScreenContext(pngData: nil, ocrText: nil, status: .ready)
    }
}

private struct WarningScreenContextProvider: AssistantScreenContextProviding {
    func current() async -> ScreenContext {
        ScreenContext(pngData: nil, ocrText: nil, status: .permissionNeeded)
    }
}

private actor GatedScreenContextProvider: AssistantScreenContextProviding {
    private var started = false
    private var continuation: CheckedContinuation<ScreenContext, Never>?

    func current() async -> ScreenContext {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        continuation?.resume(returning: .init(pngData: nil, ocrText: nil, status: .ready))
        continuation = nil
    }
}

private struct StaticPromptBuilder: AssistantPromptBuilding {
    func build(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        currentTime: Date,
        hasScreenshot: Bool,
        ocrText: String?
    ) async throws -> AssistantPrompt {
        AssistantPrompt(instructions: "Test instructions", userContent: "Test prompt")
    }
}

private actor HeldResponder: AssistantResponding {
    private var continuations: [CheckedContinuation<OpenAIResponsesClient.Response, Error>] = []
    private var calls = 0

    nonisolated func validateRequestConfiguration(settings: AssistantSettings) throws {
        guard settings.apiKey.isEmpty == false,
              settings.baseURL.hasPrefix("https://"),
              settings.model.isEmpty == false else {
            throw OpenAIResponsesClient.ClientError.invalidRequest
        }
    }

    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String] {
        [settings.model]
    }

    func testConnection(settings: AssistantSettings) async throws -> String {
        "OK"
    }

    func respond(
        settings: AssistantSettings,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> OpenAIResponsesClient.Response {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release(text: String) {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume(returning: .init(text: text, imageWasSent: false))
    }

    func callCount() -> Int {
        calls
    }
}
