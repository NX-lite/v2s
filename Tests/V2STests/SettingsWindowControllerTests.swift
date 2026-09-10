import AppKit
import Testing
@testable import v2s

@Suite @MainActor struct SettingsWindowControllerTests {
    @Test func recordingVisibilityUsesThePublishedValueForBothSettingsWindows() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-settings-window-privacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = SettingsWindowController(
            model: model,
            updaterService: UpdaterService(),
            launchAtLoginService: LaunchAtLoginService(),
            dockVisibilityController: DockVisibilityController(),
            showTranscript: {},
            quitApp: {}
        )
        controller.showSubtitleModeInfoForTesting()

        #expect(controller.windowSharingTypesForTesting == [.readOnly, .readOnly])

        model.updateOverlayStyle { $0.invisibleInRecording = true }

        #expect(controller.windowSharingTypesForTesting == [.none, .none])

        model.updateOverlayStyle { $0.invisibleInRecording = false }

        #expect(controller.windowSharingTypesForTesting == [.readOnly, .readOnly])
    }
}
