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

    private let credentialStore: RealtimeCredentialStore
    private let driverFactory: DriverFactory
    private let sourceFailureHandler: SourceFailureHandler
    private var lifecycleGeneration = 0
    private var nextDriverGeneration = 0
    private var runningSources: [String: RunningSource] = [:]
    private var startingSources: [String: StartingSource] = [:]
    private var startupCapturesBySourceID: [String: NativeRealtimeCaptureSource] = [:]
    private var removedSourceIDsDuringStartup = Set<String>()

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

    /// Replaces the current set with isolated drivers for enabled, successfully captured sources.
    /// A replacement using an already-consumed PCM input is rejected and tears down the old set.
    /// This coordinator is intentionally not connected to AppModel's production session path yet.
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
        let supersededStartupCaptures = Array(startupCapturesBySourceID.values)
        startupCapturesBySourceID = Dictionary(
            optedIn.map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        removedSourceIDsDuringStartup.removeAll()
        let finishObservers = optedIn.filter { !inputsAreInvalid && !$0.input.isConsumed }.map { capture in
            Task { [weak self] in
                let error = await capture.input.waitUntilFinished()
                guard !Task.isCancelled else { return }
                await self?.inputDidFinish(
                    sourceID: capture.sourceID,
                    startupGeneration: startupGeneration,
                    error: error
                )
            }
        }
        defer { finishObservers.forEach { $0.cancel() } }
        for capture in supersededStartupCaptures {
            capture.input.finish(error: .sourceSuperseded)
        }
        defer {
            if lifecycleGeneration == startupGeneration {
                startupCapturesBySourceID.removeAll()
                removedSourceIDsDuringStartup.removeAll()
            }
        }
        let previous = detachAllSources()
        await stop(previous.running)
        await stop(previous.starting)
        guard !Task.isCancelled else {
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
                Task { await self.cancelStartup(generation: startupGeneration) }
            }
            guard !Task.isCancelled else {
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
            if Task.isCancelled {
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
        var started: [NativeRealtimeStartedSource] = []
        var driverSettings = settings
        driverSettings.enabledSourceIDs = []
        for capture in optedIn {
            guard lifecycleGeneration == startupGeneration else { break }
            guard !removedSourceIDsDuringStartup.contains(capture.sourceID) else {
                capture.input.finish(error: .sourceSuperseded)
                continue
            }
            guard !rejectTerminatedCapture(capture) else { continue }
            guard let alias = aliases.alias(for: capture.sourceID) else { continue }
            let sourceGeneration = nextDriverGeneration
            nextDriverGeneration &+= 1
            let driver = driverFactory(driverSettings, credential, capture.role)
            let lease = RealtimeReaderLease()
            startingSources[capture.sourceID] = StartingSource(
                capture: capture,
                generation: sourceGeneration,
                driver: driver,
                lease: lease
            )
            do {
                try await withTaskCancellationHandler {
                    try await driver.start(sourceAlias: alias, generation: sourceGeneration)
                } onCancel: {
                    Task { await self.cancelStartup(generation: startupGeneration) }
                }
            } catch {
                if Task.isCancelled {
                    await cancelStartup(generation: startupGeneration)
                    return []
                }
                await driver.stop()
                capture.input.finish(error: .sourceSuperseded)
                guard lifecycleGeneration == startupGeneration else { break }
                guard let pending = startingSources[capture.sourceID],
                      pending.generation == sourceGeneration,
                      pending.lease.isActive else { continue }
                startingSources.removeValue(forKey: capture.sourceID)
                lease.deactivate()
                sourceFailureHandler(capture.sourceID, Self.failureCode(for: error))
                continue
            }

            guard !Task.isCancelled else {
                await cancelStartup(generation: startupGeneration)
                return []
            }
            guard lifecycleGeneration == startupGeneration else {
                capture.input.finish(error: .sourceSuperseded)
                await driver.stop()
                break
            }
            guard let pending = startingSources[capture.sourceID],
                  pending.generation == sourceGeneration,
                  pending.lease.isActive else {
                capture.input.finish(error: .sourceSuperseded)
                await driver.stop()
                continue
            }
            guard !capture.input.isConsumed,
                  capture.input.terminationError == nil else {
                startingSources.removeValue(forKey: capture.sourceID)
                lease.deactivate()
                removedSourceIDsDuringStartup.insert(capture.sourceID)
                capture.input.finish(error: .sourceSuperseded)
                await driver.stop()
                if let failure = Self.failureCode(for: capture.input.terminationError) {
                    sourceFailureHandler(capture.sourceID, failure)
                }
                continue
            }
            startingSources.removeValue(forKey: capture.sourceID)

            let reader = Task { [weak self] in
                let failure = await Self.readAudio(
                    from: capture,
                    alias: alias,
                    generation: sourceGeneration,
                    driver: driver,
                    lease: lease
                )
                lease.deactivate()
                capture.input.finish(error: failure == nil ? nil : .sourceSuperseded)
                await driver.stop()
                await self?.readerDidFinish(
                    sourceID: capture.sourceID,
                    generation: sourceGeneration,
                    failure: failure
                )
            }
            runningSources[capture.sourceID] = RunningSource(
                capture: capture,
                generation: sourceGeneration,
                driver: driver,
                lease: lease,
                reader: reader
            )
            started.append(NativeRealtimeStartedSource(
                sourceID: capture.sourceID,
                alias: alias,
                generation: sourceGeneration
            ))
        }
        if lifecycleGeneration != startupGeneration {
            optedIn.forEach { $0.input.finish(error: .sourceSuperseded) }
        }
        guard !Task.isCancelled else {
            await cancelStartup(generation: startupGeneration)
            return []
        }
        return started.filter { runningSources[$0.sourceID]?.generation == $0.generation }
    }

    func removeSource(sourceID: String) async {
        if let capture = startupCapturesBySourceID[sourceID],
           removedSourceIDsDuringStartup.insert(sourceID).inserted {
            capture.input.finish(error: .sourceSuperseded)
        }
        let running = runningSources.removeValue(forKey: sourceID)
        let starting = startingSources.removeValue(forKey: sourceID)
        if let running { await stop([running], streamError: .sourceSuperseded) }
        if let starting { await stop([starting]) }
    }

    func stop() async {
        lifecycleGeneration &+= 1
        let startupCaptures = Array(startupCapturesBySourceID.values)
        startupCapturesBySourceID.removeAll()
        removedSourceIDsDuringStartup.removeAll()
        startupCaptures.forEach { $0.input.finish(error: .sourceSuperseded) }
        let sources = detachAllSources()
        await stop(sources.running)
        await stop(sources.starting)
    }

    func activeSourceIDs() -> [String] {
        runningSources.keys.sorted()
    }

    private func inputDidFinish(
        sourceID: String,
        startupGeneration: Int,
        error: RealtimePCM16AudioStreamError?
    ) async {
        guard lifecycleGeneration == startupGeneration,
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
        pending.lease.deactivate()
        pending.capture.input.finish(error: .sourceSuperseded)
        await pending.driver.stop()
        guard lifecycleGeneration == startupGeneration,
              startupCapturesBySourceID[sourceID]?.input.isSameCapture(as: pending.capture.input) == true,
              let failure = Self.failureCode(for: error) else { return }
        sourceFailureHandler(sourceID, failure)
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
        lifecycleGeneration &+= 1
        let captures = Array(startupCapturesBySourceID.values)
        startupCapturesBySourceID.removeAll()
        removedSourceIDsDuringStartup.removeAll()
        captures.forEach { $0.input.finish(error: .sourceSuperseded) }
        let sources = detachAllSources()
        await stop(sources.running)
        await stop(sources.starting)
    }

    private func stop(
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

    private func stop(_ sources: [StartingSource]) async {
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
        failure: RealtimeFailureCode?
    ) {
        guard runningSources[sourceID]?.generation == finishedGeneration else { return }
        removedSourceIDsDuringStartup.insert(sourceID)
        runningSources.removeValue(forKey: sourceID)
        if let failure {
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
        do {
            while !Task.isCancelled, lease.isActive {
                guard let chunk = try await capture.input.nextChunk() else { return nil }
                guard lease.isActive else { return nil }
                // Preserve the capture timestamp as provenance; this only fences ordering
                // within one source and does not align chunks to Speech captions.
                guard chunk.sourceToken == capture.input.sourceToken,
                      chunk.generation == capture.input.generation,
                      chunk.sampleRate == 16_000,
                      chunk.frameCount > 0,
                      chunk.pcm16LE.count == chunk.frameCount * 2,
                      previousTimestamp.map({ chunk.captureTimestampNanoseconds >= $0 }) ?? true else {
                    return .malformedResponse
                }
                previousTimestamp = chunk.captureTimestampNanoseconds
                try await driver.sendAudioChunk(RealtimeAudioChunk(
                    sourceAlias: alias,
                    generation: generation,
                    capturedAtMonotonicNanoseconds: chunk.captureTimestampNanoseconds,
                    pcm16LEData: chunk.pcm16LE,
                    sampleRate: chunk.sampleRate
                ))
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
