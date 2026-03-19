import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private var suppressNextPreparationAutoShow = false

    init(model: AppModel) {
        let window = NSWindow()
        let hostingController = NSHostingController(
            rootView: SettingsView(model: model, closeSettings: {})
        )
        window.contentViewController = hostingController
        window.title = "v2s Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        super.init(window: window)
        hostingController.rootView = SettingsView(
            model: model,
            closeSettings: { [weak self] in
                self?.closeForSessionStart()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        suppressNextPreparationAutoShow = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeForSessionStart() {
        suppressNextPreparationAutoShow = true
        window?.performClose(nil)
    }

    func showSettingsForPreparationIfAllowed() {
        if suppressNextPreparationAutoShow {
            suppressNextPreparationAutoShow = false
            return
        }

        showSettings()
    }
}
