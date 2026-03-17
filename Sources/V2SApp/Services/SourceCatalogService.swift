import AppKit
import AVFoundation
import Foundation

struct SourceCatalogSnapshot {
    let applications: [InputSource]
    let microphones: [InputSource]
}

@MainActor
final class SourceCatalogService {
    func loadSnapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(
            applications: loadApplications(),
            microphones: loadMicrophones()
        )
    }

    private func loadApplications() -> [InputSource] {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && app.localizedName?.isEmpty == false
                    && app.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .map { app in
                InputSource(
                    id: "app:\(app.bundleIdentifier ?? "pid-\(app.processIdentifier)")",
                    name: app.localizedName ?? "Unknown App",
                    detail: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
                    category: .application
                )
            }

        return deduplicated(runningApps)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadMicrophones() -> [InputSource] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let devices = discoverySession.devices.map { device in
            InputSource(
                id: "mic:\(device.uniqueID)",
                name: device.localizedName,
                detail: device.uniqueID,
                category: .microphone
            )
        }

        return deduplicated(devices)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func deduplicated(_ sources: [InputSource]) -> [InputSource] {
        var seen = Set<String>()

        return sources.filter { source in
            seen.insert(source.id).inserted
        }
    }
}
