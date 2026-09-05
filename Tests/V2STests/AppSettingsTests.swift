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
}
