import Combine
import Foundation
import Testing
@testable import v2s

@Suite struct CorrectionSettingsSectionTests {
    @Test @MainActor func correctionBindingPublishesWithoutChangingSourcePolicy() {
        var initial = CorrectionSettings.default
        initial.disabledSourceIDs = ["mic-1"]
        initial.isolatedContextSourceIDs = ["app-1"]
        let coordinator = RealtimeCorrectionCoordinator(settings: initial)
        var publishedSettings = [CorrectionSettings]()
        let observation = coordinator.$settings
            .dropFirst()
            .sink { publishedSettings.append($0) }

        let binding = CorrectionSettingsBindings.binding(for: coordinator, keyPath: \.baseURL)
        binding.wrappedValue = "https://example.invalid/v1"

        #expect(coordinator.settings.baseURL == "https://example.invalid/v1")
        #expect(coordinator.settings.disabledSourceIDs == ["mic-1"])
        #expect(coordinator.settings.isolatedContextSourceIDs == ["app-1"])
        #expect(publishedSettings == [coordinator.settings])
        withExtendedLifetime(observation) {}
    }

    @Test @MainActor func sourcePolicyBindingsAreIndependent() {
        let fixture = makeTwoSourceModel()
        defer { try? FileManager.default.removeItem(at: fixture.settingsURL) }
        let model = fixture.model
        model.correction.settings.isEnabled = true

        model.setCorrectionEnabled(false, for: model.selectedSources[0])
        model.setCorrectionContextIsolated(true, for: model.selectedSources[1])

        #expect(!model.isCorrectionEnabled(for: model.selectedSources[0]))
        #expect(model.isCorrectionEnabled(for: model.selectedSources[1]))
        #expect(!model.isCorrectionContextIsolated(for: model.selectedSources[0]))
        #expect(model.isCorrectionContextIsolated(for: model.selectedSources[1]))
    }

    @Test @MainActor func globalDisableMakesEverySourcePolicyEffectivelyDisabledWithoutDiscardingSelections() {
        let fixture = makeTwoSourceModel()
        defer { try? FileManager.default.removeItem(at: fixture.settingsURL) }
        let model = fixture.model
        let source = model.selectedSources[0]
        model.correction.settings.isEnabled = true
        model.setCorrectionContextIsolated(true, for: source)

        model.correction.settings.isEnabled = false

        #expect(!model.isCorrectionEnabled(for: source))
        #expect(model.isCorrectionContextIsolated(for: source))
        #expect(model.correction.settings.isolatedContextSourceIDs == [source.id])
    }
}

@MainActor
private func makeTwoSourceModel() -> (model: AppModel, settingsURL: URL) {
    let microphone = InputSource(
        id: "mic-1",
        name: "Desk Mic",
        detail: "Synthetic microphone",
        category: .microphone
    )
    let application = InputSource(
        id: "app-1",
        name: "Conference App",
        detail: "Synthetic application",
        category: .application
    )
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("v2s-correction-settings-section-\(UUID().uuidString).json")
    var settings = AppSettings.default
    settings.selectedSourceID = microphone.id
    settings.selectedSourceIDs = [microphone.id, application.id]
    SettingsStore(fileURL: settingsURL).save(settings)

    let model = AppModel(
        settingsStore: SettingsStore(fileURL: settingsURL),
        sourceCatalogService: TestSourceCatalogService(
            applications: [application],
            microphones: [microphone]
        ),
        correction: RealtimeCorrectionCoordinator(settings: settings.correction)
    )
    return (model, settingsURL)
}
