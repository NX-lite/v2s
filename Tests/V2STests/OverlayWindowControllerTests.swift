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
            sourceCatalogService: SourceCatalogService()
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
            sourceCatalogService: SourceCatalogService(),
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

    @Test func assistantAndSubtitleScrollRoutesKeepTheirOffsetsIndependent() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-scroll-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let assistant = AssistantCoordinator()
        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
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
}
