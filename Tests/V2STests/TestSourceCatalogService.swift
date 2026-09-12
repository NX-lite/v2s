@testable import v2s

@MainActor
struct TestSourceCatalogService: SourceCatalogLoading {
    let snapshot: SourceCatalogSnapshot

    init(
        applications: [InputSource] = [],
        microphones: [InputSource] = []
    ) {
        snapshot = SourceCatalogSnapshot(
            applications: applications,
            microphones: microphones
        )
    }

    func loadSnapshot() -> SourceCatalogSnapshot {
        snapshot
    }
}
