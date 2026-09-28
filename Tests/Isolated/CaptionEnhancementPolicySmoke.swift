import Foundation

@main struct CaptionEnhancementPolicySmoke {
    static func main() {
        var correction = CorrectionSettings.default
        correction.isEnabled = true
        var native = NativeRealtimeSettings.default
        native.isEnabled = true
        native.enabledSourceIDs = ["mic-1"]

        precondition(CaptionEnhancementPolicy.mode(
            for: "mic-1", correction: correction, nativeRealtime: native
        ) == .nativeRealtime)
        precondition(CaptionEnhancementPolicy.mode(
            for: "app-1", correction: correction, nativeRealtime: native
        ) == .sentenceCorrection)
        precondition(CaptionEnhancementPolicy.mode(
            for: "none", correction: .default, nativeRealtime: .default
        ) == .localOnly)
    }
}
