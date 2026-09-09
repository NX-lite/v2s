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
        #expect(coordinator.replies[0].text == "Thinking…")
        #expect(coordinator.screenStatus == .ready)

        await responder.releaseHeldResponse(text: "Use the deployment checklist.")
        await waitUntil {
            coordinator.requestState == .idle
                && coordinator.replies.map(\.text) == ["Use the deployment checklist."]
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
                && coordinator.replies.map(\.text) == ["Second answer"]
        }

        await responder.releaseHeldResponse(text: "Stale first answer")
        await drainTasks()

        #expect(coordinator.replies.map(\.text) == ["Second answer"])
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
                && coordinator.replies.map(\.text) == ["Text-only answer"]
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
        #expect(coordinator.replies.map(\.text) == ["Assistant request failed."])
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
                && coordinator.replies.map(\.text) == ["Current answer"]
        }

        await responder.releaseHeldResponse(text: "Stale fallback answer")
        await drainTasks()

        #expect(coordinator.replies.map(\.text) == ["Current answer"])
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
        #expect(coordinator.replies.map(\.text) == ["Assistant request failed."])
        #expect(coordinator.screenStatus == .ready)
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
                && coordinator.replies.map(\.text) == ["Text-only answer"]
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
                && coordinator.replies.map(\.text) == ["Image answer"]
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
        await waitUntil { coordinator.replies.map(\.text) == ["First"] && coordinator.requestState == .idle }

        coordinator.request(.followUp, snapshot: sampleSnapshot())
        await waitUntil { coordinator.replies.map(\.text) == ["First", "Second"] && coordinator.requestState == .idle }

        coordinator.setReplyScrollOffset(999)
        #expect(coordinator.replyScrollOffset == 1)

        coordinator.updateReplyVisibleCount(2)
        #expect(coordinator.replyScrollOffset == 0)

        coordinator.scrollReplies(by: -100)
        #expect(coordinator.replyScrollOffset == 0)
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

        if case .failed = coordinator.requestState {
            // Expected: configuration fails synchronously before capture starts.
        } else {
            Issue.record("Expected a missing-configuration failure")
        }
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

        if case .failed = coordinator.requestState {
            // Expected: invalid endpoints are rejected before screen capture starts.
        } else {
            Issue.record("Expected an invalid-endpoint failure")
        }
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
    }

    @Test func emptyTranscriptFailsBeforeScreenCapture() async {
        let responder = ResponderFake(steps: [.response("unused")])
        let screen = ScreenContextFake(contexts: [readyScreenContext()])
        let coordinator = makeCoordinator(responder: responder, screen: screen)

        coordinator.request(.ask, snapshot: emptySnapshot())
        await drainTasks()

        if case .failed = coordinator.requestState {
            // Expected: empty transcript context is rejected before screen capture starts.
        } else {
            Issue.record("Expected an empty-transcript failure")
        }
        #expect(await screen.callCount() == 0)
        #expect(await responder.callCount() == 0)
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
    private var images: [Data?] = []
    private var receivedPrompts: [String] = []
    private var heldContinuations: [CheckedContinuation<OpenAIResponsesClient.Response, Error>] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String] {
        ["gpt-test"]
    }

    func testConnection(settings: AssistantSettings) async throws -> String {
        "OK"
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
        case failure
        case held
    }

    enum ResponderFailure: Error, Sendable {
        case failed
    }
}
