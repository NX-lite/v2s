import Foundation
import Testing
@testable import v2s

@MainActor
@Suite struct AssistantCoordinatorTests {
    @Test func requestPublishesThinkingThenReplyAndSwitchesMode() async {
        let responder = ResponderFake(steps: [.held])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [.init(pngData: Data([0x01]), ocrText: "Screen text", status: .ready)])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitForCalls(responder, expected: 1)

        #expect(coordinator.requestState == .running(.ask))
        #expect(coordinator.overlayMode == .assistantReplies)
        #expect(coordinator.replies.count == 1)
        #expect(coordinator.replies[0].action == .ask)
        #expect(coordinator.replies[0].content == .thinking)
        #expect(coordinator.screenStatus == .ready)

        await responder.releaseHeldResponse(text: "Use the deployment checklist.")
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Use the deployment checklist.")]
        }

        #expect(coordinator.overlayMode == .assistantReplies)
        #expect(coordinator.screenStatus == .screenshotSent)
    }

    @Test func secondRequestCancelsFirstAndIgnoresItsLateResponse() async {
        let responder = ResponderFake(steps: [.held, .response("Second answer")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [readyScreenContext(), readyScreenContext()])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitForCalls(responder, expected: 1)

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Second answer")]
        }

        await responder.releaseHeldResponse(text: "Stale first answer")
        await drainTasks()

        #expect(coordinator.replies.map(\.content) == [.response("Second answer")])
        #expect(coordinator.replies.map(\.action) == [.followUp])
        #expect(coordinator.requestState == .idle)
    }

    @Test func imageUnsupportedRetriesExactlyOnceWithoutImage() async {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let responder = ResponderFake(steps: [.imageUnsupported, .response("Text-only answer")])
        let promptBuilder = PromptBuilderFake()
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [.init(pngData: image, ocrText: "OCR", status: .ready)]),
            promptBuilder: promptBuilder
        )

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Text-only answer")]
        }

        #expect(await responder.screenshotArguments() == [image, nil])
        #expect(await responder.prompts() == ["Image prompt with OCR", "Text-only prompt with OCR"])
        #expect(await promptBuilder.calls() == [
            .init(hasScreenshot: true, ocrText: "OCR"),
            .init(hasScreenshot: false, ocrText: "OCR"),
        ])
        #expect(coordinator.screenStatus == .providerRejectedImage)
    }

    @Test func imageFallbackPromptFailurePublishesOneFailureWithoutRetry() async {
        let responder = ResponderFake(steps: [.imageUnsupported, .response("unused")])
        let promptBuilder = PromptBuilderFake(steps: [.prompt, .failure])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [.init(pngData: Data([0x01]), ocrText: "OCR", status: .ready)]),
            promptBuilder: promptBuilder
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil {
            if case .failed = coordinator.requestState { return true }
            return false
        }

        #expect(await responder.callCount() == 1)
        #expect(coordinator.replies.map(\.content) == [.failure(.requestFailed(detail: nil))])
        #expect(coordinator.screenStatus == .providerRejectedImage)
    }

    @Test func secondRequestCancelsImageFallbackAndIgnoresItsLateResponse() async {
        let responder = ResponderFake(steps: [.imageUnsupported, .held, .response("Current answer")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [readyScreenContext(), readyScreenContext()])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitForCalls(responder, expected: 2)

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Current answer")]
        }

        await responder.releaseHeldResponse(text: "Stale fallback answer")
        await drainTasks()

        #expect(coordinator.replies.map(\.content) == [.response("Current answer")])
        #expect(coordinator.screenStatus == .screenshotSent)
    }

    @Test func nonImageFailureDoesNotRetry() async {
        let responder = ResponderFake(steps: [.failure])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [readyScreenContext()])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil {
            if case .failed = coordinator.requestState { return true }
            return false
        }

        #expect(await responder.callCount() == 1)
        #expect(coordinator.requestState == .failed(.requestFailed(detail: nil)))
        #expect(coordinator.replies.map(\.content) == [.failure(.requestFailed(detail: nil))])
        #expect(coordinator.screenStatus == .ready)
    }

    @Test func typedClientFailureKeepsSanitizedDetailInSemanticFailure() async {
        let responder = ResponderFake(steps: [.clientFailure(.http(status: 503, message: "Provider temporarily unavailable"))])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [readyScreenContext()])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .failed(.requestFailed(detail: "HTTP 503: Provider temporarily unavailable"))
        }

        guard case .failed(.requestFailed(let detail)) = coordinator.requestState else {
            Issue.record("Expected a request failure with provider detail")
            return
        }
        #expect(detail == "HTTP 503: Provider temporarily unavailable")
        #expect(detail?.contains(configuredSettings().apiKey) == false)
        #expect(coordinator.replies.map(\.content) == [.failure(.requestFailed(detail: detail))])
    }

    @Test func modelFetchFailureUsesSemanticFailure() async {
        let responder = ResponderFake(steps: [], shouldFailModelFetch: true)
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [])
        )

        coordinator.fetchModels()
        await waitUntil {
            coordinator.modelFetchState == .failed(.requestFailed(detail: nil))
        }

        #expect(coordinator.modelFetchState == .failed(.requestFailed(detail: nil)))
    }

    @Test func apiTestFailureUsesSemanticFailure() async {
        let responder = ResponderFake(steps: [], shouldFailAPITest: true)
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [])
        )

        coordinator.testAPI()
        await waitUntil {
            coordinator.apiTestState == .failed(.requestFailed(detail: nil))
        }

        #expect(coordinator.apiTestState == .failed(.requestFailed(detail: nil)))
    }

    @Test func providerConfigurationChangeDiscardsStaleSuccessfulOperationResults() async {
        let responder = ProviderOperationResponderFake()
        let coordinator = AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: ScreenContextFake(contexts: []),
            promptBuilder: PromptBuilderFake()
        )

        coordinator.fetchModels()
        coordinator.testAPI()
        await waitForProviderOperations(responder)

        var updatedSettings = coordinator.settings
        updatedSettings.model = "gpt-current"
        coordinator.settings = updatedSettings

        await responder.releaseModelFetchSuccess(["stale-model"])
        await responder.releaseAPITestSuccess("stale connection")
        await drainTasks()

        #expect(coordinator.modelFetchState == .idle)
        #expect(coordinator.apiTestState == .idle)
    }

    @Test func providerConfigurationChangeDiscardsStaleFailedOperationResults() async {
        let responder = ProviderOperationResponderFake()
        let coordinator = AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: ScreenContextFake(contexts: []),
            promptBuilder: PromptBuilderFake()
        )

        coordinator.fetchModels()
        coordinator.testAPI()
        await waitForProviderOperations(responder)

        var updatedSettings = coordinator.settings
        updatedSettings.baseURL = "https://new-provider.invalid/v1"
        coordinator.settings = updatedSettings

        await responder.releaseModelFetchFailure()
        await responder.releaseAPITestFailure()
        await drainTasks()

        #expect(coordinator.modelFetchState == .idle)
        #expect(coordinator.apiTestState == .idle)
    }

    @Test func skillsAndHotKeyChangesDoNotInvalidateProviderOperations() async {
        let responder = ProviderOperationResponderFake()
        let coordinator = AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: ScreenContextFake(contexts: []),
            promptBuilder: PromptBuilderFake()
        )

        coordinator.fetchModels()
        coordinator.testAPI()
        await waitForProviderOperations(responder)

        var updatedSettings = coordinator.settings
        updatedSettings.skills = "Prefer short answers."
        updatedSettings.followUpHotKey.useShift = true
        coordinator.settings = updatedSettings

        await responder.releaseModelFetchSuccess(["current-model"])
        await responder.releaseAPITestSuccess("current connection")
        await waitUntil {
            coordinator.modelFetchState == .fetched(["current-model"])
                && coordinator.apiTestState == .passed("current connection")
        }

        #expect(coordinator.modelFetchState == .fetched(["current-model"]))
        #expect(coordinator.apiTestState == .passed("current connection"))
    }

    @Test func permissionDenialContinuesTextOnlyAndPublishesWarning() async {
        let responder = ResponderFake(steps: [.response("Text-only answer")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [.init(pngData: nil, ocrText: nil, status: .permissionNeeded)])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Text-only answer")]
        }

        #expect(await responder.screenshotArguments() == [nil])
        #expect(coordinator.screenStatus == .permissionNeeded)
        #expect(coordinator.screenStatus.isWarning)
    }

    @Test func OCRFailureRemainsWarningAfterSuccessfulImageResponse() async {
        let responder = ResponderFake(steps: [.response("Image answer")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [.init(pngData: Data([0x01]), ocrText: nil, status: .ocrFailed)])
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Image answer")]
        }

        #expect(coordinator.screenStatus == .ocrFailed)
        #expect(coordinator.screenStatus.isWarning)
    }

    @Test func replyScrollOffsetClampsAfterHistoryChanges() async {
        let responder = ResponderFake(steps: [.response("First"), .response("Second")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [readyScreenContext(), readyScreenContext()])
        )
        coordinator.updateReplyVisibleCount(1)

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil { coordinator.replies.map(\.content) == [.response("First")] && coordinator.requestState == .idle }

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil { coordinator.replies.map(\.content) == [.response("First"), .response("Second")] && coordinator.requestState == .idle }

        coordinator.setReplyScrollOffset(999)
        #expect(coordinator.replyScrollOffset == 1)

        coordinator.updateReplyVisibleCount(2)
        #expect(coordinator.replyScrollOffset == 0)

        coordinator.scrollReplies(by: -100)
        #expect(coordinator.replyScrollOffset == 0)
    }

    @Test func resetForNewSessionClearsReplyPresentationState() async {
        let responder = ResponderFake(steps: [.response("First"), .response("Second")])
        let coordinator = makeCoordinator(
            responder: responder,
            screen: ScreenContextFake(contexts: [
                .init(pngData: nil, ocrText: nil, status: .permissionNeeded),
                .init(pngData: nil, ocrText: nil, status: .permissionNeeded),
            ])
        )
        coordinator.updateReplyVisibleCount(1)

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await waitUntil { coordinator.replies.map(\.content) == [.response("First")] }

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil { coordinator.replies.map(\.content) == [.response("First"), .response("Second")] }
        coordinator.setReplyScrollOffset(1)

        #expect(coordinator.overlayMode == .assistantReplies)
        #expect(coordinator.screenStatus == .permissionNeeded)
        #expect(coordinator.replyScrollOffset == 1)

        coordinator.resetForNewSession()

        #expect(coordinator.replies.isEmpty)
        #expect(coordinator.requestState == .idle)
        #expect(coordinator.screenStatus == .unknown)
        #expect(coordinator.replyScrollOffset == 0)
        #expect(coordinator.replyVisibleCount == 0)
        #expect(coordinator.overlayMode == .subtitles)
    }

    @Test func missingConfigurationFailsBeforeScreenCapture() async {
        var settings = configuredSettings()
        settings.apiKey = " \n "
        let responder = ResponderFake(steps: [.response("unused")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = AssistantCoordinator(
            settings: settings,
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: PromptBuilderFake()
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())

        #expect(coordinator.requestState == .failed(.invalidConfiguration))
        #expect(coordinator.replies.map(\.content) == [.failure(.invalidConfiguration)])
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
    }

    @Test func invalidEndpointFailsBeforeScreenCapture() async {
        var settings = configuredSettings()
        settings.baseURL = "ftp://example.invalid/v1"
        let responder = ResponderFake(steps: [.response("unused")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = AssistantCoordinator(
            settings: settings,
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: PromptBuilderFake()
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())
        await drainTasks()

        #expect(coordinator.requestState == .failed(.invalidConfiguration))
        #expect(coordinator.replies.map(\.content) == [.failure(.invalidConfiguration)])
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
    }

    @Test func newlineModelFailsBeforeScreenCapture() async {
        var settings = configuredSettings()
        settings.model = "gpt-test\nmalicious"
        let responder = ResponderFake(steps: [.response("unused")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = AssistantCoordinator(
            settings: settings,
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: PromptBuilderFake()
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())

        #expect(coordinator.requestState == .failed(.invalidConfiguration))
        #expect(coordinator.replies.map(\.content) == [.failure(.invalidConfiguration)])
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
    }

    @Test func newlineAPIKeyFailsBeforeScreenCapture() async {
        var settings = configuredSettings()
        settings.apiKey = "header-secret\r\nX-Injected: true"
        let responder = ResponderFake(steps: [.response("unused")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = AssistantCoordinator(
            settings: settings,
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: PromptBuilderFake()
        )

        coordinator.request(.ask, snapshot: sampleSnapshot())

        #expect(coordinator.requestState == .failed(.invalidConfiguration))
        #expect(coordinator.replies.map(\.content) == [.failure(.invalidConfiguration)])
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
    }

    @Test func emptyTranscriptStillCapturesAndRequests() async {
        let responder = ResponderFake(steps: [.response("Empty-context answer")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: AssistantPromptBuilderAdapter()
        )

        coordinator.request(.ask, snapshot: emptySnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Empty-context answer")]
        }

        #expect(await screen.callCount() == 1)
        #expect(await responder.callCount() == 1)
        #expect(await responder.prompts().first?.contains("(No transcript yet.)") == true)
        #expect(await responder.screenshotArguments() == [Data([0x01])])
    }

    @Test func emptyTranscriptPermissionDenialStillSendsTextOnlyRequest() async {
        let responder = ResponderFake(steps: [.response("Text-only empty-context answer")])
        let screen = ScreenContextFake(contexts: [.init(pngData: nil, ocrText: nil, status: .permissionNeeded)])
        let coordinator = AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: AssistantPromptBuilderAdapter()
        )

        coordinator.request(.followUp, snapshot: emptySnapshot())
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.content) == [.response("Text-only empty-context answer")]
        }

        #expect(await screen.callCount() == 1)
        #expect(await responder.screenshotArguments() == [nil])
        #expect(await responder.prompts().first?.contains("(No transcript yet.)") == true)
        #expect(coordinator.screenStatus == .permissionNeeded)
    }

    private func makeCoordinator(
        responder: ResponderFake,
        screen: ScreenContextFake,
        promptBuilder: PromptBuilderFake = PromptBuilderFake()
    ) -> AssistantCoordinator {
        AssistantCoordinator(
            settings: configuredSettings(),
            responder: responder,
            screenContextProvider: screen,
            promptBuilder: promptBuilder
        )
    }

    private func configuredSettings() -> AssistantSettings {
        var settings = AssistantSettings.default
        settings.apiKey = "test-placeholder-key"
        settings.baseURL = "https://example.invalid/v1"
        settings.model = "gpt-test"
        return settings
    }

    private func sampleSnapshot() -> AssistantTranscriptSnapshot {
        AssistantTranscriptSnapshot(
            sourceName: "Planning meeting",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [
                .init(timestamp: Date(timeIntervalSince1970: 60), sourceText: "What should we ship?", translatedText: "我们应该发布什么？"),
            ]
        )
    }

    private func readyScreenContext() -> ScreenContext {
        .init(pngData: Data([0x01]), ocrText: "Screen text", status: .ready)
    }

    private func emptySnapshot() -> AssistantTranscriptSnapshot {
        AssistantTranscriptSnapshot(
            sourceName: "Planning meeting",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [.init(timestamp: .distantPast, sourceText: " \n ", translatedText: "\t")]
        )
    }

    private func waitForCalls(_ responder: ResponderFake, expected: Int) async {
        for _ in 0..<200 {
            if await responder.callCount() == expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for responder call \(expected)")
    }

    private func waitForProviderOperations(_ responder: ProviderOperationResponderFake) async {
        for _ in 0..<200 {
            if await responder.modelFetchCallCount() == 1, await responder.apiTestCallCount() == 1 {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for provider operations")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for coordinator state")
    }

    private func drainTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private actor ScreenContextFake: AssistantScreenContextProviding {
    private var contexts: [ScreenContext]
    private var index = 0
    private var calls = 0

    init(contexts: [ScreenContext]) {
        self.contexts = contexts
    }

    func current() async -> ScreenContext {
        calls += 1
        guard contexts.isEmpty == false else {
            return .init(pngData: nil, ocrText: nil, status: .captureFailed)
        }
        defer { index += 1 }
        return contexts[min(index, contexts.count - 1)]
    }

    func callCount() -> Int { calls }
}

private actor PromptBuilderFake: AssistantPromptBuilding {
    private var steps: [Step]
    private var recordedCalls: [Call] = []

    init(steps: [Step] = []) {
        self.steps = steps
    }

    func build(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        currentTime: Date,
        hasScreenshot: Bool,
        ocrText: String?
    ) async throws -> AssistantPrompt {
        recordedCalls.append(.init(hasScreenshot: hasScreenshot, ocrText: ocrText))
        let step = steps.isEmpty ? .prompt : steps.removeFirst()
        switch step {
        case .prompt:
            return .init(
                instructions: "Test instructions",
                userContent: hasScreenshot ? "Image prompt with \(ocrText ?? "no OCR")" : "Text-only prompt with \(ocrText ?? "no OCR")"
            )
        case .failure:
            throw BuildFailure.failed
        }
    }

    func calls() -> [Call] { recordedCalls }

    struct Call: Equatable, Sendable {
        let hasScreenshot: Bool
        let ocrText: String?
    }

    enum Step: Sendable {
        case prompt
        case failure
    }

    enum BuildFailure: Error, Sendable {
        case failed
    }
}

private actor ResponderFake: AssistantResponding {
    private var steps: [Step]
    private let shouldFailModelFetch: Bool
    private let shouldFailAPITest: Bool
    private var images: [Data?] = []
    private var receivedPrompts: [String] = []
    private var heldContinuations: [CheckedContinuation<OpenAIResponsesClient.Response, Error>] = []

    init(steps: [Step], shouldFailModelFetch: Bool = false, shouldFailAPITest: Bool = false) {
        self.steps = steps
        self.shouldFailModelFetch = shouldFailModelFetch
        self.shouldFailAPITest = shouldFailAPITest
    }

    nonisolated func validateRequestConfiguration(settings: AssistantSettings) throws {
        try OpenAIResponsesClient(
            apiKey: settings.apiKey,
            baseURLString: settings.baseURL,
            model: settings.model
        ).validateRequestConfiguration()
    }

    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String] {
        if shouldFailModelFetch { throw ResponderFailure.failed }
        return ["gpt-test"]
    }

    func testConnection(settings: AssistantSettings) async throws -> String {
        if shouldFailAPITest { throw ResponderFailure.failed }
        return "OK"
    }

    func respond(
        settings: AssistantSettings,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> OpenAIResponsesClient.Response {
        images.append(screenshotPNGData)
        receivedPrompts.append(prompt)
        let step = steps.isEmpty ? .failure : steps.removeFirst()
        switch step {
        case .response(let text):
            return .init(text: text, imageWasSent: screenshotPNGData != nil)
        case .imageUnsupported:
            throw OpenAIResponsesClient.ClientError.imageUnsupported(message: "Vision is unavailable")
        case .clientFailure(let error):
            throw error
        case .failure:
            throw ResponderFailure.failed
        case .held:
            return try await withCheckedThrowingContinuation { continuation in
                heldContinuations.append(continuation)
            }
        }
    }

    func releaseHeldResponse(text: String) {
        guard heldContinuations.isEmpty == false else { return }
        let continuation = heldContinuations.removeFirst()
        continuation.resume(returning: .init(text: text, imageWasSent: true))
    }

    func callCount() -> Int { images.count }
    func screenshotArguments() -> [Data?] { images }
    func prompts() -> [String] { receivedPrompts }

    enum Step: Sendable {
        case response(String)
        case imageUnsupported
        case clientFailure(OpenAIResponsesClient.ClientError)
        case failure
        case held
    }

    enum ResponderFailure: Error, Sendable {
        case failed
    }
}

private actor ProviderOperationResponderFake: AssistantResponding {
    private var modelFetchCalls = 0
    private var apiTestCalls = 0
    private var modelFetchContinuation: CheckedContinuation<[String], Error>?
    private var apiTestContinuation: CheckedContinuation<String, Error>?

    nonisolated func validateRequestConfiguration(settings: AssistantSettings) throws {}

    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String] {
        modelFetchCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            modelFetchContinuation = continuation
        }
    }

    func testConnection(settings: AssistantSettings) async throws -> String {
        apiTestCalls += 1
        return try await withCheckedThrowingContinuation { continuation in
            apiTestContinuation = continuation
        }
    }

    func respond(
        settings: AssistantSettings,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> OpenAIResponsesClient.Response {
        throw OperationFailure.failed
    }

    func releaseModelFetchSuccess(_ models: [String]) {
        modelFetchContinuation?.resume(returning: models)
        modelFetchContinuation = nil
    }

    func releaseModelFetchFailure() {
        modelFetchContinuation?.resume(throwing: OperationFailure.failed)
        modelFetchContinuation = nil
    }

    func releaseAPITestSuccess(_ response: String) {
        apiTestContinuation?.resume(returning: response)
        apiTestContinuation = nil
    }

    func releaseAPITestFailure() {
        apiTestContinuation?.resume(throwing: OperationFailure.failed)
        apiTestContinuation = nil
    }

    func modelFetchCallCount() -> Int { modelFetchCalls }
    func apiTestCallCount() -> Int { apiTestCalls }

    private enum OperationFailure: Error, Sendable {
        case failed
    }
}
