import Foundation

struct HotKeyBinding: Codable, Equatable, Hashable {
    static let allowedKeys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)
    static let defaultFollowUp = Self(
        key: "f",
        useCommand: true,
        useOption: true,
        useControl: false,
        useShift: false
    )
    static let defaultAsk = Self(
        key: "g",
        useCommand: true,
        useOption: true,
        useControl: false,
        useShift: false
    )
    static let defaultSwitchMode = Self(
        key: "t",
        useCommand: true,
        useOption: true,
        useControl: false,
        useShift: false
    )

    var key: String
    var useCommand: Bool
    var useOption: Bool
    var useControl: Bool
    var useShift: Bool

    var normalizedKey: String { key.lowercased() }

    var isValid: Bool {
        Self.allowedKeys.contains(normalizedKey)
            && (useCommand || useOption || useControl || useShift)
    }

    var displayString: String {
        var result = ""
        if useControl { result += "⌃" }
        if useOption { result += "⌥" }
        if useShift { result += "⇧" }
        if useCommand { result += "⌘" }
        return result + normalizedKey.uppercased()
    }
}

struct AssistantSettings: Codable, Equatable {
    var apiKey: String
    var baseURL: String
    var model: String
    var skills: String
    var autoDetectConversationLanguages: Bool
    var followUpHotKey: HotKeyBinding
    var askHotKey: HotKeyBinding
    var switchModeHotKey: HotKeyBinding

    static let `default` = Self(
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o",
        skills: "",
        autoDetectConversationLanguages: true,
        followUpHotKey: .defaultFollowUp,
        askHotKey: .defaultAsk,
        switchModeHotKey: .defaultSwitchMode
    )

    init(
        apiKey: String,
        baseURL: String,
        model: String,
        skills: String,
        autoDetectConversationLanguages: Bool,
        followUpHotKey: HotKeyBinding,
        askHotKey: HotKeyBinding,
        switchModeHotKey: HotKeyBinding
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.skills = skills
        self.autoDetectConversationLanguages = autoDetectConversationLanguages
        self.followUpHotKey = followUpHotKey
        self.askHotKey = askHotKey
        self.switchModeHotKey = switchModeHotKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? Self.default.apiKey
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? Self.default.baseURL
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? Self.default.model
        skills = (try? c.decodeIfPresent(String.self, forKey: .skills)) ?? Self.default.skills
        autoDetectConversationLanguages = (try? c.decodeIfPresent(Bool.self, forKey: .autoDetectConversationLanguages))
            ?? Self.default.autoDetectConversationLanguages
        followUpHotKey = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .followUpHotKey))
            ?? Self.default.followUpHotKey
        askHotKey = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .askHotKey))
            ?? Self.default.askHotKey
        switchModeHotKey = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .switchModeHotKey))
            ?? Self.default.switchModeHotKey
    }
}
