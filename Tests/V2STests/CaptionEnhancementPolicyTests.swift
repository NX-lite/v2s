import Testing
@testable import v2s

@Suite struct CaptionEnhancementPolicyTests {
    @Test func nativeRealtimeWinsOnlyForExplicitSource() {
        var correction = CorrectionSettings.default
        correction.isEnabled = true
        var native = NativeRealtimeSettings.default
        native.isEnabled = true
        native.enabledSourceIDs = ["mic-1"]

        #expect(CaptionEnhancementPolicy.mode(
            for: "mic-1", correction: correction, nativeRealtime: native
        ) == .nativeRealtime)
        #expect(CaptionEnhancementPolicy.mode(
            for: "app-1", correction: correction, nativeRealtime: native
        ) == .sentenceCorrection)
    }

    @Test func migrationKeepsLegacyChoice() {
        var correction = CorrectionSettings.default
        correction.isEnabled = true
        #expect(CaptionEnhancementPolicy.mode(
            for: "mic-1", correction: correction, nativeRealtime: .default
        ) == .sentenceCorrection)
    }

    @Test func disabledPathsRemainLocalOnly() {
        #expect(CaptionEnhancementPolicy.mode(
            for: "mic-1", correction: .default, nativeRealtime: .default
        ) == .localOnly)
    }
}
