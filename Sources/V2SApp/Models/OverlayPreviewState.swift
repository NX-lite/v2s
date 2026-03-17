import Foundation

struct OverlayPreviewState: Equatable {
    // MARK: Committed caption (main display)
    var translatedText: String
    var sourceText: String
    var sourceName: String

    // MARK: Draft layer — partial ASR, shown below committed
    var draftSourceText: String? = nil
    var draftStablePrefixLength: Int = 0
    /// Incremental translation of the current draft text (updates as stable prefix grows).
    var draftTranslatedText: String? = nil

    // MARK: Previous caption — scrolls up above committed, then fades
    var previousTranslatedText: String? = nil
    var previousSourceText: String? = nil
    /// 0.0 = fully visible · 1.0 = fully invisible (triggers SwiftUI animation)
    var previousFadeProgress: Double = 1.0

    // MARK: Caption epoch — increments on each new committed sentence (drives slide-in transition)
    var captionEpoch: Int = 0

    // MARK: Derived helpers

    var hasActiveDraftLayer: Bool {
        draftSourceText?.isEmpty == false
    }

    var hasPreviousCaptionLayer: Bool {
        previousTranslatedText != nil
    }
}
