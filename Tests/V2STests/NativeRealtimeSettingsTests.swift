import Foundation
import Testing
@testable import v2s

@Suite struct NativeRealtimeSettingsTests {
    @Test func defaultsNeverStartOrSelectMedia() {
        let value = NativeRealtimeSettings.default
        #expect(!value.isEnabled)
        #expect(value.enabledSourceIDs.isEmpty)
        #expect(value.profile == .openAIMini)
        #expect(value.credentialReference == nil)
        #expect(value.qwenWorkspaceID == nil)
    }

    @Test func modelAllowlistAndVideoCapabilityStayExplicit() {
        #expect(NativeRealtimeProfile.openAIMini.modelID == "gpt-realtime-2.1-mini")
        #expect(NativeRealtimeProfile.qwenOmniFlash.supportsVideo)
        #expect(NativeRealtimeProfile.geminiLive.supportsVideo)
        #expect(!NativeRealtimeProfile.openAI.modelID.isEmpty)
        #expect(!NativeRealtimeProfile.xAIVoice.supportsVideo)
    }

    @Test func sourceOptInIsUniqueAndExplicit() {
        var value = NativeRealtimeSettings.default
        value.isEnabled = true
        value.enabledSourceIDs = ["mic-2", "mic-1", "mic-2"]
        #expect(value.enabledSourceIDs == ["mic-1", "mic-2"])
        #expect(value.isEnabled(for: "mic-1"))
        #expect(!value.isEnabled(for: "app-1"))
    }
}
