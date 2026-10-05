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

    private struct RunningSource {
        let capture: NativeRealtimeCaptureSource
        let generation: Int
        let driver: any RealtimeSessionDriving
        let lease: RealtimeReaderLease
        let reader: Task<Void, Never>
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
    #if DEBUG
    private var beforeCancellationCleanupForTesting: (@Sendable () async -> Void)?
    private var beforeInputDidFinishForTesting: (@Sendable () async -> Void)?
    private var afterInputDidFinishForTesting: (@Sendable () -> Void)?
    #endif
    private var lifecycleGeneration = 0
    private var nextDriverGeneration = 0
    private var runningSources: [String: RunningSource] = [:]
    private var startingSources: [String: StartingSource] = [:]
    private var stoppingSources: [String: StoppingSource] = [:]
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
        startupCapturesBySourceID = Dictionary(
            optedIn.map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        let reader = Task { [weak self] in
            let failure = await Self.readAudio(
                from: capture,
                alias: reservation.alias,
                generation: reservation.generation,
                driver: reservation.driver,
                lease: reservation.lease
            )
            reservation.lease.deactivate()
            capture.input.finish(error: failure == nil ? nil : .sourceSuperseded)
            await reservation.driver.stop()
            await self?.readerDidFinish(
                sourceID: sourceID,
                generation: reservation.generation,
                cancellationToken: cancellationToken,
                failure: failure
            )
        }
        runningSources[sourceID] = RunningSource(
            capture: capture,
            generation: reservation.generation,
            driver: reservation.driver,
            lease: reservation.lease,
            reader: reader
        )
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
            source.reader.cancel()
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
            running.reader.cancel()
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
            source.reader.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await source.driver.stop() }
            }
        }
        for source in sources {
            await source.reader.value
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

    private func readerDidFinish(
        sourceID: String,
        generation finishedGeneration: Int,
        cancellationToken: StartupCancellationToken,
        failure: RealtimeFailureCode?
    ) {
        guard runningSources[sourceID]?.generation == finishedGeneration else { return }
        removedSourceIDsDuringStartup.insert(sourceID)
        runningSources.removeValue(forKey: sourceID)
        if !cancellationToken.isCancelled, let failure {
            sourceFailureHandler(sourceID, failure)
        }
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
        lease: RealtimeReaderLease
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
