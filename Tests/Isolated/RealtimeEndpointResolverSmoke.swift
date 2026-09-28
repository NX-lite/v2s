import Foundation

@main struct RealtimeEndpointResolverSmoke {
    static func main() throws {
        var settings = NativeRealtimeSettings.default
        settings.profile = .openAIMini
        let openAI = try RealtimeEndpointResolver.request(settings: settings, credential: "dummy-key")
        precondition(openAI.url?.scheme == "wss")
        precondition(openAI.url?.host == "api.openai.com")
        precondition(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-key")

        settings.profile = .qwenOmniFlash
        settings.region = .singapore
        settings.qwenWorkspaceID = "workspace-123"
        let qwen = try RealtimeEndpointResolver.request(settings: settings, credential: "dummy-key")
        precondition(qwen.url?.host == "workspace-123.ap-southeast-1.maas.aliyuncs.com")

        settings.region = .unitedStates
        do {
            _ = try RealtimeEndpointResolver.request(settings: settings, credential: "dummy-key")
            preconditionFailure("unsupported Qwen region accepted")
        } catch RealtimeEndpointError.unsupportedRegion {
        }

        settings.region = .global
        settings.profile = .geminiLive
        let gemini = try RealtimeEndpointResolver.request(settings: settings, credential: "dummy&key")
        guard let url = gemini.url else { preconditionFailure("Gemini URL missing") }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value
        precondition(key == "dummy&key")
        precondition(gemini.value(forHTTPHeaderField: "Authorization") == nil)

        settings.profile = .openAI
        do {
            _ = try RealtimeEndpointResolver.request(
                settings: settings,
                credential: "dummy\nInjected: value"
            )
            preconditionFailure("control character in credential accepted")
        } catch RealtimeEndpointError.invalidCredential {
        }
    }
}
