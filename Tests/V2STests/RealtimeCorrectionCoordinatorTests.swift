import Foundation
import Testing
@testable import v2s

@MainActor
@Suite struct RealtimeCorrectionCoordinatorTests {
    @Test func sameSourceIsSequentialAndDifferentSourcesReachTwoWayConcurrency() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()

        coordinator.enqueue(job(coordinator, sourceID: "mic-1", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "mic-1", sequence: 2))
        coordinator.enqueue(job(coordinator, sourceID: "app-1", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "app-2", sequence: 1))

        await waitUntil {
            await responder.activeSourceIDs() == Set(["mic-1", "app-1"])
        }
        #expect(await responder.maximumConcurrentCallCount() == 2)
        #expect(!(await responder.startedSequences(for: "mic-1")).contains(2))

        await responder.releaseHeldCall(sourceID: "mic-1", output: output("mic-1"))
        await responder.releaseHeldCall(sourceID: "app-1", output: output("app-1"))
        await waitUntil {
            (await responder.startedSequences(for: "mic-1")).contains(2)
        }
        #expect(await responder.maximumConcurrentCallCount() == 2)
    }

    @Test func fourthWaitingJobDropsOldestWaitingNotActive() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()

        for sequence in 1 ... 5 {
            coordinator.enqueue(job(coordinator, sourceID: "mic-1", sequence: sequence))
        }

        #expect(coordinator.waitingCaptionIDs(for: "mic-1") == [id(3), id(4), id(5)])
        #expect(coordinator.skippedCaptionIDs == [id(2)])
        await waitUntil { await responder.callCount() == 1 }
    }

    @Test func skippedDiagnosticsRemainBoundedAndKeepNewestCaptionIDs() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()

        for sequence in 1 ... 100 {
            coordinator.enqueue(job(coordinator, sourceID: "mic-1", sequence: sequence))
        }

        #expect(coordinator.skippedCaptionIDs.count == 32)
        #expect(coordinator.skippedCaptionIDs == (66 ... 97).map(id))
        #expect(coordinator.waitingCaptionIDs(for: "mic-1") == [id(98), id(99), id(100)])
    }

    @Test func equalTimestampHeadsUseStableEnqueueOrder() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        let timestamp = Date(timeIntervalSince1970: 10)

        coordinator.enqueue(job(coordinator, sourceID: "active-a", sequence: 1, capturedAt: timestamp.addingTimeInterval(-1)))
        coordinator.enqueue(job(coordinator, sourceID: "active-b", sequence: 1, capturedAt: timestamp.addingTimeInterval(-1)))
        await waitUntil { await responder.activeSourceIDs().count == 2 }

        coordinator.enqueue(job(coordinator, sourceID: "first-equal", sequence: 1, capturedAt: timestamp))
        coordinator.enqueue(job(coordinator, sourceID: "second-equal", sequence: 1, capturedAt: timestamp))
        await responder.releaseHeldCall(sourceID: "active-a", output: output("active-a"))

        await waitUntil { await responder.activeSourceIDs().contains("first-equal") }
        #expect(!(await responder.startedSourceIDs()).contains("second-equal"))
    }

    @Test func globalContextUsesNewestSixSuccessfulEntries() async {
        let responder = HeldCorrectionResponder(steps: Array(repeating: .success, count: 8))
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        for sequence in 1 ... 7 {
            coordinator.enqueue(job(coordinator, sourceID: "history", sequence: sequence))
            await waitUntil { resultCount == sequence }
        }
        coordinator.enqueue(job(coordinator, sourceID: "target", sequence: 8))
        await waitUntil { resultCount == 8 }

        let context = await responder.contextOriginals(call: 7)
        #expect(context == (1 ... 6).map { "call \($0)" })
    }

    @Test func queuedTargetBuildsContextOnlyWhenItActuallyDispatches() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()

        coordinator.enqueue(job(coordinator, sourceID: "new-context", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "other-active", sequence: 2))
        await waitUntil { await responder.callCount() == 2 }
        coordinator.enqueue(job(coordinator, sourceID: "queued-target", sequence: 50))

        await responder.releaseHeldCall(
            sourceID: "new-context",
            output: .init(correctedOriginal: "corrected source", correctedTranslation: "corrected translation")
        )
        await waitUntil { await responder.callCount() == 3 }

        let context = await responder.contextEntries(call: 2)
        #expect(context.count == 1)
        #expect(context.first?.sourceID == "new-context")
        #expect(context.first?.sourceName == "new-context")
        #expect(context.first?.sourceLanguageID == "en")
        #expect(context.first?.targetLanguageID == "zh-Hans")
        #expect(context.first?.original == "corrected source")
        #expect(context.first?.translation == "corrected translation")
    }

    @Test func globalContextUsesNewestSixAcrossSourcesWithCompleteSemantics() async {
        let responder = HeldCorrectionResponder(steps: Array(repeating: .success, count: 8))
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        for sequence in 1 ... 7 {
            coordinator.enqueue(job(
                sourceID: "source-\(sequence)",
                sourceName: "Source \(sequence)",
                sourceLanguageID: "source-language-\(sequence)",
                targetLanguageID: "target-language-\(sequence)",
                sequence: sequence,
                generation: coordinator.sessionGeneration
            ))
            await waitUntil { resultCount == sequence }
        }
        coordinator.enqueue(job(coordinator, sourceID: "target", sequence: 200))
        await waitUntil { resultCount == 8 }

        let context = await responder.contextEntries(call: 7)
        #expect(context.map(\.sourceID) == (2 ... 7).map { "source-\($0)" })
        #expect(context.map(\.sourceName) == (2 ... 7).map { "Source \($0)" })
        #expect(context.map(\.sourceLanguageID) == (2 ... 7).map { "source-language-\($0)" })
        #expect(context.map(\.targetLanguageID) == (2 ... 7).map { "target-language-\($0)" })
        #expect(context.map(\.original) == (1 ... 6).map { "call \($0)" })
        #expect(context.map(\.translation) == (1 ... 6).map { "translated call \($0)" })
    }

    @Test func isolatedSourceSuccessStillContributesToOtherGlobalContext() async {
        let responder = HeldCorrectionResponder(steps: [.success, .success])
        var settings = configuredSettings()
        settings.isolatedContextSourceIDs = ["isolated"]
        let coordinator = makeCoordinator(settings: settings, responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        coordinator.enqueue(job(coordinator, sourceID: "isolated", sequence: 1))
        await waitUntil { resultCount == 1 }
        coordinator.enqueue(job(coordinator, sourceID: "global-observer", sequence: 2))
        await waitUntil { resultCount == 2 }

        let context = await responder.contextEntries(call: 1)
        #expect(context.map(\.sourceID) == ["isolated"])
        #expect(context.map(\.original) == ["call 0"])
        #expect(context.map(\.translation) == ["translated call 0"])
    }

    @Test func isolatedContextUsesOnlyCurrentSourceNewestSix() async {
        let responder = HeldCorrectionResponder(steps: Array(repeating: .success, count: 10))
        var settings = configuredSettings()
        settings.isolatedContextSourceIDs = ["mic"]
        let coordinator = makeCoordinator(settings: settings, responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        for sequence in 1 ... 4 {
            coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: sequence))
            await waitUntil { resultCount == sequence * 2 - 1 }
            coordinator.enqueue(job(coordinator, sourceID: "app", sequence: sequence + 10))
            await waitUntil { resultCount == sequence * 2 }
        }
        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 99))
        await waitUntil { resultCount == 9 }

        let context = await responder.contextOriginals(call: 8)
        #expect(context == ["call 0", "call 2", "call 4", "call 6"])
    }

    @Test func failedAndSkippedJobsNeverEnterContext() async {
        let responder = HeldCorrectionResponder(steps: [.held, .success, .success, .success, .success])
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        for sequence in 1 ... 5 {
            coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: sequence))
        }
        await waitUntil { await responder.callCount() == 1 }
        await responder.failHeldCall(sourceID: "mic", error: .opaque("private detail"))
        await waitUntil { resultCount == 3 }

        coordinator.enqueue(job(coordinator, sourceID: "target", sequence: 9))
        await waitUntil { resultCount == 4 }

        #expect(coordinator.skippedCaptionIDs == [id(2)])
        let context = await responder.contextOriginals(call: 4)
        #expect(context == ["call 1", "call 2", "call 3"])
    }

    @Test func concurrentAudioUnsupportedJobsEachRetryOnceAndDowngradeSession() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var results: [CorrectionResult] = []
        coordinator.onResult = { results.append($0) }

        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "app", sequence: 2))
        await waitUntil { await responder.callCount() == 2 }
        await responder.failHeldCall(sourceID: "mic", error: .audioUnsupported)
        await responder.failHeldCall(sourceID: "app", error: .audioUnsupported)
        await waitUntil { await responder.callCount() == 4 }

        await responder.releaseHeldCall(sourceID: "mic", output: output("mic retry"))
        await responder.releaseHeldCall(sourceID: "app", output: output("app retry"))
        await waitUntil { results.count == 2 }

        #expect(coordinator.status == .textOnly)
        #expect(await responder.modes(for: "mic") == [.audio, .textOnly])
        #expect(await responder.modes(for: "app") == [.audio, .textOnly])
        #expect(await responder.audioPresence(for: "mic") == [true, false])
        #expect(await responder.audioPresence(for: "app") == [true, false])
    }

    @Test func authenticationRateLimitAndTimeoutDoNotDowngrade() async {
        for failure in [HeldCorrectionResponder.Failure.http(401), .http(429), .timeout] {
            let responder = HeldCorrectionResponder(steps: [.failure(failure), .success])
            let coordinator = makeCoordinator(responder: responder)
            coordinator.beginSession()
            var resultCount = 0
            coordinator.onResult = { _ in resultCount += 1 }

            coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1))
            await waitUntil { await responder.callCount() == 1 }
            coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 2))
            await waitUntil { resultCount == 1 }

            #expect(await responder.modes(for: "mic") == [.audio, .audio])
            #expect(coordinator.status != .textOnly)
        }
    }

    @Test func audioLessJobUsesTextOnlyWithoutDowngradingLaterAudio() async {
        let responder = HeldCorrectionResponder(steps: [.success, .success])
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var resultCount = 0
        coordinator.onResult = { _ in resultCount += 1 }

        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1, audio: nil))
        await waitUntil { resultCount == 1 }
        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 2))
        await waitUntil { resultCount == 2 }

        #expect(await responder.modes(for: "mic") == [.textOnly, .audio])
        #expect(await responder.audioPresence(for: "mic") == [false, true])
        #expect(coordinator.status == .audio)
    }

    @Test func staleGenerationEnqueueIsRejected() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        let staleGeneration = coordinator.sessionGeneration
        coordinator.beginSession()

        coordinator.enqueue(job(sourceID: "mic", sequence: 1, generation: staleGeneration))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await responder.callCount() == 0)
        #expect(coordinator.waitingCaptionIDs(for: "mic").isEmpty)
    }

    @Test func endSessionRejectsHeldLateResult() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var results: [CorrectionResult] = []
        coordinator.onResult = { results.append($0) }
        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1))
        await waitUntil { await responder.callCount() == 1 }

        coordinator.endSession()
        await responder.releaseHeldCall(sourceID: "mic", output: output("stale"))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(results.isEmpty)
    }

    @Test func providerChangeRejectsHeldLateResultAndKeepsSessionActive() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var results: [CorrectionResult] = []
        coordinator.onResult = { results.append($0) }
        coordinator.enqueue(job(coordinator, sourceID: "old", sequence: 1))
        await waitUntil { await responder.callCount() == 1 }

        let oldGeneration = coordinator.sessionGeneration
        coordinator.settings.model = "replacement-model"
        #expect(coordinator.sessionGeneration == oldGeneration + 1)
        coordinator.enqueue(job(coordinator, sourceID: "new", sequence: 2))
        await waitUntil { await responder.callCount() == 2 }
        await responder.releaseHeldCall(sourceID: "old", output: output("stale"))
        await responder.releaseHeldCall(sourceID: "new", output: output("current"))
        await waitUntil { results.count == 1 }

        #expect(results.map(\.sourceID) == ["new"])
    }

    @Test func cancelSourceRejectsLateResultButAllowsOtherSource() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var results: [CorrectionResult] = []
        coordinator.onResult = { results.append($0) }
        coordinator.enqueue(job(coordinator, sourceID: "cancelled", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "kept", sequence: 2))
        await waitUntil { await responder.callCount() == 2 }

        coordinator.cancel(sourceID: "cancelled")
        await responder.releaseHeldCall(sourceID: "cancelled", output: output("stale"))
        await responder.releaseHeldCall(sourceID: "kept", output: output("current"))
        await waitUntil { results.count == 1 }

        #expect(results.map(\.sourceID) == ["kept"])
    }

    @Test func cancellationIgnoringResponderStillNeverExceedsTwoRealCalls() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        coordinator.enqueue(job(coordinator, sourceID: "a", sequence: 1))
        coordinator.enqueue(job(coordinator, sourceID: "b", sequence: 2))
        await waitUntil { await responder.callCount() == 2 }

        coordinator.cancel(sourceID: "a")
        coordinator.enqueue(job(coordinator, sourceID: "c", sequence: 3))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await responder.callCount() == 2)

        await responder.releaseHeldCall(sourceID: "a", output: output("ignored"))
        await waitUntil { await responder.callCount() == 3 }
        #expect(await responder.maximumConcurrentCallCount() == 2)
    }

    @Test func synchronousInvalidationBeforeDispatchNeverCallsResponder() async {
        for (offset, invalidation) in ImmediateInvalidation.allCases.enumerated() {
            let responder = HeldCorrectionResponder(steps: [.success])
            let coordinator = makeCoordinator(responder: responder)
            coordinator.beginSession()
            coordinator.enqueue(job(coordinator, sourceID: "source-\(offset)", sequence: 100 + offset))

            switch invalidation {
            case .cancelSource:
                coordinator.cancel(sourceID: "source-\(offset)")
            case .endSession:
                coordinator.endSession()
            case .disable:
                coordinator.settings.isEnabled = false
            case .providerChange:
                coordinator.settings.model = "replacement-model"
            }

            try? await Task.sleep(for: .milliseconds(30))
            #expect(await responder.callCount() == 0, "Unexpected request after \(invalidation)")
        }
    }

    @Test func disabledAndInvalidSettingsNeverCallResponder() async {
        let disabledResponder = HeldCorrectionResponder()
        let disabled = makeCoordinator(settings: .default, responder: disabledResponder)
        disabled.beginSession()
        disabled.enqueue(job(sourceID: "mic", sequence: 1, generation: disabled.sessionGeneration))
        disabled.fetchModels()
        disabled.testAPI()

        var invalidSettings = configuredSettings()
        invalidSettings.apiKey = ""
        let invalidResponder = HeldCorrectionResponder()
        let invalid = makeCoordinator(settings: invalidSettings, responder: invalidResponder)
        invalid.beginSession()
        invalid.enqueue(job(sourceID: "mic", sequence: 2, generation: invalid.sessionGeneration))
        invalid.fetchModels()
        invalid.testAPI()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await disabledResponder.totalOperationCount() == 0)
        #expect(await invalidResponder.totalOperationCount() == 0)
        #expect(disabled.status == .disabled)
        #expect(invalid.status == .warning("Correction settings are invalid."))
    }

    @Test func modelFetchAndAPITestIgnoreStaleProviderResults() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.fetchModels()
        coordinator.testAPI()
        await waitUntil { await responder.providerOperationCount() == 2 }

        coordinator.settings.baseURL = "https://replacement.invalid/v1"
        await responder.releaseModelFetch(.success(["stale-model"]))
        await responder.releaseAPITest(.success("stale test"))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.modelFetchState == .idle)
        #expect(coordinator.apiTestState == .idle)
    }

    @Test func disablingSettingsInvalidatesHeldCorrectionAndProviderOperations() async {
        let responder = HeldCorrectionResponder()
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        var results: [CorrectionResult] = []
        coordinator.onResult = { results.append($0) }
        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1))
        coordinator.fetchModels()
        coordinator.testAPI()
        await waitUntil {
            let correctionCount = await responder.callCount()
            let operationCount = await responder.providerOperationCount()
            return correctionCount == 1 && operationCount == 2
        }

        coordinator.settings.isEnabled = false
        await responder.releaseHeldCall(sourceID: "mic", output: output("stale"))
        await responder.releaseModelFetch(.success(["stale-model"]))
        await responder.releaseAPITest(.success("stale test"))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(results.isEmpty)
        #expect(coordinator.status == .disabled)
        #expect(coordinator.modelFetchState == .idle)
        #expect(coordinator.apiTestState == .idle)
    }

    @Test func errorsExposeOnlySanitizedClientDetails() async {
        let responder = HeldCorrectionResponder(
            steps: [.failure(.opaque("DO NOT EXPOSE"))],
            modelResult: .failure(.opaque("MODEL SECRET")),
            apiResult: .failure(.http(503))
        )
        let coordinator = makeCoordinator(responder: responder)
        coordinator.beginSession()
        coordinator.enqueue(job(coordinator, sourceID: "mic", sequence: 1))
        coordinator.fetchModels()
        coordinator.testAPI()

        await waitUntil {
            coordinator.status == .warning("Correction request failed.")
                && coordinator.modelFetchState == .failed(nil)
                && coordinator.apiTestState == .failed("HTTP 503: sanitized provider failure")
        }

        #expect(coordinator.status == .warning("Correction request failed."))
        #expect(coordinator.modelFetchState == .failed(nil))
        #expect(coordinator.apiTestState == .failed("HTTP 503: sanitized provider failure"))
    }
}

@MainActor
private func makeCoordinator(
    settings: CorrectionSettings = configuredSettings(),
    responder: HeldCorrectionResponder
) -> RealtimeCorrectionCoordinator {
    RealtimeCorrectionCoordinator(settings: settings, responder: responder)
}

private func configuredSettings() -> CorrectionSettings {
    .init(
        isEnabled: true,
        apiKey: "test-placeholder-key",
        baseURL: "https://example.invalid/v1",
        model: "test-model",
        disabledSourceIDs: [],
        isolatedContextSourceIDs: []
    )
}

@MainActor
private func job(
    _ coordinator: RealtimeCorrectionCoordinator,
    sourceID: String,
    sequence: Int,
    capturedAt: Date? = nil,
    audio: Data? = Data([0x52, 0x49, 0x46, 0x46])
) -> CorrectionJob {
    job(
        sourceID: sourceID,
        sequence: sequence,
        generation: coordinator.sessionGeneration,
        capturedAt: capturedAt,
        audio: audio
    )
}

private func job(
    sourceID: String,
    sourceName: String? = nil,
    sourceLanguageID: String = "en",
    targetLanguageID: String = "zh-Hans",
    sequence: Int,
    generation: Int,
    capturedAt: Date? = nil,
    audio: Data? = Data([0x52, 0x49, 0x46, 0x46])
) -> CorrectionJob {
    .init(
        captionID: id(sequence),
        sessionGeneration: generation,
        capturedAt: capturedAt ?? Date(timeIntervalSince1970: TimeInterval(sequence)),
        sourceID: sourceID,
        sourceName: sourceName ?? sourceID,
        sourceLanguageID: sourceLanguageID,
        targetLanguageID: targetLanguageID,
        localOriginal: "\(sourceID)-\(sequence)",
        localTranslation: "local-\(sourceID)-\(sequence)",
        audioWAVData: audio
    )
}

private func id(_ sequence: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", sequence))!
}

private func output(_ value: String = "corrected") -> CorrectionProviderOutput {
    .init(correctedOriginal: value, correctedTranslation: "translated \(value)")
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private struct HeldCorrectionResponder: CorrectionResponding {
    struct RecordedContextEntry: Equatable, Sendable {
        let sourceID: String
        let sourceName: String
        let sourceLanguageID: String
        let targetLanguageID: String
        let original: String
        let translation: String
    }

    enum Failure: Error, Sendable, Equatable {
        case audioUnsupported
        case http(Int)
        case timeout
        case opaque(String)
    }

    enum Step: Sendable {
        case held
        case success
        case failure(Failure)
    }

    private let state: State

    init(
        steps: [Step] = [],
        modelResult: Result<[String], Failure>? = nil,
        apiResult: Result<String, Failure>? = nil
    ) {
        state = State(steps: steps, modelResult: modelResult, apiResult: apiResult)
    }

    func validate(settings: CorrectionSettings) throws {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              URL(string: settings.baseURL)?.scheme != nil,
              !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.opaque("invalid")
        }
    }

    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String] {
        try await state.fetchAvailableModels()
    }

    func testConnection(settings: CorrectionSettings) async throws -> String {
        try await state.testConnection()
    }

    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput {
        try await state.correct(prompt: prompt, audioWAVData: audioWAVData)
    }

    func callCount() async -> Int { await state.callCount }
    func totalOperationCount() async -> Int { await state.callCount + state.providerOperationCount }
    func providerOperationCount() async -> Int { await state.providerOperationCount }
    func maximumConcurrentCallCount() async -> Int { await state.maximumConcurrentCallCount }
    func activeSourceIDs() async -> Set<String> { await state.activeSourceIDs() }
    func startedSourceIDs() async -> [String] { await state.calls.map(\.sourceID) }
    func startedSequences(for sourceID: String) async -> [Int] { await state.calls.filter { $0.sourceID == sourceID }.map(\.sequence) }
    func modes(for sourceID: String) async -> [CorrectionInputMode] { await state.calls.filter { $0.sourceID == sourceID }.map(\.prompt.mode) }
    func audioPresence(for sourceID: String) async -> [Bool] { await state.calls.filter { $0.sourceID == sourceID }.map { $0.audioWAVData?.isEmpty == false } }
    func contextOriginals(call index: Int) async -> [String] { await state.calls[index].contextOriginals }
    func contextEntries(call index: Int) async -> [RecordedContextEntry] { await state.calls[index].contextEntries }
    func releaseHeldCall(sourceID: String, output: CorrectionProviderOutput) async { await state.releaseHeldCall(sourceID: sourceID, result: .success(output)) }
    func failHeldCall(sourceID: String, error: Failure) async { await state.releaseHeldCall(sourceID: sourceID, result: .failure(error)) }
    func releaseModelFetch(_ result: Result<[String], Failure>) async { await state.releaseModelFetch(result) }
    func releaseAPITest(_ result: Result<String, Failure>) async { await state.releaseAPITest(result) }

    actor State {
        struct Call: Sendable {
            let sourceID: String
            let sequence: Int
            let prompt: CorrectionPrompt
            let audioWAVData: Data?
            let contextEntries: [RecordedContextEntry]

            var contextOriginals: [String] {
                contextEntries.map(\.original)
            }
        }

        let steps: [Step]
        let modelResult: Result<[String], Failure>?
        let apiResult: Result<String, Failure>?
        var calls: [Call] = []
        var callCount: Int { calls.count }
        var providerOperationCount = 0
        var activeIndices: Set<Int> = []
        var maximumConcurrentCallCount = 0
        var held: [Int: CheckedContinuation<CorrectionProviderOutput, Error>] = [:]
        var modelContinuation: CheckedContinuation<[String], Error>?
        var apiContinuation: CheckedContinuation<String, Error>?

        init(steps: [Step], modelResult: Result<[String], Failure>?, apiResult: Result<String, Failure>?) {
            self.steps = steps
            self.modelResult = modelResult
            self.apiResult = apiResult
        }

        func correct(prompt: CorrectionPrompt, audioWAVData: Data?) async throws -> CorrectionProviderOutput {
            let current = Self.currentPayload(prompt.userContent)
            let index = calls.count
            calls.append(.init(
                sourceID: current.sourceID,
                sequence: current.sequence,
                prompt: prompt,
                audioWAVData: audioWAVData,
                contextEntries: Self.contextEntries(prompt.userContent)
            ))
            activeIndices.insert(index)
            maximumConcurrentCallCount = max(maximumConcurrentCallCount, activeIndices.count)
            defer { activeIndices.remove(index) }

            switch index < steps.count ? steps[index] : .held {
            case .held:
                return try await withCheckedThrowingContinuation { held[index] = $0 }
            case .success:
                return output("call \(index)")
            case .failure(let failure):
                throw Self.error(for: failure)
            }
        }

        func fetchAvailableModels() async throws -> [String] {
            providerOperationCount += 1
            if let modelResult {
                switch modelResult {
                case .success(let value): return value
                case .failure(let failure): throw Self.error(for: failure)
                }
            }
            return try await withCheckedThrowingContinuation { modelContinuation = $0 }
        }

        func testConnection() async throws -> String {
            providerOperationCount += 1
            if let apiResult {
                switch apiResult {
                case .success(let value): return value
                case .failure(let failure): throw Self.error(for: failure)
                }
            }
            return try await withCheckedThrowingContinuation { apiContinuation = $0 }
        }

        func activeSourceIDs() -> Set<String> {
            Set(activeIndices.map { calls[$0].sourceID })
        }

        func releaseHeldCall(sourceID: String, result: Result<CorrectionProviderOutput, Failure>) {
            guard let index = held.keys.sorted().first(where: { calls[$0].sourceID == sourceID }),
                  let continuation = held.removeValue(forKey: index) else { return }
            switch result {
            case .success(let output): continuation.resume(returning: output)
            case .failure(let failure): continuation.resume(throwing: Self.error(for: failure))
            }
        }

        func releaseModelFetch(_ result: Result<[String], Failure>) {
            guard let continuation = modelContinuation else { return }
            modelContinuation = nil
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let failure): continuation.resume(throwing: Self.error(for: failure))
            }
        }

        func releaseAPITest(_ result: Result<String, Failure>) {
            guard let continuation = apiContinuation else { return }
            apiContinuation = nil
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let failure): continuation.resume(throwing: Self.error(for: failure))
            }
        }

        private static func error(for failure: Failure) -> Error {
            switch failure {
            case .audioUnsupported:
                OpenAIResponsesClient.ClientError.audioUnsupported(message: "sanitized unsupported audio")
            case .http(let status):
                OpenAIResponsesClient.ClientError.http(status: status, message: "sanitized provider failure")
            case .timeout:
                URLError(.timedOut)
            case .opaque(let detail):
                OpaqueFailure(detail: detail)
            }
        }

        private static func currentPayload(_ content: String) -> (sourceID: String, sequence: Int) {
            let payload = jsonPayload(content)
            let current = payload["current"] as? [String: Any] ?? [:]
            let sourceID = current["sourceID"] as? String ?? ""
            let original = current["localOriginal"] as? String ?? "-0"
            let sequence = Int(original.split(separator: "-").last ?? "0") ?? 0
            return (sourceID, sequence)
        }

        private static func contextEntries(_ content: String) -> [RecordedContextEntry] {
            let payload = jsonPayload(content)
            let context = payload["context"] as? [[String: Any]] ?? []
            return context.compactMap { value in
                guard let sourceID = value["sourceID"] as? String,
                      let sourceName = value["sourceName"] as? String,
                      let sourceLanguageID = value["sourceLanguageID"] as? String,
                      let targetLanguageID = value["targetLanguageID"] as? String,
                      let original = value["original"] as? String,
                      let translation = value["translation"] as? String else {
                    return nil
                }
                return RecordedContextEntry(
                    sourceID: sourceID,
                    sourceName: sourceName,
                    sourceLanguageID: sourceLanguageID,
                    targetLanguageID: targetLanguageID,
                    original: original,
                    translation: translation
                )
            }
        }

        private static func jsonPayload(_ content: String) -> [String: Any] {
            guard let start = content.range(of: "<<<CORRECTION_PAYLOAD_JSON>>>\n")?.upperBound,
                  let end = content.range(of: "\n<<<END_CORRECTION_PAYLOAD_JSON>>>", range: start ..< content.endIndex)?.lowerBound,
                  let data = String(content[start ..< end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return object
        }
    }
}

private struct OpaqueFailure: LocalizedError, Sendable {
    let detail: String
    var errorDescription: String? { detail }
}

private enum ImmediateInvalidation: CaseIterable {
    case cancelSource
    case endSession
    case disable
    case providerChange
}
