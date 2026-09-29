import Darwin
import Foundation
import ScreenCaptureKit

enum VisualSourceCatalogError: Error, Equatable, Sendable {
    case unavailable
}

@MainActor
protocol VisualSourceCatalogLoading {
    func loadSnapshot() async -> Result<[VisualSource], VisualSourceCatalogError>
}

/// Enumerates local ScreenCaptureKit choices without retaining them outside the active session.
@MainActor
final class VisualSourceCatalog: VisualSourceCatalogLoading {
    func loadSnapshot() async -> Result<[VisualSource], VisualSourceCatalogError> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            let ownProcessIdentifier = getpid()

            let displays = content.displays
                .sorted { $0.displayID < $1.displayID }
                .enumerated()
                .map { index, display in
                    VisualSource(id: .display(display.displayID), name: "Display \(index + 1)")
                }

            let applications = content.applications.map { application in
                VisualSource(
                    id: .application(
                        processIdentifier: application.processID,
                        bundleIdentifier: application.bundleIdentifier
                    ),
                    name: application.applicationName,
                    ownerBundleIdentifier: application.bundleIdentifier,
                    ownerProcessIdentifier: application.processID
                )
            }

            let windows = content.windows.compactMap { window -> VisualSource? in
                guard let application = window.owningApplication else { return nil }
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? application.applicationName
                return VisualSource(
                    id: .window(
                        windowIdentifier: window.windowID,
                        processIdentifier: application.processID
                    ),
                    name: name,
                    ownerBundleIdentifier: application.bundleIdentifier,
                    ownerProcessIdentifier: application.processID
                )
            }

            return .success(Self.filteringV2S(
                displays + applications + windows,
                bundleIdentifier: ownBundleIdentifier,
                processIdentifier: ownProcessIdentifier
            ))
        } catch {
            return .failure(.unavailable)
        }
    }

    /// Pure filtering rule shared by application and window entries and covered without screen access.
    nonisolated static func filteringV2S(
        _ sources: [VisualSource],
        bundleIdentifier: String?,
        processIdentifier: Int32
    ) -> [VisualSource] {
        sources.filter { source in
            let belongsToCurrentProcess = source.ownerProcessIdentifier == processIdentifier
            let belongsToCurrentApp = bundleIdentifier.map {
                source.ownerBundleIdentifier == $0
            } ?? false
            return !belongsToCurrentProcess && !belongsToCurrentApp
        }
    }
}
