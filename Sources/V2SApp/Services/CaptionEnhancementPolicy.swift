import Foundation

enum CaptionEnhancementMode: Equatable, Sendable {
    case localOnly
    case sentenceCorrection
    case nativeRealtime
}

enum CaptionEnhancementPolicy {
    static func mode(
        for sourceID: String,
        correction: CorrectionSettings,
        nativeRealtime: NativeRealtimeSettings
    ) -> CaptionEnhancementMode {
        if nativeRealtime.isEnabled(for: sourceID) { return .nativeRealtime }
        if correction.isEnabled(for: sourceID) { return .sentenceCorrection }
        return .localOnly
    }
}
