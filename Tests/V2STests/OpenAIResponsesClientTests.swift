import Foundation
import Testing
@testable import v2s

@Suite struct OpenAIResponsesClientTests {
    @Test func openAIRequestUsesNormalizedChatEndpointAndBearerHeader() async throws {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: chatResponse("hello"))])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: "https://example.invalid/v1/",
            model: "gpt-test",
            transport: transport
        )

        let response = try await client.respond(instructions: "Be concise.", prompt: "Hi", screenshotPNGData: nil)
        let request = try #require(await transport.firstRequest())

        #expect(response == .init(text: "hello", imageWasSent: false))
        #expect(request.url?.absoluteString == "https://example.invalid/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder-key")
    }

    @Test func openAIImageRequestUsesTextAndDataURLParts() async throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: chatResponse("seen"))])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1", model: "gpt-test", transport: transport
        )

        let response = try await client.respond(instructions: "System", prompt: "Describe it", screenshotPNGData: image)
        let body = try requestBody(await transport.firstRequest())
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? [[String: Any]])
        let imagePart = try #require(userContent.first { $0["type"] as? String == "image_url" })
        let imageURL = try #require((imagePart["image_url"] as? [String: Any])?["url"] as? String)

        #expect(response.imageWasSent)
        #expect(userContent.contains { $0["type"] as? String == "text" && $0["text"] as? String == "Describe it" })
        #expect(imageURL == "data:image/png;base64,iVBORw==")
    }

    @Test func openAIResponsesEndpointUsesResponsesWireFormat() async throws {
        let payload = Data("""
        {"output":[{"content":[{"type":"output_text","text":"response text"}]}]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1/responses", model: "gpt-test", transport: transport
        )

        let response = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: Data([1, 2]))
        let request = try #require(await transport.firstRequest())
        let body = try requestBody(request)
        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "input_image" })

        #expect(request.url?.path == "/v1/responses")
        #expect(body["instructions"] as? String == "System")
        #expect(content.contains { $0["type"] as? String == "input_text" && $0["text"] as? String == "Question" })
        #expect((image["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(response == .init(text: "response text", imageWasSent: true))
    }

    @Test func geminiRequestUsesGenerateContentEndpointAndInlinePNG() async throws {
        let payload = Data("""
        {"candidates":[{"content":{"parts":[{"text":"gemini text"}]}}]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://generativelanguage.googleapis.com/v1beta", model: "gemini 2.0", transport: transport
        )

        let response = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: Data([1, 2]))
        let request = try #require(await transport.firstRequest())
        let body = try requestBody(request)
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let inlineData = try #require((parts.first { $0["inline_data"] != nil })?["inline_data"] as? [String: Any])

        #expect(request.url?.absoluteString.contains("/v1beta/models/gemini%202.0:generateContent") == true)
        #expect(request.url?.query?.contains("key=test-placeholder-key") == true)
        #expect(inlineData["mime_type"] as? String == "image/png")
        #expect(inlineData["data"] as? String == "AQI=")
        #expect(response == .init(text: "gemini text", imageWasSent: true))
    }

    @Test func responsesPayloadIgnoresNonTextOutputItems() async throws {
        let payload = Data("""
        {"output":[
          {"type":"reasoning","summary":[]},
          {"type":"message","content":[{"type":"output_text","text":"usable text"}]}
        ]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1/responses", model: "gpt-test", transport: transport
        )

        let response = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)

        #expect(response == .init(text: "usable text", imageWasSent: false))
    }

    @Test func modelDiscoveryFiltersUnsupportedGeminiModels() async throws {
        let payload = Data("""
        {"models":[
          {"name":"models/gemini-z","supportedGenerationMethods":["generateContent"]},
          {"name":"models/embed-only","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-a","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-a","supportedGenerationMethods":["generateContent"]}
        ]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-a", transport: transport
        )

        let models = try await client.fetchAvailableModels()
        let request = try #require(await transport.firstRequest())

        #expect(request.url?.path == "/v1beta/models")
        #expect(models == ["gemini-a", "gemini-z"])
    }

    @Test func geminiConcreteGenerateContentEndpointIsNotDuplicatedAndReplacesKey() async throws {
        let payload = Data("""
        {"candidates":[{"content":{"parts":[{"text":"gemini text"}]}}]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent?key=old-key&alt=json",
            model: "ignored-model",
            transport: transport
        )

        _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
        let request = try #require(await transport.firstRequest())
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(request.url?.path == "/v1beta/models/gemini-test:generateContent")
        #expect(queryItems.filter { $0.name == "key" }.map(\.value) == ["test-placeholder-key"])
        #expect(queryItems.first { $0.name == "alt" }?.value == "json")
    }

    @Test func geminiModelDiscoveryEndpointIsNotDuplicatedAndReplacesKey() async throws {
        let payload = Data("""
        {"models":[{"name":"models/gemini-a","supportedGenerationMethods":["generateContent"]}]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: "https://generativelanguage.googleapis.com/v1beta/models?key=old-key&alt=json",
            model: "gemini-a",
            transport: transport
        )

        _ = try await client.fetchAvailableModels()
        let request = try #require(await transport.firstRequest())
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(request.url?.path == "/v1beta/models")
        #expect(queryItems.filter { $0.name == "key" }.map(\.value) == ["test-placeholder-key"])
        #expect(queryItems.first { $0.name == "alt" }?.value == "json")
    }

    @Test func openAIEndpointNormalizationPreservesQueryValuesEndingInSlash() async throws {
        let payload = Data("""
        {"output":[{"content":[{"type":"output_text","text":"response text"}]}]}
        """.utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: "https://example.invalid/v1/responses?path=/",
            model: "gpt-test",
            transport: transport
        )

        _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
        let request = try #require(await transport.firstRequest())
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(request.url?.path == "/v1/responses")
        #expect(components.queryItems?.first { $0.name == "path" }?.value == "/")
    }

    @Test func missingKeyFailsBeforeTransport() async {
        let transport = StubHTTPTransport(stubs: [])
        let client = OpenAIResponsesClient(apiKey: "  ", baseURLString: "https://example.invalid/v1", model: "gpt-test", transport: transport)

        await #expect(throws: OpenAIResponsesClient.ClientError.missingAPIKey) {
            try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func imageCapabilityErrorIsTypedAndDoesNotExposeAPIKey() async {
        let payload = Data("{\"error\":{\"message\":\"Vision unavailable for test-placeholder-key\"}}".utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 400, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1", model: "gpt-test", transport: transport
        )

        do {
            _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: Data([1]))
            Issue.record("Expected imageUnsupported")
        } catch let error as OpenAIResponsesClient.ClientError {
            guard case .imageUnsupported(let message) = error else {
                Issue.record("Expected imageUnsupported, got \(error)")
                return
            }
            #expect(!message.contains("test-placeholder-key"))
            #expect(!(error.errorDescription ?? "").contains("test-placeholder-key"))
        } catch {
            Issue.record("Expected ClientError, got \(error)")
        }
    }

    @Test func malformedSuccessPayloadIsInvalidResponse() async {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: Data("{}".utf8))])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1", model: "gpt-test", transport: transport
        )

        await #expect(throws: OpenAIResponsesClient.ClientError.invalidResponse) {
            try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
        }
    }

    @Test func nonImageHTTPErrorPreservesStatusAndSanitizedMessage() async {
        let payload = Data("{\"error\":{\"message\":\"Rate limit for test-placeholder-key\"}}".utf8)
        let transport = StubHTTPTransport(stubs: [.init(status: 429, data: payload)])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key", baseURLString: "https://example.invalid/v1", model: "gpt-test", transport: transport
        )

        do {
            _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
            Issue.record("Expected http error")
        } catch let error as OpenAIResponsesClient.ClientError {
            guard case .http(let status, let message) = error else {
                Issue.record("Expected http error, got \(error)")
                return
            }
            #expect(status == 429)
            #expect(message.contains("Rate limit"))
            #expect(!message.contains("test-placeholder-key"))
            #expect(!(error.errorDescription ?? "").contains("test-placeholder-key"))
        } catch {
            Issue.record("Expected ClientError, got \(error)")
        }
    }

    @Test func transportFailureDoesNotExposeGeminiRequestSecrets() async {
        let client = OpenAIResponsesClient(
            apiKey: "transport-secret",
            baseURLString: "https://generativelanguage.googleapis.com/v1beta",
            model: "gemini-test",
            transport: ThrowingHTTPTransport()
        )

        do {
            _ = try await client.respond(instructions: "instructions-secret", prompt: "body-secret", screenshotPNGData: nil)
            Issue.record("Expected a sanitized client error")
        } catch let error as OpenAIResponsesClient.ClientError {
            #expect(error == .invalidResponse)
            let description = error.errorDescription ?? ""
            #expect(!description.contains("transport-secret"))
            #expect(!description.localizedCaseInsensitiveContains("authorization"))
            #expect(!description.contains("body-secret"))
        } catch {
            Issue.record("Expected ClientError, got \(error.localizedDescription)")
        }
    }

    @Test func transportClientErrorDoesNotExposeSecrets() async {
        let client = OpenAIResponsesClient(
            apiKey: "transport-secret",
            baseURLString: "https://example.invalid/v1",
            model: "gpt-test",
            transport: ClientErrorThrowingHTTPTransport()
        )

        do {
            _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
            Issue.record("Expected a sanitized client error")
        } catch let error as OpenAIResponsesClient.ClientError {
            #expect(error == .invalidResponse)
            let description = error.errorDescription ?? ""
            #expect(!description.contains("transport-secret"))
            #expect(!description.localizedCaseInsensitiveContains("authorization"))
        } catch {
            Issue.record("Expected ClientError, got \(error.localizedDescription)")
        }
    }

    @Test func openAIEndpointNormalizationPreservesEncodedPathSegments() async throws {
        let transport = StubHTTPTransport(stubs: [.init(status: 200, data: chatResponse("hello"))])
        let client = OpenAIResponsesClient(
            apiKey: "test-placeholder-key",
            baseURLString: "https://example.invalid/proxy%2Ftenant/v1/chat/completions",
            model: "gpt-test",
            transport: transport
        )

        _ = try await client.respond(instructions: "System", prompt: "Question", screenshotPNGData: nil)
        let request = try #require(await transport.firstRequest())

        #expect(request.url?.absoluteString.localizedCaseInsensitiveContains("/proxy%2Ftenant/v1/chat/completions") == true)
    }

    private func chatResponse(_ text: String) -> Data {
        Data("{\"choices\":[{\"message\":{\"content\":\"\(text)\"}}]}".utf8)
    }

    private func requestBody(_ request: URLRequest?) throws -> [String: Any] {
        let request = try #require(request)
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor StubHTTPTransport: HTTPTransport {
    struct Stub: Sendable {
        let status: Int
        let data: Data
    }

    enum StubError: Error { case exhausted }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
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

private actor ThrowingHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw URLLeakingTransportError("\(request.url?.absoluteString ?? "") Authorization: \(request.value(forHTTPHeaderField: "Authorization") ?? "") \(body)")
    }
}

private actor ClientErrorThrowingHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw OpenAIResponsesClient.ClientError.http(status: 400, message: "Authorization: Bearer transport-secret")
    }
}

private struct URLLeakingTransportError: Error, LocalizedError {
    let details: String

    init(_ details: String) {
        self.details = details
    }

    var errorDescription: String? { details }
}
