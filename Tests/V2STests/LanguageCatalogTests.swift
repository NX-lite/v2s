import Foundation
import Testing
@testable import v2s

@Suite struct LanguageCatalogTests {
    // A language keeps a single locale, and the winner used to be whichever identifier
    // sorted first — which can be a variant with no on-device model.
    @Test func optionsKeepPreferredLocaleForALanguage() {
        let locales = [Locale(identifier: "fr-BE"), Locale(identifier: "fr-FR")]

        let unprioritized = LanguageCatalog.options(for: locales)
        #expect(unprioritized.first(where: { $0.id == "fr" })?.localeIdentifier == "fr-BE")

        let prioritized = LanguageCatalog.options(for: locales, preferring: ["fr-FR"])
        #expect(prioritized.first(where: { $0.id == "fr" })?.localeIdentifier == "fr-FR")
    }

    @Test func optionsIgnorePreferenceForOtherLanguages() {
        let options = LanguageCatalog.options(
            for: [Locale(identifier: "fr-BE"), Locale(identifier: "fr-FR"), Locale(identifier: "it-CH")],
            preferring: ["fr-FR"]
        )

        #expect(options.first(where: { $0.id == "it" })?.localeIdentifier == "it-CH")
        #expect(options.filter { $0.id == "fr" }.count == 1)
    }

    @Test func speechInputLanguagesUseSpeechAnalyzerSupportedDefaults() {
        let expectedLocaleIdentifiers: [String: String] = [
            "en": "en-US",
            "zh-Hans": "zh-CN",
            "zh-Hant": "zh-TW",
            "yue": "yue-CN",
            "es": "es-ES",
            "de": "de-DE",
            "ja": "ja-JP",
            "fr": "fr-FR",
            "it": "it-IT",
            "ko": "ko-KR",
            "pt": "pt-BR",
            "ar": "ar-SA",
            "ca": "ca-ES",
            "cs": "cs-CZ",
            "da": "da-DK",
            "fi": "fi-FI",
            "el": "el-GR",
            "he": "he-IL",
            "hi": "hi-IN",
            "hr": "hr-HR",
            "hu": "hu-HU",
            "id": "id-ID",
            "ms": "ms-MY",
            "nb": "nb-NO",
            "nl": "nl-NL",
            "pl": "pl-PL",
            "ro": "ro-RO",
            "ru": "ru-RU",
            "sk": "sk-SK",
            "sv": "sv-SE",
            "th": "th-TH",
            "tr": "tr-TR",
            "uk": "uk-UA",
            "vi": "vi-VN",
        ]

        #expect(Set(LanguageCatalog.speechInput.map(\.id)) == Set(expectedLocaleIdentifiers.keys))

        for option in LanguageCatalog.speechInput {
            #expect(LanguageCatalog.speechLocaleIdentifier(for: option.id) == expectedLocaleIdentifiers[option.id])
        }
    }

    @Test func translationCatalogIncludesAdditionalDestinationLanguages() {
        let expectedLanguageIDs = [
            "en", "zh-Hans", "zh-Hant", "es", "de", "ja", "fr", "ko", "ar", "pt", "ru",
            "it", "nl", "id", "th", "tr", "pl", "uk", "vi", "hi", "da", "nb", "sv",
        ]

        #expect(Set(LanguageCatalog.common.map(\.id)) == Set(expectedLanguageIDs))
    }

    @Test func translationLocaleIdentifiersUseStableRegionalDefaults() {
        #expect(LanguageCatalog.translationLocaleIdentifier(for: "zh-Hans") == "zh-CN")
        #expect(LanguageCatalog.translationLocaleIdentifier(for: "zh-Hant") == "zh-TW")
        #expect(LanguageCatalog.translationLocaleIdentifier(for: "nb") == "nb-NO")
        #expect(LanguageCatalog.translationLocaleIdentifier(for: "en") == "en-US")
    }

    @Test func runtimeLocaleOptionsCollapseRegionsAndPreserveChineseScripts() {
        let options = LanguageCatalog.options(for: [
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
            Locale(identifier: "zh-CN"),
            Locale(identifier: "zh-TW"),
            Locale(identifier: "sr-Cyrl-RS"),
            Locale(identifier: "sr-Latn-RS"),
            Locale(identifier: "fa-IR"),
        ])

        #expect(options.filter { $0.id == "en" }.count == 1)
        #expect(options.first(where: { $0.id == "en" })?.localeIdentifier != nil)
        #expect(options.contains(where: { $0.id == "zh-Hans" }))
        #expect(options.contains(where: { $0.id == "zh-Hant" }))
        #expect(options.contains(where: { $0.id == "sr-Latn" }))
        #expect(options.contains(where: { $0.id == "fa" }))
    }

    @Test func runtimeTranslationOptionsRetainFrameworkLocaleIdentifier() throws {
        let options = LanguageCatalog.options(for: [
            Locale.Language(identifier: "pt-BR"),
            Locale.Language(identifier: "zh-TW"),
        ])

        let portugueseIdentifier = try #require(
            options.first(where: { $0.id == "pt" })?.localeIdentifier
        )
        let traditionalChineseIdentifier = try #require(
            options.first(where: { $0.id == "zh-Hant" })?.localeIdentifier
        )
        #expect(
            Locale.Language(identifier: portugueseIdentifier)
                .isEquivalent(to: Locale.Language(identifier: "pt-BR"))
        )
        #expect(
            Locale.Language(identifier: traditionalChineseIdentifier)
                .isEquivalent(to: Locale.Language(identifier: "zh-TW"))
        )
    }

    @Test func unsupportedStoredSpeechInputFallsBackToEnglish() {
        #expect(LanguageCatalog.supportedSpeechInputLanguageID(for: "xx") == "en")
        #expect(LanguageCatalog.supportedSpeechInputLanguageID(for: "it") == "it")
    }
}
