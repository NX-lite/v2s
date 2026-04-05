import AppKit

@MainActor
final class PopoverOutsideClickMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var shouldIgnoreClick: ((NSPoint) -> Bool)?
    private var onOutsideClick: (() -> Void)?

    func start(
        shouldIgnoreClick: @escaping (NSPoint) -> Bool,
        onOutsideClick: @escaping () -> Void
    ) {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        self.shouldIgnoreClick = shouldIgnoreClick
        self.onOutsideClick = onOutsideClick

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.handle(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        shouldIgnoreClick = nil
        onOutsideClick = nil
    }

    private func handle(_ event: NSEvent) {
        guard let shouldIgnoreClick, shouldIgnoreClick(screenPoint(for: event)) == false else {
            return
        }

        onOutsideClick?()
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window = event.window else {
            return NSEvent.mouseLocation
        }

        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
