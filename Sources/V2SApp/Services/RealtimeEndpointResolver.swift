import Foundation

enum RealtimeEndpointError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidWorkspace
    case unsupportedRegion
    case invalidURL
}

enum RealtimeEndpointResolver {
    static func request(
        settings: NativeRealtimeSettings,
        credential: String
    ) throws -> URLRequest {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw RealtimeEndpointError.invalidCredential
        }

        let profile = settings.profile
        var components = URLComponents()
        components.scheme = "wss"
        switch profile.provider {
        case .openAI:
            guard settings.region == .global else {
                throw RealtimeEndpointError.unsupportedRegion
            }
            components.host = "api.openai.com"
            components.path = "/v1/realtime"
        case .qwen:
            guard let workspace = settings.qwenWorkspaceID,
                  validWorkspace(workspace) else {
                throw RealtimeEndpointError.invalidWorkspace
            }
            switch settings.region {
            case .china:
                components.host = "\(workspace).cn-beijing.maas.aliyuncs.com"
            case .singapore:
                components.host = "\(workspace).ap-southeast-1.maas.aliyuncs.com"
            default:
                throw RealtimeEndpointError.unsupportedRegion
            }
            components.path = "/api-ws/v1/realtime"
        case .gemini:
            guard settings.region == .global else {
                throw RealtimeEndpointError.unsupportedRegion
            }
            components.host = "generativelanguage.googleapis.com"
            components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
            components.queryItems = [URLQueryItem(name: "key", value: credential)]
        case .xAI:
            guard settings.region == .global else {
                throw RealtimeEndpointError.unsupportedRegion
            }
            components.host = "api.x.ai"
            components.path = "/v1/realtime"
        }

        if profile.provider != .gemini {
            components.queryItems = [URLQueryItem(name: "model", value: profile.modelID)]
        }
        guard let url = components.url, url.scheme == "wss" else {
            throw RealtimeEndpointError.invalidURL
        }
        var request = URLRequest(url: url)
        if profile.provider != .gemini {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validWorkspace(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63,
              value.first != "-", value.last != "-" else {
            return false
        }
        return value.utf8.allSatisfy {
            (48...57).contains($0) ||
                (65...90).contains($0) ||
                (97...122).contains($0) ||
                $0 == 45
        }
    }
}
