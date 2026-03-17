import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let model: AppModel
    private let panel: OverlayPanel
    private let containerView: OverlayContainerView
    private var cancellables = Set<AnyCancellable>()
    /// Top-left corner (minX, maxY) of the panel after a user drag. nil = use auto-position.
    private var userDefinedTopLeft: NSPoint?

    init(model: AppModel) {
        self.model = model
        self.panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.containerView = OverlayContainerView(rootView: OverlayView(model: model))

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
        // Always false — partial click-through is handled by OverlayContainerView.hitTest
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = containerView
        containerView.isClickThrough = model.overlayStyle.clickThrough

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    @objc private func handleWindowMove(_ notification: Notification) {
        // Record top-left so resizes anchor to the same top edge
        userDefinedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    private func bindModel() {
        model.$isOverlayVisible
            .sink { [weak self] _ in self?.scheduleWindowSync() }
            .store(in: &cancellables)

        model.$overlayState
            .sink { [weak self] _ in self?.scheduleWindowSync() }
            .store(in: &cancellables)

        model.$overlayStyle
            .sink { [weak self] style in
                self?.containerView.isClickThrough = style.clickThrough
                self?.scheduleWindowSync()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleWindowSync() }
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
        guard let screen = currentScreen() else { return }

        let visibleFrame = screen.visibleFrame
        let style = model.overlayStyle
        let width = min(max(visibleFrame.width * style.widthRatio, style.minWidth), style.maxWidth)
        let height = panelHeight()

        let originX: Double
        let originY: Double

        if let topLeft = userDefinedTopLeft {
            // Keep the top edge anchored where the user dragged it
            originX = topLeft.x
            originY = topLeft.y - height
        } else {
            originX = visibleFrame.midX - (width / 2)
            originY = visibleFrame.maxY - style.topInset - height
        }

        panel.setFrame(
            NSRect(x: originX, y: originY, width: width, height: height),
            display: true
        )
    }

    private func panelHeight() -> Double {
        let style = model.overlayStyle
        let state = model.overlayState

        // Base: committed layer (translated + source + internal spacing)
        let base = style.scaledTranslatedFontSize + style.scaledSourceFontSize + 48.0

        // Previous caption layer adds height for ~1 second while fading
        let previousExtra: Double = state?.hasPreviousCaptionLayer == true
            ? style.scaledTranslatedFontSize * 0.82 + style.scaledSourceFontSize * 0.82 + 20.0
            : 0.0

        // Draft layer adds one source-size line
        let draftExtra: Double = state?.hasActiveDraftLayer == true
            ? style.scaledSourceFontSize + 12.0
            : 0.0

        return min(max(base + previousExtra + draftExtra, 88.0), 280.0)
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

// MARK: - Container view with per-region click-through

/// Wraps the SwiftUI hosting view and routes hit-testing so the left control
/// strip (first ~56 pts) is always interactive while the subtitle content area
/// can pass mouse events to underlying windows when clickThrough is enabled.
final class OverlayContainerView: NSView {
    var isClickThrough = true

    /// Width of the left-side control strip that must always receive mouse events.
    private static let controlStripMaxX: CGFloat = 56

    private let hostingView: NSHostingView<OverlayView>

    init(rootView: OverlayView) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Left control strip — always interactive
        if point.x <= OverlayContainerView.controlStripMaxX {
            return super.hitTest(point)
        }
        // Subtitle content area — pass through when click-through is enabled
        return isClickThrough ? nil : super.hitTest(point)
    }
}

// MARK: - Panel

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
