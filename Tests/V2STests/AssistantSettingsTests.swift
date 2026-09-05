import Foundation
import Testing
@testable import v2s

@Suite struct AssistantSettingsTests {
    @Test func defaultHotKeyBindingsAreDistinctAndValid() {
        let bindings = [
            HotKeyBinding.defaultFollowUp,
            .defaultAsk,
            .defaultSwitchMode,
        ]

        #expect(Set(bindings).count == 3)
        #expect(HotKeyBinding.defaultFollowUp.isValid)
        #expect(HotKeyBinding.defaultAsk.isValid)
        #expect(HotKeyBinding.defaultSwitchMode.isValid)
    }

    @Test func hotKeyBindingNormalizesKeyCase() {
        let binding = HotKeyBinding(
            key: "F",
            useCommand: true,
            useOption: false,
            useControl: false,
            useShift: false
        )

        #expect(binding.normalizedKey == "f")
        #expect(binding.isValid)
    }

    @Test func hotKeyBindingRequiresModifierAndAllowedKey() {
        let noModifier = HotKeyBinding(
            key: "f",
            useCommand: false,
            useOption: false,
            useControl: false,
            useShift: false
        )
        let invalidKey = HotKeyBinding(
            key: "!",
            useCommand: true,
            useOption: false,
            useControl: false,
            useShift: false
        )

        #expect(!noModifier.isValid)
        #expect(!invalidKey.isValid)
    }

    @Test func hotKeyBindingDisplaysModifiersInConventionOrder() {
        let binding = HotKeyBinding(
            key: "f",
            useCommand: true,
            useOption: true,
            useControl: true,
            useShift: true
        )

        #expect(binding.displayString == "⌃⌥⇧⌘F")
    }

    @Test func malformedAssistantFieldFallsBackWithoutDiscardingOtherFields() throws {
        let json = """
        {
          "apiKey": "kept",
          "baseURL": 42,
          "skills": "kept-skill",
          "autoDetectConversationLanguages": false
        }
        """

        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))

        #expect(settings.apiKey == "kept")
        #expect(settings.baseURL == AssistantSettings.default.baseURL)
        #expect(settings.skills == "kept-skill")
        #expect(!settings.autoDetectConversationLanguages)
    }
}
