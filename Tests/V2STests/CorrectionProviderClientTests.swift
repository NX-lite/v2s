import Foundation
import Testing
@testable import v2s

@Suite struct CorrectionProviderClientTests {
    @Test func chatCorrectionAudioRequestUsesInputAudioPart() async throws {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.chat, output: audioOutput()))])
        let client = makeClient(.chat, transport: transport)

        let result = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1, 2]))
        let body = try requestBody(await transport.firstRequest())
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        let audioPart = try #require(content.first { $0["type"] as? String == "input_audio" })
        let inputAudio = try #require(audioPart["input_audio"] as? [String: Any])

        #expect(inputAudio["data"] as? String == "AQI=")
        #expect(inputAudio["format"] as? String == "wav")
        #expect(result == .init(correctedOriginal: "Original", correctedTranslation: "Translation"))
    }

    @Test func responsesCorrectionAudioRequestUsesInputAudioPart() async throws {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.responses, output: audioOutput()))])
        let client = makeClient(.responses, transport: transport)

        _ = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1, 2]))
        let body = try requestBody(await transport.firstRequest())
        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let audioPart = try #require(content.first { $0["type"] as? String == "input_audio" })
        let inputAudio = try #require(audioPart["input_audio"] as? [String: Any])

        #expect(inputAudio["data"] as? String == "AQI=")
        #expect(inputAudio["format"] as? String == "wav")
    }

    @Test func geminiCorrectionAudioRequestUsesInlineWAVData() async throws {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.gemini, output: audioOutput()))])
        let client = makeClient(.gemini, transport: transport)

        _ = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1, 2]))
        let body = try requestBody(await transport.firstRequest())
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let inlineData = try #require((parts.first { $0["inline_data"] != nil })?["inline_data"] as? [String: Any])

        #expect(inlineData["mime_type"] as? String == "audio/wav")
        #expect(inlineData["data"] as? String == "AQI=")
    }

    @Test func textOnlyRequestsDoNotContainAttachments() async throws {
        for provider in ProviderKind.allCases {
            let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(provider, output: textOutput()))])
            let client = makeClient(provider, transport: transport)

            let result = try await client.correct(prompt: textPrompt(), audioWAVData: nil)
            let request = try #require(await transport.firstRequest())
            let body = try #require(request.httpBody)
            let serializedBody = try #require(String(data: body, encoding: .utf8))

            #expect(!serializedBody.contains("input_audio"))
            #expect(!serializedBody.contains("input_image"))
            #expect(!serializedBody.contains("image_url"))
            #expect(!serializedBody.contains("inline_data"))
            #expect(result == .init(correctedOriginal: nil, correctedTranslation: "Translation"))
        }
    }

    @Test func textOnlyRequestsIgnoreSuppliedAudioData() async throws {
        for provider in ProviderKind.allCases {
            let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(provider, output: textOutput()))])
            let client = makeClient(provider, transport: transport)

            let result = try await client.correct(prompt: textPrompt(), audioWAVData: Data([1, 2]))
            let request = try #require(await transport.firstRequest())
            let body = try #require(request.httpBody)
            let serializedBody = try #require(String(data: body, encoding: .utf8))

            #expect(!serializedBody.contains("input_audio"))
            #expect(!serializedBody.contains("input_image"))
            #expect(!serializedBody.contains("image_url"))
            #expect(!serializedBody.contains("inline_data"))
            #expect(!serializedBody.contains("AQI="))
            #expect(!serializedBody.contains("audio/wav"))
            #expect(result == .init(correctedOriginal: nil, correctedTranslation: "Translation"))
        }
    }

    @Test func audioCorrectionRequiresAudioData() async {
        let transport = StubHTTPTransport(stubs: [])
        let client = makeClient(.chat, transport: transport)

        await #expect(throws: OpenAIResponsesClient.ClientError.invalidRequest) {
            try await client.correct(prompt: audioPrompt(), audioWAVData: nil)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func audioCorrectionRejectsEmptyAudioData() async {
        let transport = StubHTTPTransport(stubs: [])
        let client = makeClient(.chat, transport: transport)

        await #expect(throws: OpenAIResponsesClient.ClientError.invalidRequest) {
            try await client.correct(prompt: audioPrompt(), audioWAVData: Data())
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func correctionOutputTrimsAudioFields() async throws {
        let transport = StubHTTPTransport(stubs: [
            .init(status: 200, data: providerResponse(.chat, output: audioOutput(original: "  Original \n", translation: "\tTranslation  "))),
        ])
        let client = makeClient(.chat, transport: transport)

        let result = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1]))

        #expect(result == .init(correctedOriginal: "Original", correctedTranslation: "Translation"))
    }

    @Test func textOnlyCorrectionIgnoresCorrectedOriginalAndUnknownKeys() async throws {
        let output = correctionOutputText([
            "correctedOriginal": "Should be ignored",
            "correctedTranslation": "  Translation  ",
            "future": "ignored",
        ])
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.chat, output: output))])
        let client = makeClient(.chat, transport: transport)

        let result = try await client.correct(prompt: textPrompt(), audioWAVData: nil)

        #expect(result == .init(correctedOriginal: nil, correctedTranslation: "Translation"))
    }

    @Test(arguments: [
        "```json\n{\"correctedTranslation\":\"Translation\"}\n```",
        "Here is the result: {\"correctedTranslation\":\"Translation\"}",
        "{not valid JSON}",
    ]) func correctionOutputRejectsFencesProseAndMalformedJSON(_ output: String) async {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.chat, output: output))])
        let client = makeClient(.chat, transport: transport)

        await #expect(throws: OpenAIResponsesClient.ClientError.invalidResponse) {
            try await client.correct(prompt: textPrompt(), audioWAVData: nil)
        }
    }

    @Test func correctionOutputRejectsEmptyStringsWrongTypesAndMissingRequiredFields() async {
        let invalidOutputs = [
            correctionOutputText(["correctedOriginal": "", "correctedTranslation": "Translation"]),
            correctionOutputText(["correctedOriginal": "Original", "correctedTranslation": "   "]),
            correctionOutputText(["correctedOriginal": "Original", "correctedTranslation": 42]),
            correctionOutputText(["correctedTranslation": "Translation"]),
        ]

        for output in invalidOutputs {
            let transport = StubHTTPTransport(stubs: [.init(status: 200, data: providerResponse(.chat, output: output))])
            let client = makeClient(.chat, transport: transport)

            await #expect(throws: OpenAIResponsesClient.ClientError.invalidResponse) {
                try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1]))
            }
        }

        let missingTranslation = StubHTTPTransport(stubs: [
            .init(status: 200, data: providerResponse(.chat, output: correctionOutputText(["correctedOriginal": "Ignored"]))),
        ])
        let textClient = makeClient(.chat, transport: missingTranslation)
        await #expect(throws: OpenAIResponsesClient.ClientError.invalidResponse) {
            try await textClient.correct(prompt: textPrompt(), audioWAVData: nil)
        }
    }

    @Test func audioKeyword400IsAudioUnsupportedAndRedactsCredentialsAndAudio() async {
        let payload = providerError("input_audio rejected for test-placeholder-key: AQI=")
        let transport = StubHTTPTransport(stubs: [.init(status: 400, data: payload)])
        let client = makeClient(.chat, transport: transport)

        do {
            _ = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1, 2]))
            Issue.record("Expected audioUnsupported")
        } catch let error as OpenAIResponsesClient.ClientError {
            guard case .audioUnsupported(let message) = error else {
                Issue.record("Expected audioUnsupported, got \(error)")
                return
            }
            #expect(!message.contains("test-placeholder-key"))
            #expect(!message.contains("AQI="))
            #expect(!(error.errorDescription ?? "").contains("test-placeholder-key"))
            #expect(!(error.errorDescription ?? "").contains("AQI="))
        } catch {
            Issue.record("Expected ClientError, got \(error)")
        }
    }

    @Test func generic400AndAudioKeywordsWithoutAudioStayHTTP() async {
        for audioData: Data? in [Data([1]), nil] {
            let message = audioData == nil ? "input_audio unavailable" : "generic bad request"
            let transport = StubHTTPTransport(stubs: [.init(status: 400, data: providerError(message))])
            let client = makeClient(.chat, transport: transport)

            do {
                _ = try await client.correct(prompt: audioData == nil ? textPrompt() : audioPrompt(), audioWAVData: audioData)
                Issue.record("Expected HTTP error")
            } catch let error as OpenAIResponsesClient.ClientError {
                guard case .http(let status, let errorMessage) = error else {
                    Issue.record("Expected HTTP error, got \(error)")
                    continue
                }
                #expect(status == 400)
                #expect(errorMessage.contains(message))
            } catch {
                Issue.record("Expected ClientError, got \(error)")
            }
        }
    }

    @Test func authenticationRateLimitAndServerErrorsStayHTTPForAudio() async {
        for status in [401, 403, 429, 500] {
            let transport = StubHTTPTransport(stubs: [.init(status: status, data: providerError("voice input unavailable"))])
            let client = makeClient(.chat, transport: transport)

            do {
                _ = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1]))
                Issue.record("Expected HTTP \(status) error")
            } catch let error as OpenAIResponsesClient.ClientError {
                guard case .http(let actualStatus, _) = error else {
                    Issue.record("Expected HTTP error, got \(error)")
                    continue
                }
                #expect(actualStatus == status)
            } catch {
                Issue.record("Expected ClientError, got \(error)")
            }
        }
    }

    @Test func transportFailureIsInvalidResponseForAudioCorrection() async {
        let transport = StubHTTPTransport(stubs: [], shouldFailTransport: true)
        let client = makeClient(.chat, transport: transport)

        await #expect(throws: OpenAIResponsesClient.ClientError.invalidResponse) {
            try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1]))
        }
    }

    private func makeClient(_ provider: ProviderKind, transport: any HTTPTransport) -> OpenAIResponsesClient {
        let baseURLString: String
        switch provider {
        case .chat:
            baseURLString = "https://example.invalid/v1"
        case .responses:
            baseURLString = "https://example.invalid/v1/responses"
        case .gemini:
            baseURLString = "https://generativelanguage.googleapis.com/v1beta"
        }
        return OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: baseURLString,
            model: "test-model",
            transport: transport
        )
    }

    private func audioPrompt() -> CorrectionPrompt {
        .init(instructions: "Return strict JSON.", userContent: "Correct this sentence.", mode: .audio)
    }

    private func textPrompt() -> CorrectionPrompt {
        .init(instructions: "Return strict JSON.", userContent: "Correct this translation.", mode: .textOnly)
    }

    private func requestBody(_ request: URLRequest?) throws -> [String: Any] {
        let request = try #require(request)
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func audioOutput(original: String = "Original", translation: String = "Translation") -> String {
        correctionOutputText(["correctedOriginal": original, "correctedTranslation": translation])
    }

    private func textOutput(translation: String = "Translation") -> String {
        correctionOutputText(["correctedTranslation": translation])
    }

    private func correctionOutputText(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func providerResponse(_ provider: ProviderKind, output: String) -> Data {
        let object: [String: Any]
        switch provider {
        case .chat:
            object = ["choices": [["message": ["content": output]]]]
        case .responses:
            object = ["output": [["type": "message", "content": [["type": "output_text", "text": output]]]]]
        case .gemini:
            object = ["candidates": [["content": ["parts": [["text": output]]]]]]
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func providerError(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message]], options: [.sortedKeys])
    }
}

private enum ProviderKind: CaseIterable, Sendable {
    case chat
    case responses
    case gemini
}

private actor StubHTTPTransport: HTTPTransport {
    struct Stub: Sendable {
        let status: Int
        let data: Data
    }

    enum StubError: Error { case exhausted, transportFailure }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []
    private let shouldFailTransport: Bool

    init(stubs: [Stub], shouldFailTransport: Bool = false) {
        self.stubs = stubs
        self.shouldFailTransport = shouldFailTransport
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if shouldFailTransport { throw StubError.transportFailure }
        guard !stubs.isEmpty else { throw StubError.exhausted }
        let stub = stubs.removeFirst()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil) else {
            throw StubError.exhausted
        }
        return (stub.data, response)
    }

    func firstRequest() -> URLRequest? { requests.first }
    func requestCount() -> Int { requests.count }
}
