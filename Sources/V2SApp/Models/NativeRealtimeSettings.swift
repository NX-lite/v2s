import Foundation

enum NativeRealtimeProvider: String, Codable, Sendable {
    case openAI
    case qwen
    case gemini
    case xAI
}

enum NativeRealtimeRegion: String, CaseIterable, Codable, Sendable {
    case global
    case china
    case singapore
    case unitedStates
}

enum NativeRealtimeProfile: String, CaseIterable, Codable, Sendable {
    case openAIMini
    case openAI
    case qwenOmniFlash
    case geminiLive
    case xAIVoice
    case xAIVoiceThinkFast

    var provider: NativeRealtimeProvider {
        switch self {
        case .openAIMini, .openAI: .openAI
        case .qwenOmniFlash: .qwen
        case .geminiLive: .gemini
        case .xAIVoice, .xAIVoiceThinkFast: .xAI
        }
    }

    var modelID: String {
        switch self {
        case .openAIMini: "gpt-realtime-2.1-mini"
        case .openAI: "gpt-realtime-2.1"
        case .qwenOmniFlash: "qwen3.8-omni-flash-realtime"
        case .geminiLive: "gemini-3.8-live"
        case .xAIVoice: "grok-voice-latest"
        case .xAIVoiceThinkFast: "grok-voice-think-fast-2.0"
        }
    }

    var supportsVideo: Bool {
        self == .qwenOmniFlash || self == .geminiLive
    }
}

struct NativeRealtimeSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var profile: NativeRealtimeProfile
    var region: NativeRealtimeRegion
    var credentialReference: String?
    var qwenWorkspaceID: String?
    var enabledSourceIDs: [String] {
        didSet { enabledSourceIDs = Self.normalized(enabledSourceIDs) }
    }

    static let `default` = Self(
        isEnabled: false,
        profile: .openAIMini,
        region: .global,
        credentialReference: nil,
        qwenWorkspaceID: nil,
        enabledSourceIDs: []
    )

    init(
        isEnabled: Bool,
        profile: NativeRealtimeProfile,
        region: NativeRealtimeRegion,
        credentialReference: String?,
        qwenWorkspaceID: String?,
        enabledSourceIDs: [String]
    ) {
        self.isEnabled = isEnabled
        self.profile = profile
        self.region = region
        self.credentialReference = credentialReference
        self.qwenWorkspaceID = qwenWorkspaceID
        self.enabledSourceIDs = Self.normalized(enabledSourceIDs)
    }

    func isEnabled(for sourceID: String) -> Bool {
        isEnabled && enabledSourceIDs.contains(sourceID)
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        profile = (try? c.decode(NativeRealtimeProfile.self, forKey: .profile)) ?? .openAIMini
        region = (try? c.decode(NativeRealtimeRegion.self, forKey: .region)) ?? .global
        credentialReference = try? c.decodeIfPresent(String.self, forKey: .credentialReference)
        qwenWorkspaceID = try? c.decodeIfPresent(String.self, forKey: .qwenWorkspaceID)
        enabledSourceIDs = Self.normalized(
            (try? c.decode([String].self, forKey: .enabledSourceIDs)) ?? []
        )
    }
}
