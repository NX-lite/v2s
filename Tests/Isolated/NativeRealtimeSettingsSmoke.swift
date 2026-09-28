import Foundation

@main struct NativeRealtimeSettingsSmoke {
    static func main() throws {
        let defaults = NativeRealtimeSettings.default
        precondition(!defaults.isEnabled)
        precondition(defaults.enabledSourceIDs.isEmpty)
        precondition(defaults.profile == .openAIMini)
        precondition(NativeRealtimeProfile.qwenOmniFlash.supportsVideo)
        precondition(!NativeRealtimeProfile.xAIVoice.supportsVideo)

        var selected = defaults
        selected.isEnabled = true
        selected.enabledSourceIDs = ["mic-2", "mic-1", "mic-2"]
        precondition(selected.enabledSourceIDs == ["mic-1", "mic-2"])
        precondition(selected.isEnabled(for: "mic-1"))
        precondition(!selected.isEnabled(for: "app-1"))

        let data = try JSONEncoder().encode(selected)
        let decoded = try JSONDecoder().decode(NativeRealtimeSettings.self, from: data)
        precondition(decoded == selected)
    }
}
