import Foundation
import Testing
@testable import v2s

@Suite struct OverlayPreviewStateTests {
    @Test func draftTranslationIsOnlyReturnedForMatchingDraft() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.draftSourceText = "Change type is not at all."
        state.draftPromotionID = firstPromotionID
        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )

        #expect(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: firstPromotionID
            ) == "Old translation"
        )
        #expect(
            state.currentDraftTranslatedText(
                for: "Okay.",
                promotionID: secondPromotionID
            ) == nil
        )
    }

    @Test func mismatchedDraftTranslationIsCleared() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Okay.",
            promotionID: secondPromotionID
        )

        #expect(state.draftTranslatedText == nil)
        #expect(state.draftTranslationSourceText == nil)
        #expect(state.draftTranslationPromotionID == nil)
    }

    @Test func samePromotionDraftTranslationStaysVisibleDuringSourceUpdate() {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: promotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Change type is not at all.",
            promotionID: promotionID
        )

        #expect(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ) == "Old translation"
        )
        #expect(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ) == nil
        )
    }

    @Test func nilPromotionDraftTranslationStillRequiresExactSourceMatch() {
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: nil
        )

        #expect(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: nil
            ) == nil
        )
    }
}
