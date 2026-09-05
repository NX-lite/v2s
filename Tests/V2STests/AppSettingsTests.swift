import Foundation
import Testing
@testable import v2s

@Suite struct AppSettingsTests {
    @Test func legacySingleSourceSettingsDecodeIntoMultiSourceFields() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "subtitleColor": { "kind": "defaultSubtitle" },
            "textColor": { "kind": "defaultText" },
            "backgroundColor": { "kind": "defaultBackground" },
            "showsTextOutline": true,
            "textOutlineColor": { "kind": "defaultTextOutline" },
            "attachToSource": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.selectedSourceID == "mic-1")
        #expect(settings.selectedSourceIDs == ["mic-1"])
        #expect(settings.sourceLanguageOverrides.isEmpty)
        #expect(settings.sourceOutputLanguageOverrides.isEmpty)
    }

    @Test func multiSourceSettingsRoundTripPreservesOverrides() throws {
        let settings = AppSettings(
            selectedSourceID: "mic-1",
            selectedSourceIDs: ["mic-1", "app-1"],
            sourceLanguageOverrides: ["app-1": "fr"],
            sourceOutputLanguageOverrides: ["mic-1": "zh-Hans", "app-1": "de"],
            inputLanguageID: "en",
            outputLanguageID: "ja",
            interfaceLanguageID: "en",
            overlayStyle: .default,
            subtitleMode: .balanced,
            subtitleDisplayMode: .both,
            glossary: ["CEO": "Chief Executive Officer"]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.selectedSourceID == "mic-1")
        #expect(decoded.selectedSourceIDs == ["mic-1", "app-1"])
        #expect(decoded.sourceLanguageOverrides == ["app-1": "fr"])
        #expect(decoded.sourceOutputLanguageOverrides == ["mic-1": "zh-Hans", "app-1": "de"])
        #expect(decoded.inputLanguageID == "en")
        #expect(decoded.outputLanguageID == "ja")
        #expect(decoded.interfaceLanguageID == "en")
        #expect(decoded.glossary == ["CEO": "Chief Executive Officer"])
    }

    @Test func invisibleInRecordingDefaultsToOffForSettingsSavedBeforeTheToggleExisted() throws {
        let json = """
        {
          "selectedSourceID": "mic-1",
          "inputLanguageID": "en",
          "outputLanguageID": "ja",
          "overlayStyle": {
            "translatedFontSize": 20,
            "sourceFontSize": 16,
            "backgroundOpacity": 0.7,
            "topInset": 12,
            "widthRatio": 0.82,
            "minWidth": 720,
            "maxWidth": 1440,
            "clickThrough": true,
            "translatedFirst": true
          },
          "subtitleMode": "balanced",
          "subtitleDisplayMode": "both",
          "glossary": {}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(!settings.overlayStyle.invisibleInRecording)
    }

    @Test func invisibleInRecordingSurvivesAnEncodeDecodeRoundTrip() throws {
        var style = OverlayStyle.default
        style.invisibleInRecording = true

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(OverlayStyle.self, from: data)

        #expect(decoded.invisibleInRecording)
    }

    @Test func forkFlatAssistantSettingsMigrateWithoutLosingPrivacy() throws {
        let json = """
        {
          "inputLanguageID":"en","outputLanguageID":"zh-Hans",
          "overlayStyle":{},"subtitleMode":"balanced",
          "subtitleDisplayMode":"both","glossary":{},
          "privacyModeEnabled":true,
          "gptAPIKey":"secret-placeholder","gptAPIBaseURL":"https://example.invalid/v1",
          "gptModel":"model-a","gptSkills":"Answer briefly",
          "autoDetectConversationLanguages":false,
          "hotKeyFollowUp":{"key":"f","useCommand":true,"useOption":true,"useControl":false,"useShift":false},
          "hotKeyAsk":{"key":"g","useCommand":true,"useOption":true,"useControl":false,"useShift":false},
          "hotKeySwitchMode":{"key":"t","useCommand":true,"useOption":true,"useControl":false,"useShift":false}
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.assistant.apiKey == "secret-placeholder")
        #expect(settings.assistant.baseURL == "https://example.invalid/v1")
        #expect(settings.assistant.model == "model-a")
        #expect(settings.assistant.skills == "Answer briefly")
        #expect(!settings.assistant.autoDetectConversationLanguages)
        #expect(settings.assistant.followUpHotKey == .defaultFollowUp)
        #expect(settings.overlayStyle.invisibleInRecording)
    }

    @Test func malformedLegacyFieldDoesNotDiscardOtherAssistantFields() throws {
        let json = """
        {"gptAPIKey":"kept","gptModel":42,"gptSkills":"kept-skill"}
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.assistant.apiKey == "kept")
        #expect(settings.assistant.model == AssistantSettings.default.model)
        #expect(settings.assistant.skills == "kept-skill")
    }

    @Test func invalidNestedAssistantDoesNotFallBackToLegacySettings() throws {
        for invalidAssistant in ["42", "null"] {
            let json = """
            {"assistant":\(invalidAssistant),"gptAPIKey":"legacy-placeholder"}
            """

            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

            #expect(settings.assistant == .default)
        }
    }

    @Test func newEncodingContainsNestedAssistantAndNoLegacySecretsKey() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["assistant"] != nil)
        #expect(object["gptAPIKey"] == nil)
        #expect(object["privacyModeEnabled"] == nil)
    }
}
