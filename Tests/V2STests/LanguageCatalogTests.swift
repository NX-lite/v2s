import XCTest
@testable import v2s

final class LanguageCatalogTests: XCTestCase {
    func testSpeechInputLanguagesUseSpeechAnalyzerSupportedDefaults() {
        let expectedLocaleIdentifiers: [String: String] = [
            "en": "en-US",
            "zh-Hans": "zh-CN",
            "yue": "yue-CN",
            "es": "es-ES",
            "de": "de-DE",
            "ja": "ja-JP",
            "fr": "fr-FR",
            "it": "it-IT",
            "ko": "ko-KR",
            "pt": "pt-BR",
        ]

        XCTAssertEqual(
            Set(LanguageCatalog.speechInput.map(\.id)),
            Set(expectedLocaleIdentifiers.keys)
        )

        for option in LanguageCatalog.speechInput {
            XCTAssertEqual(
                LanguageCatalog.speechLocaleIdentifier(for: option.id),
                expectedLocaleIdentifiers[option.id]
            )
        }
    }

    func testUnsupportedStoredSpeechInputFallsBackToEnglish() {
        XCTAssertEqual(LanguageCatalog.supportedSpeechInputLanguageID(for: "ru"), "en")
        XCTAssertEqual(LanguageCatalog.supportedSpeechInputLanguageID(for: "ar"), "en")
        XCTAssertEqual(LanguageCatalog.supportedSpeechInputLanguageID(for: "it"), "it")
    }
}
