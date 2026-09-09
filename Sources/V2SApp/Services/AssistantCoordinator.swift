import Combine
import Foundation

protocol AssistantResponding: Sendable {
    func validateRequestConfiguration(settings: AssistantSettings) throws
    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String]
    func testConnection(settings: AssistantSettings) async throws -> String
    func respond(
        settings: AssistantSettings,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> OpenAIResponsesClient.Response
}

protocol AssistantScreenContextProviding: Sendable {
    func current() async -> ScreenContext
}

protocol AssistantPromptBuilding: Sendable {
    func build(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        currentTime: Date,
        hasScreenshot: Bool,
        ocrText: String?
    ) async throws -> AssistantPrompt
}

struct OpenAIResponsesAssistantResponder: AssistantResponding {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    func validateRequestConfiguration(settings: AssistantSettings) throws {
        try client(for: settings).validateRequestConfiguration()
    }

    func fetchAvailableModels(settings: AssistantSettings) async throws -> [String] {
        try await client(for: settings).fetchAvailableModels()
    }

    func testConnection(settings: AssistantSettings) async throws -> String {
        try await client(for: settings).testConnection()
    }

    func respond(
        settings: AssistantSettings,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> OpenAIResponsesClient.Response {
        try await client(for: settings).respond(
            instructions: instructions,
            prompt: prompt,
            screenshotPNGData: screenshotPNGData
        )
    }

    private func client(for settings: AssistantSettings) -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            apiKey: settings.apiKey,
            baseURLString: settings.baseURL,
            model: settings.model,
            transport: transport
        )
    }
}

extension ScreenContextProvider: AssistantScreenContextProviding {}

struct AssistantPromptBuilderAdapter: AssistantPromptBuilding {
    private let builder: AssistantPromptBuilder

    init(builder: AssistantPromptBuilder = AssistantPromptBuilder()) {
        self.builder = builder
    }

    func build(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        currentTime: Date,
        hasScreenshot: Bool,
        ocrText: String?
    ) async throws -> AssistantPrompt {
        builder.build(
            action: action,
            snapshot: snapshot,
            settings: settings,
            currentTime: currentTime,
            hasScreenshot: hasScreenshot,
            ocrText: ocrText
        )
    }
}

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published var settings: AssistantSettings
    @Published private(set) var requestState: AssistantRequestState = .idle
    @Published private(set) var modelFetchState: AssistantModelFetchState = .idle
    @Published private(set) var apiTestState: AssistantAPITestState = .idle
    @Published private(set) var replies: [AssistantReply] = []
    @Published private(set) var screenStatus: ScreenContextStatus = .unknown
    @Published var overlayMode: OverlayViewMode = .subtitles
    @Published private(set) var replyScrollOffset = 0
    @Published private(set) var replyVisibleCount = 0

    private let responder: any AssistantResponding
    private let screenContextProvider: any AssistantScreenContextProviding
    private let promptBuilder: any AssistantPromptBuilding
    private var requestTask: Task<Void, Never>?
    private var modelFetchTask: Task<Void, Never>?
    private var apiTestTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var modelFetchGeneration = 0
    private var apiTestGeneration = 0
    private var pendingReplyID: UUID?

    init(
        settings: AssistantSettings = .default,
        responder: any AssistantResponding = OpenAIResponsesAssistantResponder(),
        screenContextProvider: any AssistantScreenContextProviding = ScreenContextProvider(
            capture: SystemScreenCapturer(),
            recognizer: VisionTextRecognizer()
        ),
        promptBuilder: any AssistantPromptBuilding = AssistantPromptBuilderAdapter()
    ) {
        self.settings = settings
        self.responder = responder
        self.screenContextProvider = screenContextProvider
        self.promptBuilder = promptBuilder
    }

    func request(_ action: AssistantAction, snapshot: AssistantTranscriptSnapshot) {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        removePendingReply()
        screenStatus = .unknown

        do {
            try responder.validateRequestConfiguration(settings: settings)
        } catch {
            let message = userFacingMessage(for: error)
            requestState = .failed(message)
            appendReply(action: action, text: message)
            return
        }
        requestState = .running(action)
        let generation = requestGeneration
        let requestSettings = settings
        requestTask = Task { [weak self] in
            await self?.performRequest(
                action: action,
                snapshot: snapshot,
                settings: requestSettings,
                generation: generation
            )
        }
    }

    func cancelRequest() {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
        removePendingReply()
        requestState = .idle
        clampReplyScrollOffset()
    }

    func fetchModels() {
        modelFetchGeneration &+= 1
        modelFetchTask?.cancel()
        let generation = modelFetchGeneration
        let requestSettings = settings
        modelFetchState = .fetching

        modelFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await self.responder.fetchAvailableModels(settings: requestSettings)
                guard self.modelFetchGeneration == generation else { return }
                self.modelFetchState = .fetched(models)
                self.modelFetchTask = nil
            } catch {
                guard self.modelFetchGeneration == generation else { return }
                self.modelFetchState = .failed(self.userFacingMessage(for: error))
                self.modelFetchTask = nil
            }
        }
    }

    func testAPI() {
        apiTestGeneration &+= 1
        apiTestTask?.cancel()
        let generation = apiTestGeneration
        let requestSettings = settings
        apiTestState = .testing

        apiTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.responder.testConnection(settings: requestSettings)
                guard self.apiTestGeneration == generation else { return }
                self.apiTestState = .passed(String(response.prefix(80)))
                self.apiTestTask = nil
            } catch {
                guard self.apiTestGeneration == generation else { return }
                self.apiTestState = .failed(self.userFacingMessage(for: error))
                self.apiTestTask = nil
            }
        }
    }

    func toggleOverlayMode() {
        overlayMode = overlayMode == .subtitles ? .assistantReplies : .subtitles
    }

    func scrollReplies(by delta: Int) {
        guard delta != 0 else { return }
        setReplyScrollOffset(replyScrollOffset + delta)
    }

    func setReplyScrollOffset(_ value: Int) {
        replyScrollOffset = min(max(0, value), maximumReplyScrollOffset)
    }

    func updateReplyVisibleCount(_ count: Int) {
        replyVisibleCount = max(0, count)
        clampReplyScrollOffset()
    }

    private func performRequest(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        generation: Int
    ) async {
        let screenContext = await screenContextProvider.current()
        guard isCurrentRequest(generation) else { return }
        screenStatus = screenContext.status

        let prompt: AssistantPrompt
        let currentTime = Date()
        do {
            prompt = try await promptBuilder.build(
                action: action,
                snapshot: snapshot,
                settings: settings,
                currentTime: currentTime,
                hasScreenshot: screenContext.pngData != nil,
                ocrText: screenContext.ocrText
            )
        } catch {
            finishRequestFailure(error, action: action, generation: generation)
            return
        }
        guard isCurrentRequest(generation) else { return }

        let replyID = appendThinkingReply(action: action)
        guard isCurrentRequest(generation) else { return }

        do {
            let response = try await responder.respond(
                settings: settings,
                instructions: prompt.instructions,
                prompt: prompt.userContent,
                screenshotPNGData: screenContext.pngData
            )
            finishRequestSuccess(response, action: action, replyID: replyID, generation: generation)
        } catch let error as OpenAIResponsesClient.ClientError {
            guard isCurrentRequest(generation) else { return }
            guard case .imageUnsupported = error, screenContext.pngData != nil else {
                finishRequestFailure(error, action: action, generation: generation)
                return
            }

            screenStatus = .providerRejectedImage
            let fallbackPrompt: AssistantPrompt
            do {
                fallbackPrompt = try await promptBuilder.build(
                    action: action,
                    snapshot: snapshot,
                    settings: settings,
                    currentTime: currentTime,
                    hasScreenshot: false,
                    ocrText: screenContext.ocrText
                )
            } catch {
                finishRequestFailure(error, action: action, generation: generation)
                return
            }
            guard isCurrentRequest(generation) else { return }
            do {
                let response = try await responder.respond(
                    settings: settings,
                    instructions: fallbackPrompt.instructions,
                    prompt: fallbackPrompt.userContent,
                    screenshotPNGData: nil
                )
                finishRequestSuccess(response, action: action, replyID: replyID, generation: generation)
            } catch {
                finishRequestFailure(error, action: action, generation: generation)
            }
        } catch {
            finishRequestFailure(error, action: action, generation: generation)
        }
    }

    private func finishRequestSuccess(
        _ response: OpenAIResponsesClient.Response,
        action: AssistantAction,
        replyID: UUID,
        generation: Int
    ) {
        guard isCurrentRequest(generation) else { return }
        if response.imageWasSent, screenStatus.isWarning == false {
            screenStatus = .screenshotSent
        }
        replacePendingReply(id: replyID, action: action, text: response.text)
        pendingReplyID = nil
        requestState = .idle
        requestTask = nil
        clampReplyScrollOffset()
    }

    private func finishRequestFailure(_ error: Error, action: AssistantAction, generation: Int) {
        guard isCurrentRequest(generation) else { return }
        let message = userFacingMessage(for: error)
        if let pendingReplyID {
            replacePendingReply(id: pendingReplyID, action: action, text: message)
            self.pendingReplyID = nil
        } else {
            appendReply(action: action, text: message)
        }
        requestState = .failed(message)
        requestTask = nil
        clampReplyScrollOffset()
    }

    private func appendThinkingReply(action: AssistantAction) -> UUID {
        let id = UUID()
        pendingReplyID = id
        appendReply(id: id, action: action, text: "Thinking…")
        return id
    }

    private func appendReply(action: AssistantAction, text: String) {
        appendReply(id: UUID(), action: action, text: text)
    }

    private func appendReply(id: UUID, action: AssistantAction, text: String) {
        replies.append(AssistantReply(id: id, action: action, title: title(for: action), text: text))
        overlayMode = .assistantReplies
        clampReplyScrollOffset()
    }

    private func replacePendingReply(id: UUID, action: AssistantAction, text: String) {
        let reply = AssistantReply(id: id, action: action, title: title(for: action), text: text)
        if let index = replies.firstIndex(where: { $0.id == id }) {
            replies[index] = reply
        } else {
            replies.append(reply)
        }
        overlayMode = .assistantReplies
    }

    private func removePendingReply() {
        guard let pendingReplyID else { return }
        replies.removeAll { $0.id == pendingReplyID }
        self.pendingReplyID = nil
        clampReplyScrollOffset()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let clientError = error as? OpenAIResponsesClient.ClientError {
            return clientError.errorDescription ?? "Assistant request failed."
        }
        return "Assistant request failed."
    }

    private func title(for action: AssistantAction) -> String {
        switch action {
        case .followUp: "Follow Up"
        case .ask: "Ask"
        }
    }

    private var maximumReplyScrollOffset: Int {
        max(0, replies.count - max(0, replyVisibleCount))
    }

    private func clampReplyScrollOffset() {
        replyScrollOffset = min(max(0, replyScrollOffset), maximumReplyScrollOffset)
    }

    private func isCurrentRequest(_ generation: Int) -> Bool {
        requestGeneration == generation
    }
}
