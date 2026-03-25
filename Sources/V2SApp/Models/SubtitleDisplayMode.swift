import Foundation

enum SubtitleDisplayMode: String, Codable, CaseIterable, Sendable {
    case both
    case originalOnly
    case translatedOnly

    var showsOriginalSubtitle: Bool {
        self != .translatedOnly
    }

    var showsTranslatedSubtitle: Bool {
        self != .originalOnly
    }

    func displayName(in languageID: String) -> String {
        switch self {
        case .both:
            return AppLocalization.string(.subtitleDisplayBoth, languageID: languageID)
        case .originalOnly:
            return AppLocalization.string(.subtitleDisplayOriginalOnly, languageID: languageID)
        case .translatedOnly:
            return AppLocalization.string(.subtitleDisplayTranslatedOnly, languageID: languageID)
        }
    }
}
