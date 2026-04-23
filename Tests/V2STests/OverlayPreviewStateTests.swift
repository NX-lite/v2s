import Foundation
import XCTest
@testable import v2s

final class OverlayPreviewStateTests: XCTestCase {
    func testDraftTranslationIsOnlyReturnedForMatchingDraft() {
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

        XCTAssertEqual(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: firstPromotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Okay.",
                promotionID: secondPromotionID
            )
        )
    }

    func testMismatchedDraftTranslationIsCleared() {
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

        XCTAssertNil(state.draftTranslatedText)
        XCTAssertNil(state.draftTranslationSourceText)
        XCTAssertNil(state.draftTranslationPromotionID)
    }

    func testSamePromotionDraftTranslationStaysVisibleDuringSourceUpdate() {
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

        XCTAssertEqual(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            )
        )
    }

    func testNilPromotionDraftTranslationStillRequiresExactSourceMatch() {
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

        XCTAssertNil(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: nil
            )
        )
    }
}
