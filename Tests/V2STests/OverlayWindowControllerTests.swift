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

        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })

        model.updateOverlayStyle { $0.invisibleInRecording = true }

        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .none })

        model.updateOverlayStyle { $0.invisibleInRecording = false }

        #expect(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })
    }
}
