import AppKit
import Testing
@testable import v2s

@Suite @MainActor struct OverlayWindowControllerTests {
    @Test func recordingVisibilityUsesNewPublishedStyleValue() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-window-controller-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService()
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        #expect(controller.panelSharingTypesForTesting.count == 9)
        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })

        model.updateOverlayStyle { $0.invisibleInRecording = true }

        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .none })

        model.updateOverlayStyle { $0.invisibleInRecording = false }

        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })
    }

    @Test func replyModeAcceptsInputWhileSubtitleModeKeepsClickThrough() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-input-mode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let assistant = AssistantCoordinator()
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: assistant
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        #expect(controller.overlayContentAcceptsInputForTesting == false)

        // Invalid configuration produces a semantic reply synchronously, without
        // touching capture or a provider. It is enough to exercise the reply UI mode.
        model.requestAssistant(.ask)

        #expect(assistant.overlayMode == .assistantReplies)
        #expect(assistant.replies.isEmpty == false)
        #expect(controller.overlayContentAcceptsInputForTesting == true)

        assistant.overlayMode = .subtitles

        #expect(controller.overlayContentAcceptsInputForTesting == false)
    }

    @Test func invalidAssistantReplyShowsWithoutCreatingSubtitleState() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-reply-only-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: AssistantCoordinator()
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        #expect(controller.shouldShowContentForTesting == false)

        // Invalid configuration produces the synchronous reply path. It must show
        // the assistant content without manufacturing an empty subtitle payload.
        model.requestAssistant(.ask)

        #expect(model.isOverlayVisible)
        #expect(model.overlayState == nil)
        #expect(model.assistant.replies.isEmpty == false)
        #expect(controller.shouldShowContentForTesting)
        #expect(controller.overlayContentAcceptsInputForTesting)

        await drainMainQueue()
        #expect(controller.panelsShownForTesting)

        // Re-publishing the already-visible flag exercises the willSet snapshot
        // path with an absent subtitle state. Reply content is still displayable,
        // so it must not be mistaken for a hide transition.
        model.isOverlayVisible = true
        #expect(controller.hasPendingHideSnapshotForTesting == false)
    }

    @Test func startingWithoutAnInputHidesAResetReplyOnlyOverlay() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-reply-reset-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: AssistantCoordinator()
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        model.requestAssistant(.ask)
        #expect(controller.shouldShowContentForTesting)

        await model.startSession()
        await drainMainQueue()

        #expect(model.assistant.replies.isEmpty)
        #expect(model.isOverlayVisible == false)
        #expect(model.overlayState == nil)
        #expect(controller.shouldShowContentForTesting == false)
        #expect(controller.panelsShownForTesting == false)

        // A regular subtitle preview can still re-show the panels after the
        // reply-only session is reset.
        model.showOverlayPreview()
        await drainMainQueue()

        #expect(model.overlayState != nil)
        #expect(controller.shouldShowContentForTesting)
        #expect(controller.panelsShownForTesting)
    }

    @Test func switchingReplyOnlyModeToSubtitlesResetsVisibilityAndCanReopen() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-mode-switch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let assistant = AssistantCoordinator()
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: assistant
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        model.requestAssistant(.ask)
        await drainMainQueue()
        #expect(model.overlayState == nil)
        #expect(model.isOverlayVisible)
        #expect(controller.panelsShownForTesting)

        assistant.overlayMode = .subtitles
        await drainMainQueue()

        #expect(model.overlayState == nil)
        #expect(model.isOverlayVisible == false)
        #expect(controller.shouldShowContentForTesting == false)
        #expect(controller.panelsShownForTesting == false)

        // This is the status-bar button route: after a reply-only overlay is
        // hidden by the mode switch, one click must show a subtitle preview.
        OverlayPopoverActions.toggle(model: model)
        await drainMainQueue()

        #expect(model.overlayState != nil)
        #expect(model.isOverlayVisible)
        #expect(controller.panelsShownForTesting)

        // Switching back to assistant replies restores the retained reply-only
        // presentation after a regular user hide.
        model.toggleOverlayVisibility()
        await drainMainQueue()
        #expect(model.isOverlayVisible == false)
        #expect(controller.panelsShownForTesting == false)

        assistant.overlayMode = .assistantReplies
        await drainMainQueue()

        #expect(model.overlayState == nil)
        #expect(model.isOverlayVisible)
        #expect(controller.panelsShownForTesting)
    }

    @Test func reShowingContentInvalidatesAnObsoleteReplyHideSnapshot() async {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-stale-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let assistant = AssistantCoordinator()
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: assistant
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        model.requestAssistant(.ask)
        await drainMainQueue()
        #expect(controller.panelsShownForTesting)

        // resetForNewSession emits a non-displayable reply state and captures the
        // currently rendered reply for a pending hide.
        assistant.resetForNewSession()
        #expect(controller.hasPendingHideSnapshotForTesting)

        // A subtitle preview arrives in the same main-thread turn before the
        // queued sync. The old reply snapshot must be discarded, not reused by
        // the next hide animation.
        model.showOverlayPreview()
        await drainMainQueue()

        #expect(controller.shouldShowContentForTesting)
        #expect(controller.panelsShownForTesting)
        #expect(controller.hasPendingHideSnapshotForTesting == false)

        model.toggleOverlayVisibility()
        #expect(controller.hasPendingHideSnapshotForTesting)
    }

    @Test func assistantAndSubtitleScrollRoutesKeepTheirOffsetsIndependent() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-scroll-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let assistant = AssistantCoordinator()
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: TestSourceCatalogService(),
            assistant: assistant
        )

        model.requestAssistant(.ask)
        model.requestAssistant(.followUp)
        assistant.updateReplyVisibleCount(1)
        assistant.setReplyScrollOffset(1)

        #expect(OverlayHistoryScrollRouting.target(for: assistant) == .assistantReplies)
        #expect(model.overlayHistoryScrollOffset == 0)

        OverlayHistoryScrollRouting.scroll(by: -1, model: model)

        #expect(assistant.replyScrollOffset == 0)
        #expect(model.overlayHistoryScrollOffset == 0)

        assistant.setReplyScrollOffset(1)
        assistant.overlayMode = .subtitles

        #expect(OverlayHistoryScrollRouting.target(for: assistant) == .subtitles)

        OverlayHistoryScrollRouting.scroll(by: -1, model: model)

        #expect(model.overlayHistoryScrollOffset == 0)
        #expect(assistant.replyScrollOffset == 1)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
