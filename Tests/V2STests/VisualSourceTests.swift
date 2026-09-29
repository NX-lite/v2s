import Testing
@testable import v2s

@Suite struct VisualSourceTests {
    @Test func selectionStartsEmptyAndRejectsASelectionBeyondFour() {
        let catalog = (1...5).map { index in
            VisualSource(
                id: .display(UInt32(index)),
                name: "Display \(index)"
            )
        }
        var selection = VisualSourceSelection()

        #expect(selection.selectedSources.isEmpty)
        for source in catalog.prefix(4) {
            #expect(selection.select(source, from: catalog) == .selected)
        }
        #expect(selection.selectedSources.count == 4)
        #expect(selection.select(catalog[4], from: catalog) == .limitReached)
        #expect(selection.selectedSources.map(\.id) == catalog.prefix(4).map(\.id))
    }

    @Test func catalogExcludesV2SApplicationAndWindowSources() {
        let ownApplication = VisualSource(
            id: .application(processIdentifier: 121, bundleIdentifier: "com.franklioxygen.v2s"),
            name: "v2s",
            ownerBundleIdentifier: "com.franklioxygen.v2s",
            ownerProcessIdentifier: 121
        )
        let ownWindow = VisualSource(
            id: .window(windowIdentifier: 44, processIdentifier: 120),
            name: "Settings",
            ownerBundleIdentifier: "com.example.helper",
            ownerProcessIdentifier: 120
        )
        let otherWindow = VisualSource(
            id: .window(windowIdentifier: 45, processIdentifier: 300),
            name: "Document",
            ownerBundleIdentifier: "com.example.editor",
            ownerProcessIdentifier: 300
        )

        let visibleSources = VisualSourceCatalog.filteringV2S(
            [ownApplication, ownWindow, otherWindow],
            bundleIdentifier: "com.franklioxygen.v2s",
            processIdentifier: 120
        )

        #expect(visibleSources == [otherWindow])
    }

    @Test func disappearedWindowResolvesAsUnavailableWithoutDisplayFallback() {
        let selectedWindow = VisualSource(
            id: .window(windowIdentifier: 91, processIdentifier: 300),
            name: "Editor",
            ownerBundleIdentifier: "com.example.editor",
            ownerProcessIdentifier: 300
        )
        let remainingDisplay = VisualSource(
            id: .display(1),
            name: "Display 1"
        )
        var selection = VisualSourceSelection()
        #expect(selection.select(selectedWindow, from: [selectedWindow, remainingDisplay]) == .selected)

        let resolution = selection.resolutions(in: [remainingDisplay])

        #expect(resolution == [.unavailable(selectedWindow.id)])
    }
}
