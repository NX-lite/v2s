import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var inputLanguageID: String
    var outputLanguageID: String
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var subtitleDisplayMode: SubtitleDisplayMode
    var glossary: [String: String]

    static let `default` = AppSettings(
        selectedSourceID: nil,
        inputLanguageID: "en",
        outputLanguageID: "zh-Hans",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:]
    )

    // Custom decoder so existing settings files load cleanly as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        inputLanguageID  = try c.decode(String.self, forKey: .inputLanguageID)
        outputLanguageID = try c.decode(String.self, forKey: .outputLanguageID)
        interfaceLanguageID = try c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle     = try c.decode(OverlayStyle.self, forKey: .overlayStyle)
        subtitleMode     = try c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? .balanced
        subtitleDisplayMode = try c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode) ?? .both
        glossary         = try c.decodeIfPresent([String: String].self, forKey: .glossary) ?? [:]
    }

    init(
        selectedSourceID: String?,
        inputLanguageID: String,
        outputLanguageID: String,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        subtitleDisplayMode: SubtitleDisplayMode,
        glossary: [String: String]
    ) {
        self.selectedSourceID = selectedSourceID
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.glossary         = glossary
    }
}
