import Foundation

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum LanguageCatalog {
    static let common: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "de", displayName: "German"),
    ]

    static func displayName(for identifier: String) -> String {
        common.first(where: { $0.id == identifier })?.displayName ?? identifier
    }
}
