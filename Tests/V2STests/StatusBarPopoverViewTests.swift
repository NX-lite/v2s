import Foundation
import Testing
@testable import v2s

@Suite @MainActor struct StatusBarPopoverViewTests {
    @Test func assistantActionDispatchesThroughModelAndClosesForAnEmptyTranscript() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-status-popover-assistant-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService(),
            assistant: AssistantCoordinator()
        )
        var closeCount = 0

        AssistantPopoverActions.dispatch(
            .ask,
            model: model,
            closePopover: { closeCount += 1 }
        )

        #expect(model.hasTranscript == false)
        #expect(model.assistant.replies.count == 1)
        #expect(model.assistant.replies[0].action == .ask)
        #expect(closeCount == 1)
    }
}
