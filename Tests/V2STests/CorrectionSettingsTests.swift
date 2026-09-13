import Foundation
import Testing
@testable import v2s

@Suite struct CorrectionSettingsTests {
    @Test func defaultsArePrivateAndIndependentFromAssistant() {
        let value = CorrectionSettings.default
        #expect(value.isEnabled == false)
        #expect(value.apiKey == "")
        #expect(value.baseURL == "https://api.openai.com/v1")
        #expect(value.model == "gpt-4o")
        #expect(value.disabledSourceIDs == [])
        #expect(value.isolatedContextSourceIDs == [])
    }

    @Test func malformedFieldFallsBackWithoutDiscardingValidFields() throws {
        let data = Data(#"{"isEnabled":true,"apiKey":"kept","baseURL":9,"model":"audio-model","disabledSourceIDs":["mic-1"]}"#.utf8)
        let value = try JSONDecoder().decode(CorrectionSettings.self, from: data)
        #expect(value.isEnabled)
        #expect(value.apiKey == "kept")
        #expect(value.baseURL == CorrectionSettings.default.baseURL)
        #expect(value.model == "audio-model")
        #expect(value.disabledSourceIDs == ["mic-1"])
    }

    @Test func sourceIDAssignmentsAreUniqueAndSorted() {
        var value = CorrectionSettings.default
        value.disabledSourceIDs = ["mic-2", "app-1", "mic-2"]
        value.isolatedContextSourceIDs = ["mic-2", "app-1", "mic-2"]

        #expect(value.disabledSourceIDs == ["app-1", "mic-2"])
        #expect(value.isolatedContextSourceIDs == ["app-1", "mic-2"])
    }

    @Test func sourceIDInitializationIsUniqueAndSorted() {
        let value = CorrectionSettings(
            isEnabled: true,
            apiKey: "key",
            baseURL: "https://example.invalid/v1",
            model: "model",
            disabledSourceIDs: ["z", "a", "z"],
            isolatedContextSourceIDs: ["b", "a", "b"]
        )

        #expect(value.disabledSourceIDs == ["a", "z"])
        #expect(value.isolatedContextSourceIDs == ["a", "b"])
    }

    @Test func sourceEnablementRespectsGlobalAndPerSourceSettings() {
        var value = CorrectionSettings.default
        value.isEnabled = true
        value.disabledSourceIDs = ["mic-1"]

        #expect(!value.isEnabled(for: "mic-1"))
        #expect(value.isEnabled(for: "app-1"))

        value.isEnabled = false
        #expect(!value.isEnabled(for: "app-1"))
    }

    @Test func isolatedContextSettingsApplyPerSource() {
        var value = CorrectionSettings.default
        value.isolatedContextSourceIDs = ["mic-1"]

        #expect(value.usesIsolatedContext(for: "mic-1"))
        #expect(!value.usesIsolatedContext(for: "app-1"))
    }
}
