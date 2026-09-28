import Foundation
import Testing
@testable import v2s

@Suite struct RealtimeEndpointResolverTests {
    @Test func bearerProvidersUseTheirOwnWSSHosts() throws {
        let cases: [(NativeRealtimeProfile, String)] = [
            (.openAIMini, "api.openai.com"),
            (.openAI, "api.openai.com"),
            (.xAIVoice, "api.x.ai"),
            (.xAIVoiceThinkFast, "api.x.ai"),
        ]
        for (profile, host) in cases {
            var settings = NativeRealtimeSettings.default
            settings.profile = profile
            let request = try RealtimeEndpointResolver.request(
                settings: settings,
                credential: "dummy-key"
            )
            let url = try #require(request.url)
            #expect(url.scheme == "wss")
            #expect(url.host == host)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-key")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "model" })?.value == profile.modelID)
        }
    }

    @Test func qwenRequiresValidWorkspaceAndSupportedRegion() throws {
        var settings = NativeRealtimeSettings.default
        settings.profile = .qwenOmniFlash
        settings.region = .singapore
        settings.qwenWorkspaceID = "workspace-123"
        let request = try RealtimeEndpointResolver.request(
            settings: settings,
            credential: "dummy-key"
        )
        let url = try #require(request.url)
        #expect(url.host == "workspace-123.ap-southeast-1.maas.aliyuncs.com")
        #expect(url.path == "/api-ws/v1/realtime")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "model" })?.value == "qwen3.8-omni-flash-realtime")

        settings.region = .unitedStates
        #expect(throws: RealtimeEndpointError.unsupportedRegion) {
            try RealtimeEndpointResolver.request(settings: settings, credential: "dummy-key")
        }
        settings.region = .china
        settings.qwenWorkspaceID = "bad/host"
        #expect(throws: RealtimeEndpointError.invalidWorkspace) {
            try RealtimeEndpointResolver.request(settings: settings, credential: "dummy-key")
        }
    }

    @Test func geminiKeyIsEscapedInQueryOnly() throws {
        var settings = NativeRealtimeSettings.default
        settings.profile = .geminiLive
        let request = try RealtimeEndpointResolver.request(
            settings: settings,
            credential: "dummy&key"
        )
        let url = try #require(request.url)
        #expect(url.host == "generativelanguage.googleapis.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value == "dummy&key")
    }

    @Test func blankCredentialIsRejectedBeforeBuildingURL() {
        #expect(throws: RealtimeEndpointError.invalidCredential) {
            try RealtimeEndpointResolver.request(
                settings: .default,
                credential: " \n "
            )
        }
        #expect(throws: RealtimeEndpointError.invalidCredential) {
            try RealtimeEndpointResolver.request(
                settings: .default,
                credential: "dummy\nInjected: value"
            )
        }
    }
}
