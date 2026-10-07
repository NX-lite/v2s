import Foundation

struct NativeRealtimeCaptureSource: Sendable {
    let sourceID: String
    let role: RealtimeAudioSourceRole
    let input: RealtimePCM16AudioInput
}

struct NativeRealtimeStartedSource: Equatable, Sendable {
    let sourceID: String
    let alias: String
    let generation: Int
}

private final class StartupCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

actor NativeRealtimeSessionCoordinator {
    typealias DriverFactory = @Sendable (
        NativeRealtimeSettings,
        String?,
        RealtimeAudioSourceRole
    ) -> any RealtimeSessionDriving
    typealias SourceFailureHandler = @Sendable (String, RealtimeFailureCode) -> Void
    typealias CaptionEventHandler = @Sendable (RealtimeCaptionEventEnvelope) -> Void
    typealias CaptionDispositionHandler = @Sendable (
        RealtimeAcceptedCaptionMetadata,
        RealtimeCaptionSubmissionDisposition
    ) -> Void
    typealias CaptureRegistrationHandler = @Sendable (RealtimeCaptureRegistration) -> Void
    typealias SourceReadyHandler = @Sendable (RealtimeSourceReadyIdentity) -> Void

    private struct RunningSource {
        let capture: NativeRealtimeCaptureSource
        let generation: Int
        let alias: String
        let driver: any RealtimeSessionDriving
        let lease: RealtimeReaderLease
        let audioReader: Task<Void, Never>
        let eventReader: Task<Void, Never>
        var captionPump: Task<Void, Never>?
    }

    private struct CaptionIdentity: Hashable {
        let captionID: UUID
        let utteranceID: String
    }

    private struct CaptionSourceState {
        let sourceToken: UUID
        let captureGeneration: UInt64
        var driverGeneration: Int?
        var alias: String?
        var queued: [RealtimeAcceptedCaptionMetadata] = []
        var admittedIntervals: [Range<Int64>] = []
        var admittedEnd: Int64?
        var committedFrontier: Int64?
        var lastAcceptedEnd: Int64?
        var seen: [CaptionIdentity] = []
        var inFlight: RealtimeAcceptedCaptionMetadata?
        var commitSucceeded = false
        var stashedEvents: [RealtimeProviderEvent] = []
    }

    private enum CaptionCoverage {
        case waiting
        case covered
        case localOnly(RealtimeCaptionLocalOnlyReason)
    }

    private struct StartingSource {
        let capture: NativeRealtimeCaptureSource
        let generation: Int
        let driver: any RealtimeSessionDriving
        let lease: RealtimeReaderLease
    }

    private struct StoppingSource {
        let generation: Int
        let driverGeneration: Int
        let task: Task<Void, Never>
    }

    private struct AudioFailureReport {
        let reportID: UUID
        let sourceID: String
        let sourceToken: UUID
        let captureGeneration: UInt64
        let driverGeneration: Int
        let startupGeneration: Int
        let failureHandlerGeneration: Int
        let cancellationToken: StartupCancellationToken
        let failure: RealtimeFailureCode
    }

    private struct StartupReservation: Sendable {
        let capture: NativeRealtimeCaptureSource
        let alias: String
        let generation: Int
        let driver: any RealtimeSessionDriving
        let lease: RealtimeReaderLease

        var startingSource: StartingSource {
            StartingSource(
                capture: capture,
                generation: generation,
                driver: driver,
                lease: lease
            )
        }
    }

    private let credentialStore: RealtimeCredentialStore
    private let driverFactory: DriverFactory
    private var sourceFailureHandler: SourceFailureHandler
    private var sourceFailureHandlerGeneration = 0
    private var captionEventHandler: CaptionEventHandler = { _ in }
    private var captionDispositionHandler: CaptionDispositionHandler = { _, _ in }
    private var captureRegistrationHandler: CaptureRegistrationHandler = { _ in }
    private var sourceReadyHandler: SourceReadyHandler = { _ in }
    #if DEBUG
    private var beforeCancellationCleanupForTesting: (@Sendable () async -> Void)?
    private var beforeInputDidFinishForTesting: (@Sendable () async -> Void)?
    private var afterInputDidFinishForTesting: (@Sendable () -> Void)?
    private var beforeProviderEventDeliveryForTesting: (@Sendable () async -> Void)?
    #endif
    private var lifecycleGeneration = 0
    private var nextDriverGeneration = 0
    private var runningSources: [String: RunningSource] = [:]
    private var startingSources: [String: StartingSource] = [:]
    private var stoppingSources: [String: StoppingSource] = [:]
    private var captionSourcesByID: [String: CaptionSourceState] = [:]
    private var pendingAudioFailureReports: [String: AudioFailureReport] = [:]
    private var audioFailureReportTasks: [UUID: Task<Void, Never>] = [:]
    private var startupCapturesBySourceID: [String: NativeRealtimeCaptureSource] = [:]
    private var removedSourceIDsDuringStartup = Set<String>()
    private var nextStopGeneration = 0

    init(
        credentialStore: RealtimeCredentialStore = RealtimeCredentialStore(),
        driverFactory: @escaping DriverFactory = { settings, credential, role in
            NativeRealtimeSessionDriver(
                settings: settings,
                credential: credential,
                sourceRole: role
            )
        },
        sourceFailureHandler: @escaping SourceFailureHandler = { _, _ in }
    ) {
        self.credentialStore = credentialStore
        self.driverFactory = driverFactory
        self.sourceFailureHandler = sourceFailureHandler
    }

    func setSourceFailureHandler(_ handler: @escaping SourceFailureHandler) {
        sourceFailureHandler = handler
        sourceFailureHandlerGeneration &+= 1
    }

    func setCaptionEventHandler(_ handler: @escaping CaptionEventHandler) {
        captionEventHandler = handler
    }

    func setCaptionDispositionHandler(_ handler: @escaping CaptionDispositionHandler) {
        captionDispositionHandler = handler
    }

    func setCaptureRegistrationHandler(_ handler: @escaping CaptureRegistrationHandler) {
        captureRegistrationHandler = handler
    }

    func setSourceReadyHandler(_ handler: @escaping SourceReadyHandler) {
        sourceReadyHandler = handler
    }

    #if DEBUG
    func stashedCaptionEventsForTesting(sourceID: String, captionID: UUID) -> Int {
        guard let state = captionSourcesByID[sourceID],
              state.inFlight?.captionID == captionID else { return 0 }
        return state.stashedEvents.count
    }

    func admittedAudioRangeCountForTesting(sourceID: String) -> Int {
        captionSourcesByID[sourceID]?.admittedIntervals.count ?? 0
    }

    func seenCaptionIdentityCountForTesting(sourceID: String) -> Int {
        captionSourcesByID[sourceID]?.seen.count ?? 0
    }

    func acceptedCaptionMetadataForTesting(sourceID: String) -> RealtimeAcceptedCaptionMetadata? {
        guard let state = captionSourcesByID[sourceID] else { return nil }
        return state.inFlight ?? state.queued.first
    }

    func inFlightCaptionIDForTesting(sourceID: String) -> UUID? {
        captionSourcesByID[sourceID]?.inFlight?.captionID
    }

    func captionCommitSucceededForTesting(sourceID: String, captionID: UUID) -> Bool {
        guard let state = captionSourcesByID[sourceID],
              state.inFlight?.captionID == captionID else { return false }
        return state.commitSucceeded
    }
    #endif

    func submitAcceptedCaption(
        _ metadata: RealtimeAcceptedCaptionMetadata
    ) -> RealtimeCaptionSubmissionDisposition {
        guard !Task.isCancelled else {
            return .localOnly(.unavailableSource)
        }
        guard Self.hasValidTextIdentity(metadata) else {
            return .localOnly(.invalidMetadata)
        }
        guard let interval = metadata.sampleInterval else {
            return .localOnly(.missingProvenance)
        }
        guard Self.isValid(interval: interval) else {
            return .localOnly(.invalidMetadata)
        }
        guard let capture = startupCapturesBySourceID[metadata.sourceID]
                ?? runningSources[metadata.sourceID]?.capture,
              capture.input.sourceToken == metadata.sourceToken,
              capture.input.generation == metadata.captureGeneration,
              !capture.input.isConsumed,
              capture.input.terminationError == nil,
              runningSources[metadata.sourceID]?.lease.isActive != false else {
            return .localOnly(.unavailableSource)
        }
        guard interval.lowerBound >= capture.input.firstAvailableSampleIndex else {
            return .localOnly(.missingAudioCoverage)
        }
        var state = captionSourcesByID[metadata.sourceID] ?? CaptionSourceState(
            sourceToken: metadata.sourceToken,
            captureGeneration: metadata.captureGeneration
        )
        guard state.sourceToken == metadata.sourceToken,
              state.captureGeneration == metadata.captureGeneration else {
            return .localOnly(.unavailableSource)
        }
        guard !state.seen.contains(where: {
            $0.captionID == metadata.captionID || $0.utteranceID == metadata.utteranceID
        }) else {
            return .localOnly(.duplicateIdentity)
        }
        if let committedFrontier = state.committedFrontier,
           interval.lowerBound < committedFrontier {
            return .localOnly(.consumedAudio)
        }
        if let lastAcceptedEnd = state.lastAcceptedEnd,
           interval.lowerBound < lastAcceptedEnd {
            return .localOnly(.outOfOrderInterval)
        }
        guard state.queued.count + (state.inFlight == nil ? 0 : 1) < 8 else {
            captionSourcesByID[metadata.sourceID] = state
            isolateCaptionSource(
                sourceID: metadata.sourceID,
                sourceToken: metadata.sourceToken,
                captureGeneration: metadata.captureGeneration,
                failure: .backpressure
            )
            return .localOnly(.backpressure)
        }
        guard makeRoomForSeenIdentity(in: &state) else {
            return .localOnly(.queueFull)
        }

        state.seen.append(CaptionIdentity(
            captionID: metadata.captionID,
            utteranceID: metadata.utteranceID
        ))
        state.lastAcceptedEnd = interval.upperBound
        state.queued.append(metadata)
        captionSourcesByID[metadata.sourceID] = state
        pumpCaption(sourceID: metadata.sourceID)
        return .queued
    }

    private nonisolated static func hasValidTextIdentity(
        _ metadata: RealtimeAcceptedCaptionMetadata
    ) -> Bool {
        validLocalIdentifier(metadata.sourceID, maximumScalars: 256)
            && validLocalIdentifier(metadata.utteranceID, maximumScalars: 128)
            && validLocalIdentifier(metadata.sourceLanguageID, maximumScalars: 128)
            && validLocalIdentifier(metadata.targetLanguageID, maximumScalars: 128)
    }

    private nonisolated static func validLocalIdentifier(
        _ value: String,
        maximumScalars: Int
    ) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= maximumScalars else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private nonisolated static func isValid(
        interval: NormalizedAudioSampleInterval
    ) -> Bool {
        guard interval.lowerBound >= 0,
              interval.upperBound > interval.lowerBound,
              let startSample = UInt64(exactly: interval.lowerBound),
              let endSample = UInt64(exactly: interval.upperBound) else { return false }
        let (_, startOverflow) = startSample.multipliedReportingOverflow(by: 62_500)
        let (_, endOverflow) = endSample.multipliedReportingOverflow(by: 62_500)
        return !startOverflow && !endOverflow
    }

    private func makeRoomForSeenIdentity(in state: inout CaptionSourceState) -> Bool {
        guard state.seen.count >= 128 else { return true }
        var active = Set(state.queued.map {
            CaptionIdentity(captionID: $0.captionID, utteranceID: $0.utteranceID)
        })
        if let inFlight = state.inFlight {
            active.insert(CaptionIdentity(
                captionID: inFlight.captionID,
                utteranceID: inFlight.utteranceID
            ))
        }
        guard let index = state.seen.firstIndex(where: { !active.contains($0) }) else {
            return false
        }
        state.seen.remove(at: index)
        return true
    }

    private func audioWasAdmitted(
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        driverGeneration: Int,
        lease: RealtimeReaderLease,
        interval: NormalizedAudioSampleInterval
    ) {
        guard lease.isActive,
              let running = runningSources[sourceID],
              running.generation == driverGeneration,
              running.lease === lease,
              running.capture.input.sourceToken == sourceToken,
              running.capture.input.generation == captureGeneration,
              Self.isValid(interval: interval),
              var state = captionSourcesByID[sourceID],
              state.sourceToken == sourceToken,
              state.captureGeneration == captureGeneration,
              state.driverGeneration == driverGeneration else { return }

        if let last = state.admittedIntervals.last {
            guard interval.lowerBound >= last.lowerBound,
                  interval.upperBound > last.upperBound else {
                isolateCurrentSource(
                    sourceID: sourceID,
                    driverGeneration: driverGeneration,
                    failure: .malformedResponse
                )
                return
            }
            if interval.lowerBound == last.upperBound {
                state.admittedIntervals[state.admittedIntervals.count - 1] =
                    last.lowerBound..<interval.upperBound
            } else {
                state.admittedIntervals.append(interval)
            }
        } else {
            state.admittedIntervals.append(interval)
        }
        state.admittedEnd = max(state.admittedEnd ?? interval.upperBound, interval.upperBound)
        guard state.admittedIntervals.count <= 128 else {
            captionSourcesByID[sourceID] = state
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: .backpressure
            )
            return
        }
        captionSourcesByID[sourceID] = state
        pumpCaption(sourceID: sourceID)
    }

    private func captionCoverage(
        _ metadata: RealtimeAcceptedCaptionMetadata,
        state: CaptionSourceState
    ) -> CaptionCoverage {
        guard let interval = metadata.sampleInterval else {
            return .localOnly(.missingProvenance)
        }
        if let committedFrontier = state.committedFrontier,
           interval.lowerBound < committedFrontier {
            return .localOnly(.consumedAudio)
        }
        guard let first = state.admittedIntervals.first else { return .waiting }
        guard interval.lowerBound >= first.lowerBound else {
            return .localOnly(.missingAudioCoverage)
        }

        var coveredThrough = interval.lowerBound
        for admitted in state.admittedIntervals {
            if admitted.upperBound <= coveredThrough { continue }
            if admitted.lowerBound > coveredThrough {
                return .localOnly(.missingAudioCoverage)
            }
            coveredThrough = admitted.upperBound
            if coveredThrough >= interval.upperBound { return .covered }
        }
        return .waiting
    }

    private func pumpCaption(sourceID: String) {
        guard var running = runningSources[sourceID], running.lease.isActive,
              var state = captionSourcesByID[sourceID],
              state.sourceToken == running.capture.input.sourceToken,
              state.captureGeneration == running.capture.input.generation,
              state.driverGeneration == running.generation,
              state.alias == running.alias,
              state.inFlight == nil else { return }

        while let metadata = state.queued.first {
            switch captionCoverage(metadata, state: state) {
            case .waiting:
                captionSourcesByID[sourceID] = state
                return
            case .localOnly(let reason):
                state.queued.removeFirst()
                captionSourcesByID[sourceID] = state
                captionDispositionHandler(metadata, .localOnly(reason))
            case .covered:
                guard let interval = metadata.sampleInterval,
                      let startSample = UInt64(exactly: interval.lowerBound),
                      let endSample = UInt64(exactly: interval.upperBound) else {
                    state.queued.removeFirst()
                    captionSourcesByID[sourceID] = state
                    captionDispositionHandler(metadata, .localOnly(.invalidMetadata))
                    continue
                }
                let (startNanoseconds, startOverflow) = startSample.multipliedReportingOverflow(by: 62_500)
                let (endNanoseconds, endOverflow) = endSample.multipliedReportingOverflow(by: 62_500)
                guard !startOverflow, !endOverflow, endNanoseconds > startNanoseconds else {
                    state.queued.removeFirst()
                    captionSourcesByID[sourceID] = state
                    captionDispositionHandler(metadata, .localOnly(.invalidMetadata))
                    continue
                }

                state.queued.removeFirst()
                state.inFlight = metadata
                state.commitSucceeded = false
                state.stashedEvents.removeAll(keepingCapacity: true)
                captionSourcesByID[sourceID] = state
                let utterance = RealtimeUtterance(
                    sourceAlias: running.alias,
                    generation: running.generation,
                    captionID: metadata.captionID,
                    utteranceID: metadata.utteranceID,
                    startMonotonicNanoseconds: startNanoseconds,
                    endMonotonicNanoseconds: endNanoseconds,
                    requiresPreciseSampleCoverage: true
                )
                let driver = running.driver
                let driverGeneration = running.generation
                let lease = running.lease
                let token = running.capture.input.sourceToken
                let captureGeneration = running.capture.input.generation
                let commitTask = Task { [weak self] in
                    do {
                        try await driver.commit(utterance)
                        await self?.captionCommitDidFinish(
                            metadata,
                            sourceID: sourceID,
                            sourceToken: token,
                            captureGeneration: captureGeneration,
                            driverGeneration: driverGeneration,
                            lease: lease,
                            failure: nil
                        )
                    } catch {
                        await self?.captionCommitDidFinish(
                            metadata,
                            sourceID: sourceID,
                            sourceToken: token,
                            captureGeneration: captureGeneration,
                            driverGeneration: driverGeneration,
                            lease: lease,
                            failure: Self.failureCode(for: error)
                        )
                    }
                }
                running.captionPump = commitTask
                runningSources[sourceID] = running
                return
            }
        }
        captionSourcesByID[sourceID] = state
    }

    private func captionCommitDidFinish(
        _ metadata: RealtimeAcceptedCaptionMetadata,
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        driverGeneration: Int,
        lease: RealtimeReaderLease,
        failure: RealtimeFailureCode?
    ) {
        guard lease.isActive,
              let running = runningSources[sourceID],
              running.generation == driverGeneration,
              running.lease === lease,
              running.capture.input.sourceToken == sourceToken,
              running.capture.input.generation == captureGeneration,
              var state = captionSourcesByID[sourceID],
              state.sourceToken == sourceToken,
              state.captureGeneration == captureGeneration,
              state.driverGeneration == driverGeneration,
              state.inFlight?.captionID == metadata.captionID,
              state.inFlight?.utteranceID == metadata.utteranceID else { return }

        if let failure {
            state.stashedEvents.removeAll()
            captionSourcesByID[sourceID] = state
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: failure
            )
            return
        }
        guard let interval = metadata.sampleInterval else {
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: .malformedResponse
            )
            return
        }

        state.committedFrontier = max(state.committedFrontier ?? interval.upperBound, interval.upperBound)
        state.admittedIntervals = state.admittedIntervals.compactMap { admitted in
            guard admitted.upperBound > interval.upperBound else { return nil }
            if admitted.lowerBound < interval.upperBound {
                return interval.upperBound..<admitted.upperBound
            }
            return admitted
        }
        state.commitSucceeded = true
        let stashed = state.stashedEvents
        state.stashedEvents.removeAll(keepingCapacity: true)
        captionSourcesByID[sourceID] = state

        for event in stashed {
            guard runningSources[sourceID]?.generation == driverGeneration,
                  captionSourcesByID[sourceID]?.inFlight?.captionID == metadata.captionID else { return }
            processInFlightEvent(
                event,
                metadata: metadata,
                sourceID: sourceID,
                sourceToken: sourceToken,
                captureGeneration: captureGeneration,
                alias: running.alias,
                driverGeneration: driverGeneration
            )
        }
    }

    #if DEBUG
    func setBeforeCancellationCleanupForTesting(_ operation: (@Sendable () async -> Void)?) {
        beforeCancellationCleanupForTesting = operation
    }

    func setInputDidFinishTestingHooks(
        before: (@Sendable () async -> Void)?,
        after: (@Sendable () -> Void)?
    ) {
        beforeInputDidFinishForTesting = before
        afterInputDidFinishForTesting = after
    }

    func setBeforeProviderEventDeliveryForTesting(_ operation: (@Sendable () async -> Void)?) {
        beforeProviderEventDeliveryForTesting = operation
    }

    private func waitBeforeProviderEventDeliveryForTesting() async {
        let operation = beforeProviderEventDeliveryForTesting
        await operation?()
    }
    #endif

    /// Replaces the current set with isolated drivers for enabled, successfully captured sources.
    /// A replacement using an already-consumed PCM input is rejected and tears down the old set.
    /// The caller gates this operation on session-specific disclosure. It streams PCM
    /// to isolated drivers but does not commit caption intervals on its own.
    func start(
        captures: [NativeRealtimeCaptureSource],
        settings: NativeRealtimeSettings
    ) async -> [NativeRealtimeStartedSource] {
        var seenSourceIDs = Set<String>()
        let optedIn = captures.filter {
            settings.isEnabled(for: $0.sourceID) && seenSourceIDs.insert($0.sourceID).inserted
        }
        let reusesExistingInput = optedIn.contains(where: isAlreadyConsumedCapture)
        var containsSharedInput = false
        if optedIn.count > 1 {
            for firstIndex in 0..<(optedIn.count - 1) {
                for secondIndex in (firstIndex + 1)..<optedIn.count
                where optedIn[firstIndex].input.isSameCapture(as: optedIn[secondIndex].input) {
                    containsSharedInput = true
                }
            }
        }
        let inputsAreInvalid = reusesExistingInput || containsSharedInput
        lifecycleGeneration &+= 1
        let startupGeneration = lifecycleGeneration
        let cancellationToken = StartupCancellationToken()
        let supersededStartupCaptures = Array(startupCapturesBySourceID.values)
        captionSourcesByID.removeAll()
        pendingAudioFailureReports.removeAll()
        startupCapturesBySourceID = Dictionary(
            optedIn.map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for capture in optedIn {
            captureRegistrationHandler(RealtimeCaptureRegistration(
                sourceID: capture.sourceID,
                sourceToken: capture.input.sourceToken,
                captureGeneration: capture.input.generation
            ))
        }
        removedSourceIDsDuringStartup.removeAll()
        let finishObservers = optedIn.filter { !inputsAreInvalid && !$0.input.isConsumed }.map { capture in
            Task { [weak self] in
                let error = await capture.input.waitUntilFinished()
                guard !Task.isCancelled, !cancellationToken.isCancelled else { return }
                await self?.inputDidFinish(
                    sourceID: capture.sourceID,
                    startupGeneration: startupGeneration,
                    cancellationToken: cancellationToken,
                    error: error
                )
            }
        }
        defer { finishObservers.forEach { $0.cancel() } }
        for capture in supersededStartupCaptures {
            capture.input.finish(error: .sourceSuperseded)
        }
        let cancelStartupSynchronously: @Sendable () -> Void = {
            cancellationToken.cancel()
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
            Task { await self.cancelStartup(generation: startupGeneration) }
        }
        defer {
            if lifecycleGeneration == startupGeneration {
                startupCapturesBySourceID.removeAll()
                removedSourceIDsDuringStartup.removeAll()
            }
        }
        // Publish replacement captures first so concurrent removal can tombstone this
        // startup generation. Then synchronously revoke every running predecessor
        // before joining an older stop task; an unrelated slow stop must not leave a
        // previous source able to continue sending audio during replacement.
        let previous = detachAllSources()
        scheduleStops(for: previous)
        await withTaskCancellationHandler {
            await waitForAllStoppingSources()
        } onCancel: {
            cancelStartupSynchronously()
        }
        guard !Task.isCancelled, !cancellationToken.isCancelled else {
            await cancelStartup(generation: startupGeneration)
            return []
        }
        guard lifecycleGeneration == startupGeneration else {
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
            return []
        }
        if inputsAreInvalid {
            failUnstartedSources(optedIn, with: .invalidConfiguration)
            return []
        }
        guard !optedIn.isEmpty else { return [] }
        for capture in optedIn {
            rejectTerminatedCapture(capture)
        }
        guard optedIn.contains(where: { !removedSourceIDsDuringStartup.contains($0.sourceID) }) else {
            return []
        }

        let credential: String?
        do {
            guard let reference = settings.credentialReference else {
                if lifecycleGeneration == startupGeneration {
                    failUnstartedSources(optedIn, with: .invalidConfiguration)
                }
                return []
            }
            credential = try await withTaskCancellationHandler {
                try await credentialStore.load(reference: reference)
            } onCancel: {
                cancelStartupSynchronously()
            }
            guard !Task.isCancelled, !cancellationToken.isCancelled else {
                await cancelStartup(generation: startupGeneration)
                return []
            }
            guard lifecycleGeneration == startupGeneration else {
                optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
                return []
            }
            guard let credential,
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  credential.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                failUnstartedSources(optedIn, with: .invalidConfiguration)
                return []
            }
        } catch {
            if Task.isCancelled || cancellationToken.isCancelled {
                await cancelStartup(generation: startupGeneration)
                return []
            }
            if lifecycleGeneration == startupGeneration {
                failUnstartedSources(optedIn, with: .invalidConfiguration)
            } else {
                optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
            }
            return []
        }

        let aliases = RealtimeSourceAliases(sourceIDs: optedIn.map(\.sourceID))
        var driverSettings = settings
        driverSettings.enabledSourceIDs = []
        var reservations: [StartupReservation] = []
        for capture in optedIn {
            guard !Task.isCancelled,
                  !cancellationToken.isCancelled,
                  lifecycleGeneration == startupGeneration else { break }
            guard !removedSourceIDsDuringStartup.contains(capture.sourceID) else {
                capture.input.finish(error: .sourceSuperseded)
                continue
            }
            guard !rejectTerminatedCapture(capture) else { continue }
            guard let alias = aliases.alias(for: capture.sourceID) else { continue }
            let sourceGeneration = nextDriverGeneration
            nextDriverGeneration &+= 1
            let reservation = StartupReservation(
                capture: capture,
                alias: alias,
                generation: sourceGeneration,
                driver: driverFactory(driverSettings, credential, capture.role),
                lease: RealtimeReaderLease()
            )
            startingSources[capture.sourceID] = reservation.startingSource
            reservations.append(reservation)
        }
        guard !Task.isCancelled, !cancellationToken.isCancelled else {
            await cancelStartup(generation: startupGeneration)
            return []
        }
        guard lifecycleGeneration == startupGeneration else {
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
            return []
        }

        // Start every reserved driver independently. Each task activates its own
        // reader as soon as that driver's setup finishes, while this call gathers
        // results in reservation order for a deterministic return value.
        let sourceStartTasks = reservations.map { reservation in
            Task { [self] in
                await startReservedSource(
                    reservation,
                    startupGeneration: startupGeneration,
                    cancellationToken: cancellationToken
                )
            }
        }
        let cancellationReservations = reservations
        let started = await withTaskCancellationHandler {
            var results: [NativeRealtimeStartedSource] = []
            for task in sourceStartTasks {
                if let result = await task.value {
                    results.append(result)
                }
            }
            return results
        } onCancel: {
            cancellationToken.cancel()
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
            for reservation in cancellationReservations {
                reservation.lease.deactivate()
                reservation.capture.input.finish(error: .sourceSuperseded)
            }
            sourceStartTasks.forEach { $0.cancel() }
            Task { await self.cancelStartup(generation: startupGeneration) }
        }
        if lifecycleGeneration != startupGeneration {
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
        }
        guard !Task.isCancelled, !cancellationToken.isCancelled else {
            await cancelStartup(generation: startupGeneration)
            return []
        }
        return started.filter { runningSources[$0.sourceID]?.generation == $0.generation }
    }

    private func startReservedSource(
        _ reservation: StartupReservation,
        startupGeneration: Int,
        cancellationToken: StartupCancellationToken
    ) async -> NativeRealtimeStartedSource? {
        let capture = reservation.capture
        let sourceID = capture.sourceID

        guard !Task.isCancelled,
              !cancellationToken.isCancelled,
              lifecycleGeneration == startupGeneration,
              !removedSourceIDsDuringStartup.contains(sourceID),
              isCurrentReservation(reservation),
              !capture.input.isConsumed,
              capture.input.terminationError == nil else {
            capture.input.finish(error: .sourceSuperseded)
            await stopRevokedStart(reservation)
            return nil
        }

        do {
            try await reservation.driver.start(
                sourceAlias: reservation.alias,
                generation: reservation.generation
            )
        } catch {
            guard !Task.isCancelled,
                  !cancellationToken.isCancelled,
                  lifecycleGeneration == startupGeneration,
                  !removedSourceIDsDuringStartup.contains(sourceID),
                  isCurrentReservation(reservation) else {
                capture.input.finish(error: .sourceSuperseded)
                await stopRevokedStart(reservation)
                return nil
            }
            startingSources.removeValue(forKey: sourceID)
            reservation.lease.deactivate()
            removedSourceIDsDuringStartup.insert(sourceID)
            capture.input.finish(error: .sourceSuperseded)
            let stopping = scheduleStop(sourceID: sourceID, starting: reservation.startingSource)
            // Report while this startup identity is still current; a stop barrier
            // may allow a replacement to install a different failure handler.
            sourceFailureHandler(sourceID, Self.failureCode(for: error))
            await waitForStoppingSource(sourceID: sourceID, stopping)
            return nil
        }

        guard !Task.isCancelled,
              !cancellationToken.isCancelled,
              lifecycleGeneration == startupGeneration,
              !removedSourceIDsDuringStartup.contains(sourceID),
              isCurrentReservation(reservation),
              reservation.lease.isActive else {
            capture.input.finish(error: .sourceSuperseded)
            await stopRevokedStart(reservation)
            return nil
        }
        guard !capture.input.isConsumed,
              capture.input.terminationError == nil else {
            let terminalError = capture.input.terminationError
            startingSources.removeValue(forKey: sourceID)
            reservation.lease.deactivate()
            removedSourceIDsDuringStartup.insert(sourceID)
            capture.input.finish(error: .sourceSuperseded)
            let stopping = scheduleStop(sourceID: sourceID, starting: reservation.startingSource)
            if let failure = Self.failureCode(for: terminalError) {
                sourceFailureHandler(sourceID, failure)
            }
            await waitForStoppingSource(sourceID: sourceID, stopping)
            return nil
        }

        startingSources.removeValue(forKey: sourceID)
        var captionState = captionSourcesByID[sourceID] ?? CaptionSourceState(
            sourceToken: capture.input.sourceToken,
            captureGeneration: capture.input.generation
        )
        guard captionState.sourceToken == capture.input.sourceToken,
              captionState.captureGeneration == capture.input.generation else {
            capture.input.finish(error: .sourceSuperseded)
            let stopping = scheduleStop(sourceID: sourceID, starting: reservation.startingSource)
            await waitForStoppingSource(sourceID: sourceID, stopping)
            return nil
        }
        captionState.driverGeneration = reservation.generation
        captionState.alias = reservation.alias
        captionSourcesByID[sourceID] = captionState

        let audioReader = Task { [weak self] in
            let failure = await Self.readAudio(
                from: capture,
                alias: reservation.alias,
                generation: reservation.generation,
                driver: reservation.driver,
                lease: reservation.lease,
                onAdmission: { [weak self] interval in
                    await self?.audioWasAdmitted(
                        sourceID: sourceID,
                        sourceToken: capture.input.sourceToken,
                        captureGeneration: capture.input.generation,
                        driverGeneration: reservation.generation,
                        lease: reservation.lease,
                        interval: interval
                    )
                }
            )
            reservation.lease.deactivate()
            capture.input.finish(error: failure == nil ? nil : .sourceSuperseded)
            await self?.audioReaderDidFinish(
                sourceID: sourceID,
                generation: reservation.generation,
                startupGeneration: startupGeneration,
                cancellationToken: cancellationToken,
                failure: failure
            )
        }
        let eventReader = Task { [weak self] in
            let stream = await reservation.driver.events()
            guard !Task.isCancelled, reservation.lease.isActive else { return }
            for await event in stream {
                guard !Task.isCancelled, reservation.lease.isActive else { break }
#if DEBUG
                await self?.waitBeforeProviderEventDeliveryForTesting()
#endif
                guard !Task.isCancelled, reservation.lease.isActive else { break }
                await self?.providerEventDidArrive(
                    event,
                    sourceID: sourceID,
                    sourceToken: capture.input.sourceToken,
                    captureGeneration: capture.input.generation,
                    alias: reservation.alias,
                    driverGeneration: reservation.generation,
                    lease: reservation.lease
                )
                guard reservation.lease.isActive else { break }
            }
            guard !Task.isCancelled, reservation.lease.isActive else { return }
            await self?.eventReaderDidFinish(
                sourceID: sourceID,
                sourceToken: capture.input.sourceToken,
                captureGeneration: capture.input.generation,
                driverGeneration: reservation.generation,
                lease: reservation.lease
            )
        }
        runningSources[sourceID] = RunningSource(
            capture: capture,
            generation: reservation.generation,
            alias: reservation.alias,
            driver: reservation.driver,
            lease: reservation.lease,
            audioReader: audioReader,
            eventReader: eventReader,
            captionPump: nil
        )
        sourceReadyHandler(RealtimeSourceReadyIdentity(
            sourceID: sourceID,
            sourceToken: capture.input.sourceToken,
            captureGeneration: capture.input.generation,
            alias: reservation.alias,
            driverGeneration: reservation.generation
        ))
        pumpCaption(sourceID: sourceID)
        return NativeRealtimeStartedSource(
            sourceID: sourceID,
            alias: reservation.alias,
            generation: reservation.generation
        )
    }

    private func isCurrentReservation(_ reservation: StartupReservation) -> Bool {
        guard let pending = startingSources[reservation.capture.sourceID] else { return false }
        return pending.generation == reservation.generation
            && pending.lease === reservation.lease
            && pending.lease.isActive
    }

    private func stopRevokedStart(_ reservation: StartupReservation) async {
        let stopping = stoppingSources[reservation.capture.sourceID].flatMap {
            $0.driverGeneration == reservation.generation ? $0 : nil
        }
        // Cancel a late setup acknowledgement immediately. A removal may already
        // have an in-flight stop for this driver; waiting for that stop first can
        // deadlock drivers that only finish stopping after this post-ACK stop.
        await reservation.driver.stop()
        // Still join the removal/replacement stop that revoked this reservation so
        // neither caller can cross the shared lifecycle barrier early. Capture its
        // identity before the await so a replacement stop cannot be joined by ID.
        await waitForStoppingSource(sourceID: reservation.capture.sourceID, stopping)
    }

    func removeSource(sourceID: String) async {
        captionSourcesByID.removeValue(forKey: sourceID)
        pendingAudioFailureReports.removeValue(forKey: sourceID)
        if let capture = startupCapturesBySourceID[sourceID],
           removedSourceIDsDuringStartup.insert(sourceID).inserted {
            capture.input.finish(error: .sourceSuperseded)
        }
        let running = runningSources.removeValue(forKey: sourceID)
        let starting = startingSources.removeValue(forKey: sourceID)
        let stopping = scheduleStop(
            sourceID: sourceID,
            running: running,
            starting: starting
        )
        await waitForStoppingSource(sourceID: sourceID, stopping)
    }

    func stop() async {
        lifecycleGeneration &+= 1
        captionSourcesByID.removeAll()
        pendingAudioFailureReports.removeAll()
        let startupCaptures = Array(startupCapturesBySourceID.values)
        startupCapturesBySourceID.removeAll()
        removedSourceIDsDuringStartup.removeAll()
        startupCaptures.forEach { $0.input.finish(error: .sourceSuperseded) }
        let sources = detachAllSources()
        scheduleStops(for: sources)
        await waitForAllStoppingSources()
    }

    func activeSourceIDs() -> [String] {
        runningSources.keys.sorted()
    }

    #if DEBUG
    func lifecycleGenerationForTesting() -> Int {
        lifecycleGeneration
    }

    func startupSourceIDsForTesting() -> [String] {
        startupCapturesBySourceID.keys.sorted()
    }

    func audioFailureReportPendingForTesting(sourceID: String) -> Bool {
        pendingAudioFailureReports[sourceID] != nil
    }

    func waitForAudioFailureReportTasksForTesting() async {
        let tasks = Array(audioFailureReportTasks.values)
        for task in tasks {
            await task.value
        }
    }
    #endif

    private func inputDidFinish(
        sourceID: String,
        startupGeneration: Int,
        cancellationToken: StartupCancellationToken,
        error: RealtimePCM16AudioStreamError?
    ) async {
        #if DEBUG
        let beforeProcessing = beforeInputDidFinishForTesting
        let afterProcessing = afterInputDidFinishForTesting
        defer { afterProcessing?() }
        if let beforeProcessing {
            await beforeProcessing()
        }
        #endif
        guard !cancellationToken.isCancelled,
              lifecycleGeneration == startupGeneration,
              let capture = startupCapturesBySourceID[sourceID],
              runningSources[sourceID] == nil,
              removedSourceIDsDuringStartup.insert(sourceID).inserted else { return }
        capture.input.finish(error: error)
        guard let pending = startingSources.removeValue(forKey: sourceID) else {
            if let failure = Self.failureCode(for: error) {
                sourceFailureHandler(sourceID, failure)
            }
            return
        }
        let stopping = scheduleStop(sourceID: sourceID, starting: pending)
        // Report while this startup identity is still current. Waiting for the
        // shared stop can let start() finish and clear its capture metadata first.
        // The lease/input have already been revoked synchronously above.
        if let failure = Self.failureCode(for: error) {
            sourceFailureHandler(sourceID, failure)
        }
        await waitForStoppingSource(sourceID: sourceID, stopping)
    }

    private func isAlreadyConsumedCapture(_ capture: NativeRealtimeCaptureSource) -> Bool {
        runningSources.values.contains { $0.capture.input.isSameCapture(as: capture.input) }
            || startingSources.values.contains { $0.capture.input.isSameCapture(as: capture.input) }
            || startupCapturesBySourceID.values.contains { $0.input.isSameCapture(as: capture.input) }
    }

    @discardableResult
    private func rejectTerminatedCapture(_ capture: NativeRealtimeCaptureSource) -> Bool {
        let error = capture.input.terminationError
        guard capture.input.isConsumed || error != nil else { return false }
        guard removedSourceIDsDuringStartup.insert(capture.sourceID).inserted else { return true }
        capture.input.finish(error: error)
        sourceFailureHandler(capture.sourceID, Self.failureCode(for: error) ?? .invalidConfiguration)
        return true
    }

    private func detachAllSources() -> (running: [RunningSource], starting: [StartingSource]) {
        let sources = Array(runningSources.values)
        runningSources.removeAll()
        let starting = Array(startingSources.values)
        startingSources.removeAll()
        for source in sources {
            source.lease.deactivate()
            source.capture.input.finish(error: .sourceSuperseded)
            source.audioReader.cancel()
            source.eventReader.cancel()
            source.captionPump?.cancel()
        }
        for source in starting {
            source.lease.deactivate()
            source.capture.input.finish(error: .sourceSuperseded)
        }
        return (sources, starting)
    }

    private func cancelStartup(generation cancelledGeneration: Int) async {
        guard lifecycleGeneration == cancelledGeneration else { return }
        #if DEBUG
        if let beforeCancellationCleanupForTesting {
            await beforeCancellationCleanupForTesting()
        }
        #endif
        // The test hook may suspend while another lifecycle operation advances.
        guard lifecycleGeneration == cancelledGeneration else { return }
        lifecycleGeneration &+= 1
        captionSourcesByID.removeAll()
        pendingAudioFailureReports.removeAll()
        let captures = Array(startupCapturesBySourceID.values)
        startupCapturesBySourceID.removeAll()
        removedSourceIDsDuringStartup.removeAll()
        captures.forEach { $0.input.finish(error: .sourceSuperseded) }
        let sources = detachAllSources()
        scheduleStops(for: sources)
        await waitForAllStoppingSources()
    }

    private func scheduleStops(
        for sources: (running: [RunningSource], starting: [StartingSource])
    ) {
        for source in sources.running {
            _ = scheduleStop(sourceID: source.capture.sourceID, running: source)
        }
        for source in sources.starting {
            _ = scheduleStop(sourceID: source.capture.sourceID, starting: source)
        }
    }

    private func scheduleStop(
        sourceID: String,
        running: RunningSource? = nil,
        starting: StartingSource? = nil
    ) -> StoppingSource? {
        if let existing = stoppingSources[sourceID] {
            return existing
        }
        guard let driverGeneration = running?.generation ?? starting?.generation else { return nil }

        // Revocation is synchronous at the coordinator boundary. The shared task
        // below owns only the potentially slow driver shutdown and reader join.
        if let running {
            running.lease.deactivate()
            running.capture.input.finish(error: .sourceSuperseded)
            running.audioReader.cancel()
            running.eventReader.cancel()
            running.captionPump?.cancel()
        }
        if let starting {
            starting.lease.deactivate()
            starting.capture.input.finish(error: .sourceSuperseded)
        }

        let generation = nextStopGeneration
        nextStopGeneration &+= 1
        let task = Task { [running, starting] in
            if let running {
                await Self.stop([running])
            }
            if let starting {
                await Self.stop([starting])
            }
        }
        let stopping = StoppingSource(
            generation: generation,
            driverGeneration: driverGeneration,
            task: task
        )
        stoppingSources[sourceID] = stopping
        return stopping
    }

    private func waitForAllStoppingSources() async {
        let sources = Array(stoppingSources)
        for (sourceID, stopping) in sources {
            await waitForStoppingSource(sourceID: sourceID, stopping)
        }
    }

    private func waitForStoppingSource(
        sourceID: String,
        _ stopping: StoppingSource?
    ) async {
        guard let stopping else { return }
        await stopping.task.value
        guard stoppingSources[sourceID]?.generation == stopping.generation else { return }
        stoppingSources.removeValue(forKey: sourceID)
    }

    private nonisolated static func stop(
        _ sources: [RunningSource],
        streamError: RealtimePCM16AudioStreamError? = .sourceSuperseded
    ) async {
        for source in sources {
            source.lease.deactivate()
            source.capture.input.finish(error: streamError)
            source.audioReader.cancel()
            source.eventReader.cancel()
            source.captionPump?.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await source.driver.stop() }
            }
        }
        for source in sources {
            await source.audioReader.value
            await source.eventReader.value
            if let captionPump = source.captionPump {
                await captionPump.value
            }
        }
    }

    private nonisolated static func stop(_ sources: [StartingSource]) async {
        for source in sources {
            source.lease.deactivate()
            source.capture.input.finish(error: .sourceSuperseded)
        }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await source.driver.stop() }
            }
        }
    }

    private func providerEventDidArrive(
        _ event: RealtimeProviderEvent,
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        alias: String,
        driverGeneration: Int,
        lease: RealtimeReaderLease
    ) {
        guard lease.isActive,
              let running = runningSources[sourceID],
              running.generation == driverGeneration,
              running.alias == alias,
              running.lease === lease,
              running.capture.input.sourceToken == sourceToken,
              running.capture.input.generation == captureGeneration else { return }

        switch event {
        case .correctedText(let eventAlias, let generation, let captionID, let utteranceID, let text):
            guard eventAlias == alias, generation == driverGeneration,
                  let state = captionSourcesByID[sourceID],
                  let metadata = state.inFlight,
                  metadata.captionID == captionID,
                  metadata.utteranceID == utteranceID,
                  let safeText = Self.boundedProviderText(text) else { return }
            let boundedEvent = RealtimeProviderEvent.correctedText(
                sourceAlias: eventAlias,
                generation: generation,
                captionID: captionID,
                utteranceID: utteranceID,
                text: safeText
            )
            if state.commitSucceeded {
                processInFlightEvent(
                    boundedEvent,
                    metadata: metadata,
                    sourceID: sourceID,
                    sourceToken: sourceToken,
                    captureGeneration: captureGeneration,
                    alias: alias,
                    driverGeneration: driverGeneration
                )
            } else {
                stashInFlightEvent(boundedEvent, sourceID: sourceID, driverGeneration: driverGeneration)
            }
        case .utteranceCompleted(let eventAlias, let generation, let captionID, let utteranceID):
            guard eventAlias == alias, generation == driverGeneration,
                  let state = captionSourcesByID[sourceID],
                  let metadata = state.inFlight,
                  metadata.captionID == captionID,
                  metadata.utteranceID == utteranceID else { return }
            let terminal = RealtimeProviderEvent.utteranceCompleted(
                sourceAlias: eventAlias,
                generation: generation,
                captionID: captionID,
                utteranceID: utteranceID
            )
            if state.commitSucceeded {
                processInFlightEvent(
                    terminal,
                    metadata: metadata,
                    sourceID: sourceID,
                    sourceToken: sourceToken,
                    captureGeneration: captureGeneration,
                    alias: alias,
                    driverGeneration: driverGeneration
                )
            } else {
                stashInFlightEvent(terminal, sourceID: sourceID, driverGeneration: driverGeneration)
            }
        case .suggestion(let eventAlias, let generation, let text):
            guard eventAlias == alias, generation == driverGeneration,
                  let state = captionSourcesByID[sourceID],
                  let metadata = state.inFlight,
                  let safeText = Self.boundedProviderText(text) else { return }
            let suggestion = RealtimeProviderEvent.suggestion(
                sourceAlias: eventAlias,
                generation: generation,
                text: safeText
            )
            if state.commitSucceeded {
                processInFlightEvent(
                    suggestion,
                    metadata: metadata,
                    sourceID: sourceID,
                    sourceToken: sourceToken,
                    captureGeneration: captureGeneration,
                    alias: alias,
                    driverGeneration: driverGeneration
                )
            } else {
                stashInFlightEvent(suggestion, sourceID: sourceID, driverGeneration: driverGeneration)
            }
        case .expired(let eventAlias, let generation):
            guard eventAlias == alias, generation == driverGeneration else { return }
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: .sessionExpired
            )
        case .failure(let eventAlias, let generation, let failure):
            guard eventAlias == alias, generation == driverGeneration else { return }
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: failure
            )
        }
    }

    private nonisolated static func boundedProviderText(_ text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 4_096,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar == "\n" || scalar == "\t"
              }) else { return nil }
        return text
    }

    private func stashInFlightEvent(
        _ event: RealtimeProviderEvent,
        sourceID: String,
        driverGeneration: Int
    ) {
        guard var state = captionSourcesByID[sourceID],
              state.driverGeneration == driverGeneration,
              state.inFlight != nil else { return }
        guard state.stashedEvents.count < 8 else {
            isolateCurrentSource(
                sourceID: sourceID,
                driverGeneration: driverGeneration,
                failure: .backpressure
            )
            return
        }
        state.stashedEvents.append(event)
        captionSourcesByID[sourceID] = state
    }

    private func processInFlightEvent(
        _ event: RealtimeProviderEvent,
        metadata: RealtimeAcceptedCaptionMetadata,
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        alias: String,
        driverGeneration: Int
    ) {
        guard var state = captionSourcesByID[sourceID],
              state.sourceToken == sourceToken,
              state.captureGeneration == captureGeneration,
              state.driverGeneration == driverGeneration,
              state.inFlight?.captionID == metadata.captionID,
              state.inFlight?.utteranceID == metadata.utteranceID,
              state.commitSucceeded else { return }

        switch event {
        case .correctedText(let eventAlias, let generation, let captionID, let utteranceID, let text):
            guard eventAlias == alias, generation == driverGeneration,
                  captionID == metadata.captionID, utteranceID == metadata.utteranceID,
                  let safeText = Self.boundedProviderText(text) else { return }
            captionEventHandler(RealtimeCaptionEventEnvelope(
                sourceID: sourceID,
                sourceToken: sourceToken,
                captureGeneration: captureGeneration,
                sourceAlias: alias,
                driverGeneration: driverGeneration,
                captionID: metadata.captionID,
                utteranceID: metadata.utteranceID,
                sourceLanguageID: metadata.sourceLanguageID,
                targetLanguageID: metadata.targetLanguageID,
                kind: .correctedText(safeText)
            ))
        case .suggestion(let eventAlias, let generation, let text):
            guard eventAlias == alias, generation == driverGeneration,
                  let safeText = Self.boundedProviderText(text) else { return }
            captionEventHandler(RealtimeCaptionEventEnvelope(
                sourceID: sourceID,
                sourceToken: sourceToken,
                captureGeneration: captureGeneration,
                sourceAlias: alias,
                driverGeneration: driverGeneration,
                captionID: metadata.captionID,
                utteranceID: metadata.utteranceID,
                sourceLanguageID: metadata.sourceLanguageID,
                targetLanguageID: metadata.targetLanguageID,
                kind: .suggestion(safeText)
            ))
        case .utteranceCompleted(let eventAlias, let generation, let captionID, let utteranceID):
            guard eventAlias == alias, generation == driverGeneration,
                  captionID == metadata.captionID, utteranceID == metadata.utteranceID else { return }
            state.inFlight = nil
            state.commitSucceeded = false
            state.stashedEvents.removeAll(keepingCapacity: true)
            captionSourcesByID[sourceID] = state
            captionEventHandler(RealtimeCaptionEventEnvelope(
                sourceID: sourceID,
                sourceToken: sourceToken,
                captureGeneration: captureGeneration,
                sourceAlias: alias,
                driverGeneration: driverGeneration,
                captionID: metadata.captionID,
                utteranceID: metadata.utteranceID,
                sourceLanguageID: metadata.sourceLanguageID,
                targetLanguageID: metadata.targetLanguageID,
                kind: .utteranceCompleted
            ))
            pumpCaption(sourceID: sourceID)
        case .expired, .failure:
            break
        }
    }

    private func eventReaderDidFinish(
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        driverGeneration: Int,
        lease: RealtimeReaderLease
    ) {
        guard lease.isActive,
              let running = runningSources[sourceID],
              running.generation == driverGeneration,
              running.lease === lease,
              running.capture.input.sourceToken == sourceToken,
              running.capture.input.generation == captureGeneration else { return }
        isolateCurrentSource(
            sourceID: sourceID,
            driverGeneration: driverGeneration,
            failure: .connectionFailed
        )
    }

    private func isolateCaptionSource(
        sourceID: String,
        sourceToken: UUID,
        captureGeneration: UInt64,
        failure: RealtimeFailureCode
    ) {
        if let running = runningSources[sourceID],
           running.capture.input.sourceToken == sourceToken,
           running.capture.input.generation == captureGeneration {
            runningSources.removeValue(forKey: sourceID)
            captionSourcesByID.removeValue(forKey: sourceID)
            running.lease.deactivate()
            running.capture.input.finish(error: .backpressureExceeded)
            _ = scheduleStop(sourceID: sourceID, running: running)
            sourceFailureHandler(sourceID, failure)
            return
        }
        if let starting = startingSources[sourceID],
           starting.capture.input.sourceToken == sourceToken,
           starting.capture.input.generation == captureGeneration {
            startingSources.removeValue(forKey: sourceID)
            removedSourceIDsDuringStartup.insert(sourceID)
            captionSourcesByID.removeValue(forKey: sourceID)
            starting.lease.deactivate()
            starting.capture.input.finish(error: .backpressureExceeded)
            _ = scheduleStop(sourceID: sourceID, starting: starting)
            sourceFailureHandler(sourceID, failure)
            return
        }
        if let capture = startupCapturesBySourceID[sourceID],
           capture.input.sourceToken == sourceToken,
           capture.input.generation == captureGeneration {
            removedSourceIDsDuringStartup.insert(sourceID)
            captionSourcesByID.removeValue(forKey: sourceID)
            capture.input.finish(error: .backpressureExceeded)
            sourceFailureHandler(sourceID, failure)
        }
    }

    private func isolateCurrentSource(
        sourceID: String,
        driverGeneration: Int,
        failure: RealtimeFailureCode
    ) {
        guard let running = runningSources[sourceID],
              running.generation == driverGeneration else { return }
        runningSources.removeValue(forKey: sourceID)
        captionSourcesByID.removeValue(forKey: sourceID)
        running.lease.deactivate()
        running.capture.input.finish(error: .sourceSuperseded)
        _ = scheduleStop(sourceID: sourceID, running: running)
        sourceFailureHandler(sourceID, failure)
    }

    private func audioReaderDidFinish(
        sourceID: String,
        generation finishedGeneration: Int,
        startupGeneration: Int,
        cancellationToken: StartupCancellationToken,
        failure: RealtimeFailureCode?
    ) {
        guard let running = runningSources[sourceID],
              running.generation == finishedGeneration else { return }
        runningSources.removeValue(forKey: sourceID)
        removedSourceIDsDuringStartup.insert(sourceID)
        running.lease.deactivate()
        running.capture.input.finish(error: failure == nil ? nil : .sourceSuperseded)
        if let state = captionSourcesByID.removeValue(forKey: sourceID) {
            for metadata in state.queued {
                let disposition: RealtimeCaptionSubmissionDisposition
                switch captionCoverage(metadata, state: state) {
                case .localOnly(.missingAudioCoverage):
                    disposition = .localOnly(.missingAudioCoverage)
                case .waiting, .covered, .localOnly:
                    disposition = .localOnly(.unavailableSource)
                }
                captionDispositionHandler(metadata, disposition)
            }
            if let inFlight = state.inFlight, !state.commitSucceeded {
                captionDispositionHandler(inFlight, .localOnly(.unavailableSource))
            }
        }
        let stopping = scheduleStop(sourceID: sourceID, running: running)
        if let failure, let stopping {
            let report = AudioFailureReport(
                reportID: UUID(),
                sourceID: sourceID,
                sourceToken: running.capture.input.sourceToken,
                captureGeneration: running.capture.input.generation,
                driverGeneration: finishedGeneration,
                startupGeneration: startupGeneration,
                failureHandlerGeneration: sourceFailureHandlerGeneration,
                cancellationToken: cancellationToken,
                failure: failure
            )
            pendingAudioFailureReports[sourceID] = report
            let reportTask = Task { [weak self] in
                await stopping.task.value
                await self?.reportAudioReaderFailure(report)
            }
            audioFailureReportTasks[report.reportID] = reportTask
        }
    }

    private func reportAudioReaderFailure(_ report: AudioFailureReport) {
        guard pendingAudioFailureReports[report.sourceID]?.reportID == report.reportID else {
            audioFailureReportTasks.removeValue(forKey: report.reportID)
            return
        }
        pendingAudioFailureReports.removeValue(forKey: report.sourceID)
        audioFailureReportTasks.removeValue(forKey: report.reportID)
        guard !report.cancellationToken.isCancelled,
              lifecycleGeneration == report.startupGeneration,
              sourceFailureHandlerGeneration == report.failureHandlerGeneration,
              runningSources[report.sourceID]?.generation != report.driverGeneration else { return }
        sourceFailureHandler(report.sourceID, report.failure)
    }

    private func failUnstartedSources(
        _ sources: [NativeRealtimeCaptureSource],
        with failure: RealtimeFailureCode
    ) {
        for source in sources {
            let terminalFailure = Self.failureCode(for: source.input.terminationError)
            source.input.finish(error: .sourceSuperseded)
            if !removedSourceIDsDuringStartup.contains(source.sourceID) {
                sourceFailureHandler(source.sourceID, terminalFailure ?? failure)
            }
        }
    }

    private nonisolated static func readAudio(
        from capture: NativeRealtimeCaptureSource,
        alias: String,
        generation: Int,
        driver: any RealtimeSessionDriving,
        lease: RealtimeReaderLease,
        onAdmission: @escaping @Sendable (NormalizedAudioSampleInterval) async -> Void
    ) async -> RealtimeFailureCode? {
        var previousTimestamp: UInt64?
        var previousSampleEnd: UInt64?
        do {
            while !Task.isCancelled, lease.isActive {
                guard let chunk = try await capture.input.nextChunk() else { return nil }
                guard lease.isActive else { return nil }
                let (pcmByteCount, pcmByteCountOverflow) = chunk.frameCount.multipliedReportingOverflow(by: 2)
                guard !pcmByteCountOverflow,
                      chunk.sourceToken == capture.input.sourceToken,
                      chunk.generation == capture.input.generation,
                      chunk.sampleRate == 16_000,
                      chunk.frameCount > 0,
                      chunk.pcm16LE.count == pcmByteCount,
                      previousTimestamp.map({ chunk.captureTimestampNanoseconds >= $0 }) ?? true,
                      chunk.sampleInterval.lowerBound >= 0,
                      chunk.sampleInterval.upperBound > chunk.sampleInterval.lowerBound,
                      let expectedFrameCount = Int64(exactly: chunk.frameCount),
                      chunk.sampleInterval.upperBound - chunk.sampleInterval.lowerBound == expectedFrameCount,
                      let startSample = UInt64(exactly: chunk.sampleInterval.lowerBound),
                      let endSample = UInt64(exactly: chunk.sampleInterval.upperBound),
                      previousSampleEnd.map({ startSample >= $0 }) ?? true else {
                    return .malformedResponse
                }
                let (startNanoseconds, startOverflow) = startSample.multipliedReportingOverflow(by: 62_500)
                let (endNanoseconds, endOverflow) = endSample.multipliedReportingOverflow(by: 62_500)
                guard !startOverflow, !endOverflow else { return .malformedResponse }

                // Arrival timestamps are retained as provenance only. Sample-clock
                // boundaries come exclusively from the normalized PCM interval.
                previousTimestamp = chunk.captureTimestampNanoseconds
                previousSampleEnd = endSample
                let audio = RealtimeAudioChunk(
                    sourceAlias: alias,
                    generation: generation,
                    capturedAtMonotonicNanoseconds: chunk.captureTimestampNanoseconds,
                    startMonotonicNanoseconds: startNanoseconds,
                    endMonotonicNanoseconds: endNanoseconds,
                    pcm16LEData: chunk.pcm16LE,
                    sampleRate: chunk.sampleRate
                )
                guard !Task.isCancelled, lease.isActive else { return nil }
                try await driver.sendAudioChunk(audio)
                guard !Task.isCancelled,
                      lease.isActive,
                      chunk.sourceToken == capture.input.sourceToken,
                      chunk.generation == capture.input.generation else { return nil }
                await onAdmission(chunk.sampleInterval)
            }
            return nil
        } catch let error as RealtimePCM16AudioStreamError {
            guard lease.isActive else { return nil }
            switch error {
            case .backpressureExceeded: return .backpressure
            case .invalidAudioChunk: return .malformedResponse
            case .sourceSuperseded, .concurrentRead: return nil
            }
        } catch {
            guard lease.isActive else { return nil }
            return failureCode(for: error)
        }
    }

    private nonisolated static func failureCode(for error: any Error) -> RealtimeFailureCode {
        (error as? RealtimeFailureCode) ?? .connectionFailed
    }

    private nonisolated static func failureCode(
        for streamError: RealtimePCM16AudioStreamError?
    ) -> RealtimeFailureCode? {
        switch streamError {
        case .backpressureExceeded: return .backpressure
        case .invalidAudioChunk: return .malformedResponse
        case .sourceSuperseded, .concurrentRead, nil: return nil
        }
    }
}

private final class RealtimeReaderLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
