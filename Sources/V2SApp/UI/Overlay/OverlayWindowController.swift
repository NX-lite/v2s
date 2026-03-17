import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let model: AppModel
    private let panel: OverlayPanel
    private let hostingController: NSHostingController<OverlayView>
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.hostingController = NSHostingController(rootView: OverlayView(model: model))

        configurePanel()
        bindModel()
        syncWindow()
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.tabbingMode = .disallowed
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = model.overlayStyle.clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentViewController = hostingController
    }

    private func bindModel() {
        model.$isOverlayVisible
            .sink { [weak self] _ in
                self?.scheduleWindowSync()
            }
            .store(in: &cancellables)

        model.$overlayState
            .sink { [weak self] _ in
                self?.scheduleWindowSync()
            }
            .store(in: &cancellables)

        model.$overlayStyle
            .sink { [weak self] style in
                self?.panel.ignoresMouseEvents = style.clickThrough
                self?.scheduleWindowSync()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.scheduleWindowSync()
            }
            .store(in: &cancellables)
    }

    private func scheduleWindowSync() {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindow()
        }
    }

    private func syncWindow() {
        guard model.isOverlayVisible, model.overlayState != nil else {
            panel.orderOut(nil)
            return
        }

        positionPanel()
        panel.orderFront(nil)
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = currentScreen() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let width = min(max(visibleFrame.width * model.overlayStyle.widthRatio, model.overlayStyle.minWidth), model.overlayStyle.maxWidth)
        let height = min(max(model.overlayStyle.translatedFontSize + model.overlayStyle.sourceFontSize + 56, 88), 180)
        let originX = visibleFrame.midX - (width / 2)
        let originY = visibleFrame.maxY - model.overlayStyle.topInset - height

        panel.setFrame(
            NSRect(x: originX, y: originY, width: width, height: height),
            display: true
        )
    }

    private func currentScreen() -> NSScreen? {
        if let targetDisplayID = model.overlayStyle.targetDisplayID,
           let matchedScreen = NSScreen.screens.first(where: { $0.displayIDString == targetDisplayID }) {
            return matchedScreen
        }

        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    var displayIDString: String? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return screenNumber.stringValue
    }
}
