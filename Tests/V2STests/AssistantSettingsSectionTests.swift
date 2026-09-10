import Combine
import Testing
@testable import v2s

@Suite struct AssistantSettingsSectionTests {
    @Test @MainActor func bindingWritesCoordinatorSettingsAndPublishesTheNewValue() {
        var initial = AssistantSettings.default
        initial.apiKey = "existing-key"
        initial.followUpHotKey = HotKeyBinding(
            key: "q",
            useCommand: true,
            useOption: false,
            useControl: false,
            useShift: false
        )
        let coordinator = AssistantCoordinator(settings: initial)
        var publishedSettings = [AssistantSettings]()
        let observation = coordinator.$settings
            .dropFirst()
            .sink { publishedSettings.append($0) }

        let binding = AssistantSettingsBindings.binding(
            for: coordinator,
            keyPath: \.baseURL
        )
        binding.wrappedValue = "https://example.invalid/v1"

        #expect(coordinator.settings.baseURL == "https://example.invalid/v1")
        #expect(coordinator.settings.apiKey == "existing-key")
        #expect(coordinator.settings.followUpHotKey == initial.followUpHotKey)
        #expect(publishedSettings == [coordinator.settings])
        withExtendedLifetime(observation) {}
    }

    @Test func formUpdatesCopySettingsWithoutDiscardingOtherFields() {
        var original = AssistantSettings.default
        original.apiKey = "existing-key"
        original.followUpHotKey = HotKeyBinding(
            key: "q",
            useCommand: true,
            useOption: false,
            useControl: false,
            useShift: false
        )

        let updated = AssistantSettingsForm.updating(original) { settings in
            settings.baseURL = "https://example.invalid/v1"
            settings.autoDetectConversationLanguages = false
        }

        #expect(updated.apiKey == "existing-key")
        #expect(updated.followUpHotKey == original.followUpHotKey)
        #expect(updated.baseURL == "https://example.invalid/v1")
        #expect(updated.autoDetectConversationLanguages == false)
    }
}
