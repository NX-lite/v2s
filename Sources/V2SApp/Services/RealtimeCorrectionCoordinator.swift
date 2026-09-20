import Combine
import Foundation

protocol CorrectionResponding: Sendable {
    func validate(settings: CorrectionSettings) throws
    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String]
    func testConnection(settings: CorrectionSettings) async throws -> String
    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput
}

struct OpenAICorrectionResponder: CorrectionResponding {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    func validate(settings: CorrectionSettings) throws {
        try client(for: settings).validateRequestConfiguration()
    }

    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String] {
        try await client(for: settings).fetchAvailableModels()
    }

    func testConnection(settings: CorrectionSettings) async throws -> String {
        try await client(for: settings).testConnection()
    }

    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput {
        try await client(for: settings).correct(prompt: prompt, audioWAVData: audioWAVData)
    }

    private func client(for settings: CorrectionSettings) -> OpenAIResponsesClient {
        OpenAIResponsesClient(
            apiKey: settings.apiKey,
            baseURLString: settings.baseURL,
            model: settings.model,
            transport: transport
        )
    }
}

@MainActor
final class RealtimeCorrectionCoordinator: ObservableObject {
    @Published var settings: CorrectionSettings {
        didSet {
            settingsDidChange(from: oldValue)
        }
    }
    @Published private(set) var status: CorrectionStatus
    @Published private(set) var modelFetchState: CorrectionModelFetchState = .idle
    @Published private(set) var apiTestState: CorrectionAPITestState = .idle
    private(set) var sessionGeneration = 0
    var onResult: ((CorrectionResult) -> Void)?

    private static let maximumConcurrentCalls = 2
    private static let maximumWaitingPerSource = 3
    private static let maximumSkippedDiagnostics = 32

    private let responder: any CorrectionResponding
    private let promptBuilder: CorrectionPromptBuilder
    private var sessionIsActive = false
    private var sessionUsesTextOnly = false
    private var nextEnqueueOrdinal: UInt64 = 0
    private var nextSuccessOrdinal: UInt64 = 0
    private var waitingBySource: [String: [WaitingJob]] = [:]
    private var activeBySource: [String: ActiveDispatch] = [:]
    private var successfulBySource: [String: [SuccessfulEntry]] = [:]
    private var modelFetchTask: Task<Void, Never>?
    private var apiTestTask: Task<Void, Never>?
    private var modelFetchGeneration = 0
    private var apiTestGeneration = 0
    private var modelFetchToken: UUID?
    private var apiTestToken: UUID?
    private(set) var skippedCaptionIDs: [UUID] = []

    init(
        settings: CorrectionSettings = .default,
        responder: any CorrectionResponding = OpenAICorrectionResponder(
            transport: URLSessionHTTPTransport()
        ),
        promptBuilder: CorrectionPromptBuilder = CorrectionPromptBuilder()
    ) {
        self.settings = settings
        self.responder = responder
        self.promptBuilder = promptBuilder
        status = settings.isEnabled ? .ready : .disabled
    }

    func beginSession() {
        sessionGeneration &+= 1
        sessionIsActive = true
        invalidateActiveCalls()
        clearSessionState()
        refreshSessionStatus()
    }

    func enqueue(_ job: CorrectionJob) {
        guard sessionIsActive,
              job.sessionGeneration == sessionGeneration,
              settings.isEnabled(for: job.sourceID),
              validateCurrentSettings() else {
            return
        }

        nextEnqueueOrdinal &+= 1
        var waiting = waitingBySource[job.sourceID, default: []]
        if waiting.count == Self.maximumWaitingPerSource {
            recordSkipped(waiting.removeFirst().job.captionID)
        }
        waiting.append(WaitingJob(job: job, ordinal: nextEnqueueOrdinal))
        waitingBySource[job.sourceID] = waiting
        drain()
    }

    func cancel(sourceID: String) {
        waitingBySource.removeValue(forKey: sourceID)
        guard let active = activeBySource[sourceID] else { return }
        active.acceptsResult = false
        active.task?.cancel()
    }

    func endSession() {
        sessionGeneration &+= 1
        sessionIsActive = false
        invalidateActiveCalls()
        clearSessionState()
        status = settings.isEnabled ? .ready : .disabled
    }

    func fetchModels() {
        modelFetchGeneration &+= 1
        modelFetchTask?.cancel()
        modelFetchTask = nil
        modelFetchToken = nil

        guard settings.isEnabled else {
            modelFetchState = .idle
            return
        }
        do {
            try responder.validate(settings: settings)
        } catch {
            modelFetchState = .failed(sanitizedDetail(for: error))
            return
        }

        let generation = modelFetchGeneration
        let token = UUID()
        let requestSettings = settings
        modelFetchToken = token
        modelFetchState = .fetching
        modelFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await responder.fetchAvailableModels(settings: requestSettings)
                guard modelFetchGeneration == generation, modelFetchToken == token else { return }
                modelFetchState = .fetched(models)
                modelFetchTask = nil
                modelFetchToken = nil
            } catch {
                guard modelFetchGeneration == generation, modelFetchToken == token else { return }
                modelFetchState = .failed(sanitizedDetail(for: error))
                modelFetchTask = nil
                modelFetchToken = nil
            }
        }
    }

    func testAPI() {
        apiTestGeneration &+= 1
        apiTestTask?.cancel()
        apiTestTask = nil
        apiTestToken = nil

        guard settings.isEnabled else {
            apiTestState = .idle
            return
        }
        do {
            try responder.validate(settings: settings)
        } catch {
            apiTestState = .failed(sanitizedDetail(for: error))
            return
        }

        let generation = apiTestGeneration
        let token = UUID()
        let requestSettings = settings
        apiTestToken = token
        apiTestState = .testing
        apiTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await responder.testConnection(settings: requestSettings)
                guard apiTestGeneration == generation, apiTestToken == token else { return }
                apiTestState = .passed(String(response.prefix(80)))
                apiTestTask = nil
                apiTestToken = nil
            } catch {
                guard apiTestGeneration == generation, apiTestToken == token else { return }
                apiTestState = .failed(sanitizedDetail(for: error))
                apiTestTask = nil
                apiTestToken = nil
            }
        }
    }

    func waitingCaptionIDs(for sourceID: String) -> [UUID] {
        waitingBySource[sourceID, default: []].map(\.job.captionID)
    }

    private func drain() {
        guard sessionIsActive else { return }
        while activeBySource.count < Self.maximumConcurrentCalls,
              let next = nextDispatchableJob() {
            var sourceWaiting = waitingBySource[next.job.sourceID, default: []]
            guard let index = sourceWaiting.firstIndex(where: { $0.ordinal == next.ordinal }) else {
                return
            }
            sourceWaiting.remove(at: index)
            if sourceWaiting.isEmpty {
                waitingBySource.removeValue(forKey: next.job.sourceID)
            } else {
                waitingBySource[next.job.sourceID] = sourceWaiting
            }
            dispatch(next.job)
        }
    }

    private func nextDispatchableJob() -> WaitingJob? {
        waitingBySource.values.compactMap(\.first).filter {
            activeBySource[$0.job.sourceID] == nil
        }.min {
            if $0.job.capturedAt != $1.job.capturedAt {
                return $0.job.capturedAt < $1.job.capturedAt
            }
            return $0.ordinal < $1.ordinal
        }
    }

    private func dispatch(_ job: CorrectionJob) {
        let mode: CorrectionInputMode = sessionUsesTextOnly || job.audioWAVData?.isEmpty != false
            ? .textOnly
            : .audio
        let context = context(for: job.sourceID)
        let prompt = promptBuilder.build(job: job, context: context, mode: mode)
        let requestSettings = settings
        let generation = sessionGeneration
        let token = UUID()
        let active = ActiveDispatch(token: token)
        activeBySource[job.sourceID] = active
        status = mode == .audio ? .audio : .textOnly

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCorrection(
                job: job,
                settings: requestSettings,
                context: context,
                prompt: prompt,
                mode: mode,
                generation: generation,
                token: token
            )
        }
        active.task = task
    }

    private func performCorrection(
        job: CorrectionJob,
        settings: CorrectionSettings,
        context: [CorrectionContextEntry],
        prompt: CorrectionPrompt,
        mode: CorrectionInputMode,
        generation: Int,
        token: UUID
    ) async {
        guard !Task.isCancelled,
              isCurrent(job.sourceID, generation: generation, token: token) else {
            releaseSlot(sourceID: job.sourceID, token: token)
            return
        }
        do {
            let output = try await responder.correct(
                settings: settings,
                prompt: prompt,
                audioWAVData: mode == .audio ? job.audioWAVData : nil
            )
            finishSuccess(output, job: job, mode: mode, generation: generation, token: token)
        } catch let error as OpenAIResponsesClient.ClientError {
            guard case .audioUnsupported = error, mode == .audio else {
                finishFailure(error, sourceID: job.sourceID, generation: generation, token: token)
                return
            }
            guard isCurrent(job.sourceID, generation: generation, token: token) else {
                releaseSlot(sourceID: job.sourceID, token: token)
                return
            }

            sessionUsesTextOnly = true
            status = .textOnly
            let fallbackPrompt = promptBuilder.build(job: job, context: context, mode: .textOnly)
            do {
                let output = try await responder.correct(
                    settings: settings,
                    prompt: fallbackPrompt,
                    audioWAVData: nil
                )
                finishSuccess(output, job: job, mode: .textOnly, generation: generation, token: token)
            } catch {
                finishFailure(error, sourceID: job.sourceID, generation: generation, token: token)
            }
        } catch {
            finishFailure(error, sourceID: job.sourceID, generation: generation, token: token)
        }
    }

    private func finishSuccess(
        _ output: CorrectionProviderOutput,
        job: CorrectionJob,
        mode: CorrectionInputMode,
        generation: Int,
        token: UUID
    ) {
        guard isCurrent(job.sourceID, generation: generation, token: token) else {
            releaseSlot(sourceID: job.sourceID, token: token)
            return
        }

        let correctedOriginal = mode == .audio ? output.correctedOriginal : nil
        let result = CorrectionResult(
            captionID: job.captionID,
            sessionGeneration: generation,
            sourceID: job.sourceID,
            correctedOriginal: correctedOriginal,
            correctedTranslation: output.correctedTranslation,
            mode: mode
        )
        recordSuccess(job: job, result: result)
        onResult?(result)
        status = sessionUsesTextOnly ? .textOnly : (mode == .audio ? .audio : .textOnly)
        releaseSlot(sourceID: job.sourceID, token: token)
    }

    private func finishFailure(
        _ error: Error,
        sourceID: String,
        generation: Int,
        token: UUID
    ) {
        guard isCurrent(sourceID, generation: generation, token: token) else {
            releaseSlot(sourceID: sourceID, token: token)
            return
        }
        status = .warning(sanitizedDetail(for: error) ?? "Correction request failed.")
        releaseSlot(sourceID: sourceID, token: token)
    }

    private func isCurrent(_ sourceID: String, generation: Int, token: UUID) -> Bool {
        sessionIsActive
            && sessionGeneration == generation
            && activeBySource[sourceID]?.token == token
            && activeBySource[sourceID]?.acceptsResult == true
    }

    private func releaseSlot(sourceID: String, token: UUID) {
        guard activeBySource[sourceID]?.token == token else { return }
        activeBySource.removeValue(forKey: sourceID)
        drain()
    }

    private func context(for sourceID: String) -> [CorrectionContextEntry] {
        let candidates: [SuccessfulEntry]
        if settings.usesIsolatedContext(for: sourceID) {
            candidates = successfulBySource[sourceID, default: []]
        } else {
            candidates = successfulBySource.values.flatMap { $0 }
        }
        return candidates.sorted(by: Self.successOrder).suffix(CorrectionPromptBuilder.contextLimit).map(\.entry)
    }

    private func recordSuccess(job: CorrectionJob, result: CorrectionResult) {
        nextSuccessOrdinal &+= 1
        let entry = CorrectionContextEntry(
            captionID: job.captionID,
            capturedAt: job.capturedAt,
            sourceID: job.sourceID,
            sourceName: job.sourceName,
            sourceLanguageID: job.sourceLanguageID,
            targetLanguageID: job.targetLanguageID,
            original: result.correctedOriginal ?? job.localOriginal,
            translation: result.correctedTranslation
        )
        var sourceEntries = successfulBySource[job.sourceID, default: []]
        sourceEntries.append(SuccessfulEntry(entry: entry, ordinal: nextSuccessOrdinal))
        sourceEntries.sort(by: Self.successOrder)
        successfulBySource[job.sourceID] = Array(sourceEntries.suffix(CorrectionPromptBuilder.contextLimit))
    }

    private func recordSkipped(_ captionID: UUID) {
        skippedCaptionIDs.append(captionID)
        if skippedCaptionIDs.count > Self.maximumSkippedDiagnostics {
            skippedCaptionIDs.removeFirst(skippedCaptionIDs.count - Self.maximumSkippedDiagnostics)
        }
    }

    private static func successOrder(_ lhs: SuccessfulEntry, _ rhs: SuccessfulEntry) -> Bool {
        if lhs.entry.capturedAt != rhs.entry.capturedAt {
            return lhs.entry.capturedAt < rhs.entry.capturedAt
        }
        return lhs.ordinal < rhs.ordinal
    }

    private func settingsDidChange(from previous: CorrectionSettings) {
        let providerChanged = CorrectionProviderIdentity(previous) != CorrectionProviderIdentity(settings)
        let disabledGlobally = previous.isEnabled && !settings.isEnabled

        if providerChanged || disabledGlobally {
            invalidateProviderOperations()
        }
        if sessionIsActive, providerChanged || disabledGlobally {
            sessionGeneration &+= 1
            invalidateActiveCalls()
            clearSessionState()
        }
        refreshSessionStatus()
    }

    private func invalidateProviderOperations() {
        modelFetchGeneration &+= 1
        modelFetchTask?.cancel()
        modelFetchTask = nil
        modelFetchToken = nil
        modelFetchState = .idle

        apiTestGeneration &+= 1
        apiTestTask?.cancel()
        apiTestTask = nil
        apiTestToken = nil
        apiTestState = .idle
    }

    private func invalidateActiveCalls() {
        for active in activeBySource.values {
            active.acceptsResult = false
            active.task?.cancel()
        }
    }

    private func clearSessionState() {
        waitingBySource.removeAll()
        successfulBySource.removeAll()
        skippedCaptionIDs.removeAll()
        sessionUsesTextOnly = false
        nextEnqueueOrdinal = 0
        nextSuccessOrdinal = 0
    }

    @discardableResult
    private func validateCurrentSettings() -> Bool {
        guard settings.isEnabled else {
            status = .disabled
            return false
        }
        do {
            try responder.validate(settings: settings)
            return true
        } catch {
            status = .warning("Correction settings are invalid.")
            return false
        }
    }

    private func refreshSessionStatus() {
        guard settings.isEnabled else {
            status = .disabled
            return
        }
        guard validateCurrentSettings() else { return }
        status = sessionIsActive ? (sessionUsesTextOnly ? .textOnly : .audio) : .ready
    }

    private func sanitizedDetail(for error: Error) -> String? {
        (error as? OpenAIResponsesClient.ClientError)?.errorDescription
    }
}

private struct CorrectionProviderIdentity: Equatable {
    let apiKey: String
    let baseURL: String
    let model: String

    init(_ settings: CorrectionSettings) {
        apiKey = settings.apiKey
        baseURL = settings.baseURL
        model = settings.model
    }
}

private struct WaitingJob {
    let job: CorrectionJob
    let ordinal: UInt64
}

private struct SuccessfulEntry {
    let entry: CorrectionContextEntry
    let ordinal: UInt64
}

@MainActor
private final class ActiveDispatch {
    let token: UUID
    var task: Task<Void, Never>?
    var acceptsResult = true

    init(token: UUID) {
        self.token = token
    }
}
