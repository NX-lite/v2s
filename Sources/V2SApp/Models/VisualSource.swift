import Foundation

/// A source choice exists only for the current capture session. Its native ID is local state.
struct VisualSource: Equatable, Hashable, Identifiable, Sendable {
    enum Kind: Sendable {
        case display
        case application
        case window
    }

    enum ID: Hashable, Sendable {
        case display(UInt32)
        case application(processIdentifier: Int32, bundleIdentifier: String?)
        case window(windowIdentifier: UInt32, processIdentifier: Int32)
    }

    let id: ID
    let name: String
    let ownerBundleIdentifier: String?
    let ownerProcessIdentifier: Int32?

    init(
        id: ID,
        name: String,
        ownerBundleIdentifier: String? = nil,
        ownerProcessIdentifier: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.ownerBundleIdentifier = ownerBundleIdentifier
        self.ownerProcessIdentifier = ownerProcessIdentifier
    }

    var kind: Kind {
        switch id {
        case .display:
            .display
        case .application:
            .application
        case .window:
            .window
        }
    }
}

enum VisualSourceSelectionChange: Equatable, Sendable {
    case selected
    case alreadySelected
    case sourceUnavailable
    case limitReached
}

enum VisualSourceResolution: Equatable, Sendable {
    case available(VisualSource)
    case unavailable(VisualSource.ID)
}

/// Session-only ordered selection. It starts empty and never substitutes another source.
struct VisualSourceSelection: Equatable, Sendable {
    static let maximumSelectionCount = 4

    private(set) var selectedSources: [VisualSource] = []

    init() {}

    @discardableResult
    mutating func select(_ source: VisualSource, from catalog: [VisualSource]) -> VisualSourceSelectionChange {
        guard let currentSource = catalog.first(where: { $0.id == source.id }) else {
            return .sourceUnavailable
        }
        guard !selectedSources.contains(where: { $0.id == currentSource.id }) else {
            return .alreadySelected
        }
        guard selectedSources.count < Self.maximumSelectionCount else {
            return .limitReached
        }

        selectedSources.append(currentSource)
        return .selected
    }

    mutating func remove(_ sourceID: VisualSource.ID) {
        selectedSources.removeAll { $0.id == sourceID }
    }

    mutating func clear() {
        selectedSources.removeAll(keepingCapacity: false)
    }

    func resolutions(in catalog: [VisualSource]) -> [VisualSourceResolution] {
        selectedSources.map { selectedSource in
            guard let currentSource = catalog.first(where: { $0.id == selectedSource.id }) else {
                return .unavailable(selectedSource.id)
            }
            return .available(currentSource)
        }
    }
}
