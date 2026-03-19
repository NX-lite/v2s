import AppKit

@MainActor
final class DockVisibilityController {
    enum Reason: Hashable {
        case settingsWindow
    }

    private var reasons = Set<Reason>()

    func setVisible(_ visible: Bool, for reason: Reason) {
        if visible {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }

        if reasons.isEmpty == false {
            NSApp.applicationIconImage = resolvedDockIcon()
        }

        NSApp.setActivationPolicy(reasons.isEmpty ? .accessory : .regular)
    }

    private func resolvedDockIcon() -> NSImage {
        if let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let fileName = (iconFile as NSString).deletingPathExtension
            let fileExtension = (iconFile as NSString).pathExtension.isEmpty
                ? "icns"
                : (iconFile as NSString).pathExtension

            if let iconURL = Bundle.main.url(forResource: fileName, withExtension: fileExtension),
               let iconImage = NSImage(contentsOf: iconURL) {
                return iconImage
            }
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            return iconImage
        }

        #if SWIFT_PACKAGE
        if let iconURL = Bundle.module.url(forResource: "AppIcon-512", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            return iconImage
        }
        #endif

        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }
}
