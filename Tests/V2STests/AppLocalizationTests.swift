import Testing
@testable import v2s

@Suite struct AppLocalizationTests {
    @Test func englishMultipleSourcesUsesSingularAndPluralForms() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "en") == "1 Source")
        #expect(AppLocalization.multipleSourcesText(count: 3, languageID: "en") == "3 Sources")
    }

    @Test func russianMultipleSourcesUsesProperPluralCategories() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "ru") == "1 источник")
        #expect(AppLocalization.multipleSourcesText(count: 2, languageID: "ru") == "2 источника")
        #expect(AppLocalization.multipleSourcesText(count: 5, languageID: "ru") == "5 источников")
        #expect(AppLocalization.multipleSourcesText(count: 11, languageID: "ru") == "11 источников")
        #expect(AppLocalization.multipleSourcesText(count: 21, languageID: "ru") == "21 источник")
    }

    @Test func arabicMultipleSourcesUsesDistinctPluralForms() {
        #expect(AppLocalization.multipleSourcesText(count: 1, languageID: "ar") == "مصدر واحد")
        #expect(AppLocalization.multipleSourcesText(count: 2, languageID: "ar") == "مصدران")
        #expect(AppLocalization.multipleSourcesText(count: 4, languageID: "ar") == "4 مصادر")
        #expect(AppLocalization.multipleSourcesText(count: 12, languageID: "ar") == "12 مصدرًا")
    }
}
