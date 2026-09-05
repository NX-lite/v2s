import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var selectedSourceIDs: [String]
    var sourceLanguageOverrides: [String: String]
    var sourceOutputLanguageOverrides: [String: String]
    var inputLanguageID: String
    var outputLanguageID: String
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var subtitleDisplayMode: SubtitleDisplayMode
    var glossary: [String: String]
    var assistant: AssistantSettings

    static let `default` = AppSettings(
        selectedSourceID: nil,
        selectedSourceIDs: [],
        sourceLanguageOverrides: [:],
        sourceOutputLanguageOverrides: [:],
        inputLanguageID: "en",
        outputLanguageID: "zh-Hans",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:],
        assistant: .default
    )

    private enum LegacyCodingKeys: String, CodingKey {
        case privacyModeEnabled
        case gptAPIKey
        case gptAPIBaseURL
        case gptModel
        case gptSkills
        case autoDetectConversationLanguages
        case hotKeyFollowUp
        case hotKeyAsk
        case hotKeySwitchMode
    }

    // Custom decoder so existing settings files load cleanly as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try? c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        selectedSourceIDs = (try? c.decodeIfPresent([String].self, forKey: .selectedSourceIDs))
            ?? selectedSourceID.map { [$0] }
            ?? AppSettings.default.selectedSourceIDs
        sourceLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceLanguageOverrides))
            ?? AppSettings.default.sourceLanguageOverrides
        sourceOutputLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceOutputLanguageOverrides))
            ?? AppSettings.default.sourceOutputLanguageOverrides
        inputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .inputLanguageID))
            ?? AppSettings.default.inputLanguageID
        outputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .outputLanguageID))
            ?? AppSettings.default.outputLanguageID
        interfaceLanguageID = try? c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle = (try? c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle))
            ?? AppSettings.default.overlayStyle
        subtitleMode = (try? c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode))
            ?? AppSettings.default.subtitleMode
        subtitleDisplayMode = (try? c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode))
            ?? AppSettings.default.subtitleDisplayMode
        glossary = (try? c.decodeIfPresent([String: String].self, forKey: .glossary))
            ?? AppSettings.default.glossary

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let nestedAssistant = try? c.decodeIfPresent(AssistantSettings.self, forKey: .assistant) {
            assistant = nestedAssistant
        } else {
            assistant = AssistantSettings(
                apiKey: (try? legacy.decodeIfPresent(String.self, forKey: .gptAPIKey))
                    ?? AssistantSettings.default.apiKey,
                baseURL: (try? legacy.decodeIfPresent(String.self, forKey: .gptAPIBaseURL))
                    ?? AssistantSettings.default.baseURL,
                model: (try? legacy.decodeIfPresent(String.self, forKey: .gptModel))
                    ?? AssistantSettings.default.model,
                skills: (try? legacy.decodeIfPresent(String.self, forKey: .gptSkills))
                    ?? AssistantSettings.default.skills,
                autoDetectConversationLanguages: (try? legacy.decodeIfPresent(Bool.self, forKey: .autoDetectConversationLanguages))
                    ?? AssistantSettings.default.autoDetectConversationLanguages,
                followUpHotKey: (try? legacy.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeyFollowUp))
                    ?? AssistantSettings.default.followUpHotKey,
                askHotKey: (try? legacy.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeyAsk))
                    ?? AssistantSettings.default.askHotKey,
                switchModeHotKey: (try? legacy.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeySwitchMode))
                    ?? AssistantSettings.default.switchModeHotKey
            )
        }

        if let privacyModeEnabled = try? legacy.decodeIfPresent(Bool.self, forKey: .privacyModeEnabled) {
            overlayStyle.invisibleInRecording = privacyModeEnabled
        }
    }

    init(
        selectedSourceID: String?,
        selectedSourceIDs: [String] = [],
        sourceLanguageOverrides: [String: String] = [:],
        sourceOutputLanguageOverrides: [String: String] = [:],
        inputLanguageID: String,
        outputLanguageID: String,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        subtitleDisplayMode: SubtitleDisplayMode,
        glossary: [String: String],
        assistant: AssistantSettings = .default
    ) {
        self.selectedSourceID = selectedSourceID
        self.selectedSourceIDs = selectedSourceIDs
        self.sourceLanguageOverrides = sourceLanguageOverrides
        self.sourceOutputLanguageOverrides = sourceOutputLanguageOverrides
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.glossary         = glossary
        self.assistant = assistant
    }
}
