import Testing
@testable import v2s

@Suite struct AssistantSettingsSectionTests {
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
