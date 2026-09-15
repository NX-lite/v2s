import Foundation

struct CorrectionProviderOutput: Equatable, Sendable {
    let correctedOriginal: String?
    let correctedTranslation: String
}

struct OpenAIResponsesClient: Sendable {
    enum ClientError: Error, Equatable, LocalizedError {
        case missingAPIKey
        case invalidRequest
        case invalidResponse
        case http(status: Int, message: String)
        case imageUnsupported(message: String)
        case audioUnsupported(message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API key is missing."
            case .invalidRequest:
                return "Could not build the API request."
            case .invalidResponse:
                return "API returned an unreadable response."
            case .http(let status, let message):
                return "HTTP \(status): \(message)"
            case .imageUnsupported(let message):
                return "Image input is not supported by this provider: \(message)"
            case .audioUnsupported(let message):
                return "Audio input is not supported by this provider: \(message)"
            }
        }
    }

    struct Response: Equatable, Sendable {
        let text: String
        let imageWasSent: Bool
    }

    let apiKey: String
    let baseURLString: String
    let model: String
    let transport: any HTTPTransport

    init(
        apiKey: String,
        baseURLString: String,
        model: String,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.apiKey = apiKey
        self.baseURLString = baseURLString
        self.model = model
        self.transport = transport
    }

    func fetchAvailableModels() async throws -> [String] {
        let key = try validatedAPIKey()
        if isGeminiProvider {
            return try await fetchGeminiModels(apiKey: key)
        }
        return try await fetchOpenAIModels(apiKey: key)
    }

    func testConnection() async throws -> String {
        try await respond(
            instructions: "You are a connectivity test assistant. Reply with exactly one short sentence.",
            prompt: "Reply with: OK",
            screenshotPNGData: nil
        ).text
    }

    func validateRequestConfiguration() throws {
        _ = try validatedRequestConfiguration()
    }

    func respond(instructions: String, prompt: String, screenshotPNGData: Data?) async throws -> Response {
        let configuration = try validatedRequestConfiguration()
        switch configuration.endpoint {
        case .gemini(let url):
            return try await respondGemini(
                url: url,
                apiKey: configuration.apiKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
        case .openAI(let endpoint):
            return try await respondOpenAI(
                endpoint: endpoint,
                apiKey: configuration.apiKey,
                model: configuration.model,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
        }
    }

    func correct(prompt: CorrectionPrompt, audioWAVData: Data?) async throws -> CorrectionProviderOutput {
        guard prompt.mode != .audio || audioWAVData != nil else { throw ClientError.invalidRequest }

        let configuration = try validatedRequestConfiguration()
        let response: Response
        switch configuration.endpoint {
        case .gemini(let url):
            response = try await respondGemini(
                url: url,
                apiKey: configuration.apiKey,
                instructions: prompt.instructions,
                prompt: prompt.userContent,
                screenshotPNGData: nil,
                audioWAVData: audioWAVData
            )
        case .openAI(let endpoint):
            response = try await respondOpenAI(
                endpoint: endpoint,
                apiKey: configuration.apiKey,
                model: configuration.model,
                instructions: prompt.instructions,
                prompt: prompt.userContent,
                screenshotPNGData: nil,
                audioWAVData: audioWAVData
            )
        }
        return try Self.decodeCorrectionOutput(response.text, mode: prompt.mode)
    }

    private var isGeminiProvider: Bool {
        guard let host = Self.baseComponents(from: baseURLString)?.host else { return false }
        return host.caseInsensitiveCompare("generativelanguage.googleapis.com") == .orderedSame
    }

    private func validatedAPIKey() throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingAPIKey }
        guard !key.contains(where: \.isNewline) else { throw ClientError.invalidRequest }
        return key
    }

    private func validatedModel() throws -> String {
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedModel.isEmpty, !resolvedModel.contains(where: { $0.isNewline }) else {
            throw ClientError.invalidRequest
        }
        return resolvedModel
    }

    private func respondOpenAI(
        endpoint: OpenAIEndpoint,
        apiKey: String,
        model: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?,
        audioWAVData: Data? = nil
    ) async throws -> Response {
        let request: URLRequest
        switch endpoint {
        case .chat(let url):
            request = try openAIChatRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData,
                audioWAVData: audioWAVData
            )
        case .responses(let url):
            request = try openAIResponsesRequest(
                url: url,
                apiKey: apiKey,
                model: model,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData,
                audioWAVData: audioWAVData
            )
        }

        let sentMedia: SentMediaKind = audioWAVData == nil ? (screenshotPNGData == nil ? .none : .image) : .audio
        let data = try await successfulData(for: request, apiKey: apiKey, sentMedia: sentMedia)
        let text: String
        switch endpoint {
        case .chat:
            text = try Self.decode(ChatCompletionPayload.self, from: data).outputText
        case .responses:
            text = try Self.decode(ResponsesPayload.self, from: data).outputText
        }
        guard !text.isEmpty else { throw ClientError.invalidResponse }
        return Response(text: text, imageWasSent: screenshotPNGData != nil)
    }

    private func respondGemini(
        url: URL,
        apiKey: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?,
        audioWAVData: Data? = nil
    ) async throws -> Response {
        let parts = [GeminiPart(text: prompt)]
            + (screenshotPNGData.map { [GeminiPart(inlineData: .init(mimeType: "image/png", data: $0.base64EncodedString()))] } ?? [])
            + (audioWAVData.map { [GeminiPart(inlineData: .init(mimeType: "audio/wav", data: $0.base64EncodedString()))] } ?? [])
        let body = GeminiGenerateContentRequest(
            systemInstruction: .init(parts: [.init(text: instructions)]),
            contents: [.init(role: "user", parts: parts)],
            generationConfig: .init(maxOutputTokens: 900)
        )
        let request = try jsonRequest(url: url, method: "POST", body: body)
        let sentMedia: SentMediaKind = audioWAVData == nil ? (screenshotPNGData == nil ? .none : .image) : .audio
        let data = try await successfulData(for: request, apiKey: apiKey, sentMedia: sentMedia)
        let text = try Self.decode(GeminiGenerateContentPayload.self, from: data).outputText
        guard !text.isEmpty else { throw ClientError.invalidResponse }
        return Response(text: text, imageWasSent: screenshotPNGData != nil)
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [String] {
        let url = try openAIModelsURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await successfulData(for: request, apiKey: apiKey)
        let payload = try Self.decode(OpenAIModelsPayload.self, from: data)
        return Array(Set(payload.data.map(\.id))).sorted()
    }

    private func fetchGeminiModels(apiKey: String) async throws -> [String] {
        let url = try geminiModelsURL(apiKey: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await successfulData(for: request, apiKey: apiKey)
        let payload = try Self.decode(GeminiModelsPayload.self, from: data)
        return Array(Set(payload.models.compactMap { item in
            guard item.supportedGenerationMethods.contains("generateContent") else { return nil }
            return item.name.hasPrefix("models/") ? String(item.name.dropFirst("models/".count)) : item.name
        })).sorted()
    }

    private func openAIChatRequest(
        url: URL,
        apiKey: String,
        model: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?,
        audioWAVData: Data? = nil
    ) throws -> URLRequest {
        let content: ChatContent
        if screenshotPNGData != nil || audioWAVData != nil {
            var parts = [ChatContentPart(type: "text", text: prompt)]
            if let screenshotPNGData {
                parts.append(.init(type: "image_url", imageURL: .init(url: "data:image/png;base64,\(screenshotPNGData.base64EncodedString())", detail: "low")))
            }
            if let audioWAVData {
                parts.append(.init(type: "input_audio", inputAudio: .init(data: audioWAVData.base64EncodedString(), format: "wav")))
            }
            content = .parts(parts)
        } else {
            content = .text(prompt)
        }
        let body = ChatCompletionRequest(
            model: model,
            messages: [.init(role: "system", content: .text(instructions)), .init(role: "user", content: content)],
            maxTokens: 900
        )
        return try jsonRequest(url: url, method: "POST", authorization: apiKey, body: body)
    }

    private func openAIResponsesRequest(
        url: URL,
        apiKey: String,
        model: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?,
        audioWAVData: Data? = nil
    ) throws -> URLRequest {
        var content = [ResponsesInputPart(type: "input_text", text: prompt)]
        if let screenshotPNGData {
            content.append(.init(type: "input_image", imageURL: "data:image/png;base64,\(screenshotPNGData.base64EncodedString())"))
        }
        if let audioWAVData {
            content.append(.init(type: "input_audio", inputAudio: .init(data: audioWAVData.base64EncodedString(), format: "wav")))
        }
        let body = ResponsesRequest(
            model: model,
            instructions: instructions,
            input: [.init(role: "user", content: content)],
            maxOutputTokens: 900
        )
        return try jsonRequest(url: url, method: "POST", authorization: apiKey, body: body)
    }

    private func jsonRequest<Body: Encodable>(
        url: URL, method: String, authorization: String? = nil, body: Body
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ClientError.invalidRequest
        }
        return request
    }

    private func successfulData(for request: URLRequest, apiKey: String, sentMedia: SentMediaKind = .none) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.sanitizedErrorMessage(from: data, apiKey: apiKey) ?? "HTTP \(response.statusCode)"
            if sentMedia == .image && Self.isImageCapabilityRejection(status: response.statusCode, message: message) {
                throw ClientError.imageUnsupported(message: message)
            }
            if sentMedia == .audio && Self.isAudioCapabilityRejection(status: response.statusCode, message: message) {
                throw ClientError.audioUnsupported(message: message)
            }
            throw ClientError.http(status: response.statusCode, message: message)
        }
        return data
    }

    private enum RequestEndpoint {
        case openAI(OpenAIEndpoint)
        case gemini(URL)
    }

    private enum SentMediaKind {
        case none
        case image
        case audio
    }

    private enum OpenAIEndpoint {
        case chat(URL)
        case responses(URL)
    }

    private enum GeminiBasePath {
        case root([String])
        case models([String])
        case generateContent([String])
    }

    private func validatedRequestConfiguration() throws -> (apiKey: String, model: String, endpoint: RequestEndpoint) {
        let key = try validatedAPIKey()
        let resolvedModel = try validatedModel()
        if isGeminiProvider {
            return (
                apiKey: key,
                model: resolvedModel,
                endpoint: .gemini(try geminiGenerateContentURL(model: resolvedModel, apiKey: key))
            )
        }
        return (apiKey: key, model: resolvedModel, endpoint: .openAI(try openAIEndpoint()))
    }

    private func openAIEndpoint() throws -> OpenAIEndpoint {
        var components = try Self.requiredBaseComponents(from: baseURLString)
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if parts.last == "responses" {
            return .responses(try Self.requiredURL(components))
        }
        if parts.suffix(2) == ["chat", "completions"] {
            return .chat(try Self.requiredURL(components))
        }
        components.percentEncodedPath = Self.appending(percentEncodedPath: components.percentEncodedPath, components: ["chat", "completions"])
        return .chat(try Self.requiredURL(components))
    }

    private func openAIModelsURL() throws -> URL {
        var components = try Self.requiredBaseComponents(from: baseURLString)
        var parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if parts.suffix(2) == ["chat", "completions"] {
            parts.removeLast(2)
        } else if parts.last == "responses" {
            parts.removeLast()
        }
        if parts.last != "models" {
            parts.append("models")
        }
        components.percentEncodedPath = "/" + parts.joined(separator: "/")
        return try Self.requiredURL(components)
    }

    private func geminiModelsURL(apiKey: String) throws -> URL {
        var components = try Self.requiredBaseComponents(from: baseURLString)
        switch Self.geminiBasePath(for: components.percentEncodedPath) {
        case .root(let segments):
            components.percentEncodedPath = Self.path(from: segments + ["models"])
        case .models(let segments):
            components.percentEncodedPath = Self.path(from: segments)
        case .generateContent(var segments):
            segments.removeLast()
            if segments.last != "models" { segments.append("models") }
            components.percentEncodedPath = Self.path(from: segments)
        }
        Self.replaceAPIKey(in: &components, with: apiKey)
        return try Self.requiredURL(components)
    }

    private func geminiGenerateContentURL(model: String, apiKey: String) throws -> URL {
        var components = try Self.requiredBaseComponents(from: baseURLString)
        if case .generateContent(let segments) = Self.geminiBasePath(for: components.percentEncodedPath) {
            components.percentEncodedPath = Self.path(from: segments)
            Self.replaceAPIKey(in: &components, with: apiKey)
            return try Self.requiredURL(components)
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ClientError.invalidRequest
        }
        let segments: [String]
        switch Self.geminiBasePath(for: components.percentEncodedPath) {
        case .root(let prefix):
            segments = prefix + ["models", "\(encodedModel):generateContent"]
        case .models(let prefix):
            segments = prefix + ["\(encodedModel):generateContent"]
        case .generateContent:
            throw ClientError.invalidRequest
        }
        components.percentEncodedPath = Self.path(from: segments)
        Self.replaceAPIKey(in: &components, with: apiKey)
        return try Self.requiredURL(components)
    }

    private static func replaceAPIKey(in components: inout URLComponents, with apiKey: String) {
        let retainedPairs = (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: false).filter { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? pair
            return name.caseInsensitiveCompare("key") != .orderedSame
        }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        components.percentEncodedQuery = (retainedPairs.map(String.init) + ["key=\(encodedKey)"]).joined(separator: "&")
    }

    private static func baseComponents(from baseURLString: String) -> URLComponents? {
        let source = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, var components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return nil
        }
        var normalizedPath = components.percentEncodedPath
        while normalizedPath.last == "/" { normalizedPath.removeLast() }
        components.percentEncodedPath = normalizedPath
        components.fragment = nil
        return components
    }

    private static func requiredBaseComponents(from baseURLString: String) throws -> URLComponents {
        guard let components = baseComponents(from: baseURLString) else { throw ClientError.invalidRequest }
        return components
    }

    private static func requiredURL(_ components: URLComponents) throws -> URL {
        guard let url = components.url else { throw ClientError.invalidRequest }
        return url
    }

    private static func appending(percentEncodedPath: String, components: [String]) -> String {
        let existing = percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + ([existing] + components).filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func geminiBasePath(for percentEncodedPath: String) -> GeminiBasePath {
        let segments = percentEncodedPath.split(separator: "/").map(String.init)
        if segments.last?.hasSuffix(":generateContent") == true { return .generateContent(segments) }
        if segments.last == "models" { return .models(segments) }
        return .root(segments)
    }

    private static func path(from segments: [String]) -> String {
        "/" + segments.joined(separator: "/")
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private static func decodeCorrectionOutput(_ text: String, mode: CorrectionInputMode) throws -> CorrectionProviderOutput {
        let output = try decode(CorrectionOutputPayload.self, from: Data(text.utf8))
        let translation = output.correctedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { throw ClientError.invalidResponse }

        switch mode {
        case .audio:
            guard let correctedOriginal = output.correctedOriginal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !correctedOriginal.isEmpty else {
                throw ClientError.invalidResponse
            }
            return CorrectionProviderOutput(correctedOriginal: correctedOriginal, correctedTranslation: translation)
        case .textOnly:
            return CorrectionProviderOutput(correctedOriginal: nil, correctedTranslation: translation)
        }
    }

    private static func sanitizedErrorMessage(from data: Data, apiKey: String) -> String? {
        guard let payload = try? JSONDecoder().decode(ProviderErrorPayload.self, from: data) else { return nil }
        let raw = payload.error.message ?? payload.error.status
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return sanitize(raw, apiKey: apiKey)
    }

    private static func sanitize(_ message: String, apiKey: String) -> String {
        var sanitized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: apiKey, with: "[redacted]")
        sanitized = sanitized.replacingOccurrences(of: "authorization", with: "[redacted-header]", options: .caseInsensitive)
        sanitized = sanitized.replacingOccurrences(
            of: "(?i)data:[^\\s\\\"']*;base64,[A-Za-z0-9+/]+={0,2}",
            with: "[redacted-media]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{2,}={1,2}(?![A-Za-z0-9+/=])",
            with: "[redacted-media]",
            options: .regularExpression
        )
        return String(sanitized.prefix(1_000))
    }

    private static func isImageUnsupportedError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return ["image", "vision", "visual", "multimodal", "multi-modal", "inline_data", "no endpoints"].contains {
            lowercased.contains($0)
        }
    }

    private static func isImageCapabilityRejection(status: Int, message: String) -> Bool {
        status != 401 && status != 403 && status != 429 && !(500..<600).contains(status) && isImageUnsupportedError(message)
    }

    private static func isAudioCapabilityRejection(status: Int, message: String) -> Bool {
        status == 400 && isAudioUnsupportedError(message)
    }

    private static func isAudioUnsupportedError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return ["audio", "speech", "voice", "input_audio", "inline_data", "multimodal", "multi-modal"].contains {
            lowercased.contains($0)
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int

    enum CodingKeys: String, CodingKey { case model, messages; case maxTokens = "max_tokens" }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: ChatContent
}

private enum ChatContent: Encodable {
    case text(String)
    case parts([ChatContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

private struct ChatContentPart: Encodable {
    struct ImageURL: Encodable {
        let url: String
        let detail: String
    }

    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let type: String
    let text: String?
    let imageURL: ImageURL?
    let inputAudio: InputAudio?

    init(type: String, text: String? = nil, imageURL: ImageURL? = nil, inputAudio: InputAudio? = nil) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
        self.inputAudio = inputAudio
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [ResponsesInput]
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey { case model, instructions, input; case maxOutputTokens = "max_output_tokens" }
}

private struct ResponsesInput: Encodable {
    let role: String
    let content: [ResponsesInputPart]
}

private struct ResponsesInputPart: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let type: String
    let text: String?
    let imageURL: String?
    let inputAudio: InputAudio?

    init(type: String, text: String? = nil, imageURL: String? = nil, inputAudio: InputAudio? = nil) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
        self.inputAudio = inputAudio
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    struct SystemInstruction: Encodable { let parts: [GeminiPart] }
    struct Content: Encodable { let role: String; let parts: [GeminiPart] }
    struct GenerationConfig: Encodable { let maxOutputTokens: Int }

    let systemInstruction: SystemInstruction
    let contents: [Content]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case contents, generationConfig
        case systemInstruction = "system_instruction"
    }
}

private struct GeminiPart: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String
        enum CodingKeys: String, CodingKey { case data; case mimeType = "mime_type" }
    }

    let text: String?
    let inlineData: InlineData?

    init(text: String) { self.text = text; self.inlineData = nil }
    init(inlineData: InlineData) { self.text = nil; self.inlineData = inlineData }

    enum CodingKeys: String, CodingKey { case text; case inlineData = "inline_data" }
}

private struct ChatCompletionPayload: Decodable {
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
    let choices: [Choice]

    var outputText: String {
        choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ResponsesPayload: Decodable {
    struct Output: Decodable { let content: [Content]? }
    struct Content: Decodable { let type: String; let text: String? }
    let output: [Output]

    var outputText: String {
        output.flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GeminiGenerateContentPayload: Decodable {
    struct Candidate: Decodable { let content: Content }
    struct Content: Decodable { let parts: [Part] }
    struct Part: Decodable { let text: String? }
    let candidates: [Candidate]

    var outputText: String {
        candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct CorrectionOutputPayload: Decodable {
    let correctedOriginal: String?
    let correctedTranslation: String
}

private struct OpenAIModelsPayload: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct GeminiModelsPayload: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]
    }
    let models: [Model]
}

private struct ProviderErrorPayload: Decodable {
    struct ProviderError: Decodable { let message: String?; let status: String? }
    let error: ProviderError
}
