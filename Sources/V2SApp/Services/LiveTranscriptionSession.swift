import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

struct RecognizedSentence: Equatable, Sendable {
    let text: String
    let promotionSegmentID: UUID?
    let audioWAVData: Data?
    let audioProvenance: RecognizedAudioProvenance?

    init(
        text: String,
        promotionSegmentID: UUID? = nil,
        audioWAVData: Data? = nil,
        audioProvenance: RecognizedAudioProvenance? = nil
    ) {
        self.text = text
        self.promotionSegmentID = promotionSegmentID
        self.audioWAVData = audioWAVData
        self.audioProvenance = audioProvenance
    }
}

private struct UncheckedSendablePCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

private struct SpeechInputPCMBuffer {
    let buffer: AVAudioPCMBuffer
    let verifiedRepackProof: NormalizedPCM16RepackProof?
}

struct RealtimePCM16AudioChunk: Equatable, Sendable {
    let sourceToken: UUID
    let generation: UInt64
    let captureTimestampNanoseconds: UInt64
    let sampleRate: Int
    let frameCount: Int
    let sampleInterval: NormalizedAudioSampleInterval
    let pcm16LE: Data
}

enum RealtimePCM16AudioStreamError: Error, Equatable {
    case backpressureExceeded
    case sourceSuperseded
    case invalidAudioChunk
    case concurrentRead
}

enum RealtimePCM16AudioOfferResult: Equatable {
    case enqueued
    case noConsumer
    case rejectedSource
    case rejectedGeneration
    case backpressureExceeded
    case invalidAudioChunk
    case closed
}

struct RealtimePCM16AudioInput: Sendable {
    let sourceToken: UUID
    let generation: UInt64
    let firstAvailableSampleIndex: Int64

    private let fanout: RealtimePCM16AudioFanout

    fileprivate init(
        sourceToken: UUID,
        generation: UInt64,
        firstAvailableSampleIndex: Int64,
        fanout: RealtimePCM16AudioFanout
    ) {
        self.sourceToken = sourceToken
        self.generation = generation
        self.firstAvailableSampleIndex = max(0, firstAvailableSampleIndex)
        self.fanout = fanout
    }

    func nextChunk() async throws -> RealtimePCM16AudioChunk? {
        try await fanout.nextChunk()
    }

    func finish(error: RealtimePCM16AudioStreamError? = nil) {
        fanout.finish(error: error)
    }

    func waitUntilFinished() async -> RealtimePCM16AudioStreamError? {
        await fanout.waitUntilFinished()
    }

    func isSameCapture(as other: RealtimePCM16AudioInput) -> Bool {
        fanout === other.fanout
    }

    var isConsumed: Bool {
        fanout.isConsumed
    }

    var terminationError: RealtimePCM16AudioStreamError? {
        fanout.terminationError
    }
}

/// A per-capture-generation bounded mailbox. Capturing only performs a short lock,
/// copies one already-normalized chunk, and signals a waiting reader; it never calls
/// the consumer or performs network work. Audio is terminally rejected on overflow.
final class RealtimePCM16AudioFanout: @unchecked Sendable {
    private let lock = NSLock()
    let maximumBufferedFrames: Int
    private let maximumBufferedChunks: Int

    private var chunks: [RealtimePCM16AudioChunk] = []
    private var bufferedFrames = 0
    private var didCreateInput = false
    private var didFinishInput = false
    private var isClosed = false
    private var terminalError: RealtimePCM16AudioStreamError?
    private var readerIsActive = false
    private var waitingReader: CheckedContinuation<RealtimePCM16AudioChunk?, Error>?
    private var finishWaiters: [UUID: CheckedContinuation<RealtimePCM16AudioStreamError?, Never>] = [:]

    let sourceToken: UUID
    let generation: UInt64

    init(
        sourceToken: UUID,
        generation: UInt64,
        maximumBufferedFrames: Int = 32_000,
        maximumBufferedChunks: Int = 128
    ) {
        self.sourceToken = sourceToken
        self.generation = generation
        self.maximumBufferedFrames = max(1, maximumBufferedFrames)
        self.maximumBufferedChunks = max(1, maximumBufferedChunks)
    }

    func makeInput(firstAvailableSampleIndex: Int64 = 0) -> RealtimePCM16AudioInput? {
        lock.lock()
        defer { lock.unlock() }
        guard !didCreateInput, !isClosed else { return nil }
        didCreateInput = true
        return RealtimePCM16AudioInput(
            sourceToken: sourceToken,
            generation: generation,
            firstAvailableSampleIndex: firstAvailableSampleIndex,
            fanout: self
        )
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isClosed && didCreateInput
    }

    var isConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinishInput
    }

    var terminationError: RealtimePCM16AudioStreamError? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    func waitUntilFinished() async -> RealtimePCM16AudioStreamError? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RealtimePCM16AudioStreamError?, Never>) in
                lock.lock()
                guard !isClosed, !Task.isCancelled else {
                    let error = terminalError
                    lock.unlock()
                    continuation.resume(returning: error)
                    return
                }
                finishWaiters[waiterID] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancelFinishWaiter(waiterID)
        }
    }

    @discardableResult
    func offer(
        pcm16LE: Data,
        frameCount: Int,
        sampleInterval: NormalizedAudioSampleInterval,
        sourceToken offeredSourceToken: UUID,
        generation offeredGeneration: UInt64,
        captureTimestampNanoseconds: UInt64
    ) -> RealtimePCM16AudioOfferResult {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return .closed
        }
        guard offeredSourceToken == sourceToken else {
            lock.unlock()
            return .rejectedSource
        }
        guard offeredGeneration == generation else {
            lock.unlock()
            return .rejectedGeneration
        }
        guard didCreateInput else {
            lock.unlock()
            return .noConsumer
        }
        guard sampleInterval.lowerBound >= 0,
              sampleInterval.upperBound > sampleInterval.lowerBound,
              frameCount > 0,
              frameCount <= Int.max / 2,
              pcm16LE.count == frameCount * 2,
              Int64(exactly: frameCount) == sampleInterval.upperBound - sampleInterval.lowerBound else {
            isClosed = true
            terminalError = .invalidAudioChunk
            chunks.removeAll(keepingCapacity: false)
            bufferedFrames = 0
            let waiter = waitingReader
            waitingReader = nil
            let finishWaiters = Array(self.finishWaiters.values)
            self.finishWaiters.removeAll()
            lock.unlock()
            waiter?.resume(throwing: RealtimePCM16AudioStreamError.invalidAudioChunk)
            finishWaiters.forEach { $0.resume(returning: .invalidAudioChunk) }
            return .invalidAudioChunk
        }

        guard frameCount <= maximumBufferedFrames - bufferedFrames,
              chunks.count < maximumBufferedChunks else {
            isClosed = true
            terminalError = .backpressureExceeded
            chunks.removeAll(keepingCapacity: false)
            bufferedFrames = 0
            let waiter = waitingReader
            waitingReader = nil
            let finishWaiters = Array(self.finishWaiters.values)
            self.finishWaiters.removeAll()
            lock.unlock()
            waiter?.resume(throwing: RealtimePCM16AudioStreamError.backpressureExceeded)
            finishWaiters.forEach { $0.resume(returning: .backpressureExceeded) }
            return .backpressureExceeded
        }

        let chunk = RealtimePCM16AudioChunk(
            sourceToken: sourceToken,
            generation: generation,
            captureTimestampNanoseconds: captureTimestampNanoseconds,
            sampleRate: 16_000,
            frameCount: frameCount,
            sampleInterval: sampleInterval,
            pcm16LE: pcm16LE
        )
        if let waiter = waitingReader {
            waitingReader = nil
            lock.unlock()
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
            bufferedFrames += frameCount
            lock.unlock()
        }
        return .enqueued
    }

    func finish(error: RealtimePCM16AudioStreamError? = nil) {
        lock.lock()
        didFinishInput = true
        let finishWaiters = Array(self.finishWaiters.values)
        self.finishWaiters.removeAll()
        guard !isClosed else {
            let finishError = terminalError
            lock.unlock()
            finishWaiters.forEach { $0.resume(returning: finishError) }
            return
        }
        isClosed = true
        terminalError = error
        chunks.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        let waiter = waitingReader
        waitingReader = nil
        lock.unlock()

        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume(returning: nil)
        }
        finishWaiters.forEach { $0.resume(returning: error) }
    }

    private func cancelFinishWaiter(_ waiterID: UUID) {
        lock.lock()
        let waiter = finishWaiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    fileprivate func nextChunk() async throws -> RealtimePCM16AudioChunk? {
        guard beginReader() else {
            throw RealtimePCM16AudioStreamError.concurrentRead
        }
        do {
            let result: RealtimePCM16AudioChunk? = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RealtimePCM16AudioChunk?, Error>) in
                registerReader(continuation)
            }
            finishReader()
            return result
        } catch {
            finishReader()
            throw error
        }
    }

    private func beginReader() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !readerIsActive else { return false }
        readerIsActive = true
        return true
    }

    private func registerReader(
        _ continuation: CheckedContinuation<RealtimePCM16AudioChunk?, Error>
    ) {
        lock.lock()
        let chunk: RealtimePCM16AudioChunk?
        let error: RealtimePCM16AudioStreamError?
        if !chunks.isEmpty {
            chunk = chunks.removeFirst()
            bufferedFrames -= chunk?.frameCount ?? 0
            error = nil
        } else if isClosed {
            chunk = nil
            error = terminalError
        } else {
            waitingReader = continuation
            lock.unlock()
            return
        }
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: chunk)
        }
    }

    private func finishReader() {
        lock.lock()
        readerIsActive = false
        lock.unlock()
    }
}

private final class CommittedDeliveryPauseForTesting: @unchecked Sendable {
    let authorizationReached = DispatchSemaphore(value: 0)
    let resumeDelivery = DispatchSemaphore(value: 0)
}

final class LiveTranscriptionSession: NSObject, @unchecked Sendable {
    enum LegacyRecognitionErrorDisposition: Equatable {
        case ignore
        case restartImmediately
        case retryWithBackoff
        case stopAndSurface
    }

    /// Decides what to do about a legacy recognition-task error.
    ///
    /// `message` is the error's localized description. Code 203 is a bucket Apple uses
    /// for unrelated failures — the transient "Retry"/"Corrupt" faults that a restart
    /// clears, and the server quota rejection that no amount of retrying clears — so
    /// only the quota text earns a hard stop.
    static func legacyRecognitionErrorDisposition(
        domain: String,
        code: Int,
        message: String = ""
    ) -> LegacyRecognitionErrorDisposition {
        guard domain == "kAFAssistantErrorDomain" else {
            return .retryWithBackoff
        }

        if message.range(of: "quota", options: .caseInsensitive) != nil {
            return .stopAndSurface
        }

        switch code {
        case 216, 301:
            return .ignore
        case 1110:
            return .restartImmediately
        default:
            return .retryWithBackoff
        }
    }

    private struct CommittedEmission {
        let text: String
        let promotionSegmentID: UUID?
        let audioWAVData: Data?
        let audioProvenance: RecognizedAudioProvenance?
        let modernTimedText: ModernSpeechTextSnapshot?
        let deliveryToken: CommittedEmissionDeliveryToken

        init(
            text: String,
            promotionSegmentID: UUID?,
            audioWAVData: Data? = nil,
            audioProvenance: RecognizedAudioProvenance? = nil,
            modernTimedText: ModernSpeechTextSnapshot? = nil,
            deliveryToken: CommittedEmissionDeliveryToken
        ) {
            self.text = text
            self.promotionSegmentID = promotionSegmentID
            self.audioWAVData = audioWAVData
            self.audioProvenance = audioProvenance
            self.modernTimedText = modernTimedText?.text == text ? modernTimedText : nil
            self.deliveryToken = deliveryToken
        }
    }

    private struct CommittedEmissionDeliveryToken: Sendable {
        let sessionEpoch: Int
        let audioCaptureEpoch: Int?
        let modernRecognitionEpoch: Int?
    }

    private struct ModernPartialDraftDelivery: Sendable {
        let draft: DraftSegment?
        let deliveryToken: CommittedEmissionDeliveryToken
    }

    private enum CommittedEmissionDeliveryPermission: Equatable {
        case suppress
        case textOnly
        case textAndAudio
    }

    private struct ApplicationCaptureDescriptor: Sendable {
        let appName: String
        let processObjectIDs: [AudioObjectID]
        let readStreamFailureMessage: String
    }

    @MainActor
    private struct RecentCommittedSentence {
        let rawText: String
        let comparableText: String
        let time: Date
        let allowsPrefixContinuation: Bool
    }

    private struct AudioLevelStats {
        let peak: Float
        let rms: Float
    }

    private enum RecognitionBackend: Equatable {
        case legacy
        case speechAnalyzer
    }

    enum SessionError: LocalizedError, AppLocalizableError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioCapturePermissionDenied
        case unsupportedSpeechLocale(String)
        case unavailableSpeechRecognizer(String)
        case missingMicrophoneDevice
        case missingApplication(String)
        case applicationNotProducingAudio(String)
        case failedToStartCapture(String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .speechPermissionDenied:
                return AppLocalization.string(.speechPermissionDenied, languageID: languageID)
            case .microphonePermissionDenied:
                return AppLocalization.string(.microphonePermissionDenied, languageID: languageID)
            case .audioCapturePermissionDenied:
                return AppLocalization.string(.appAudioCapturePermissionDenied, languageID: languageID)
            case .unsupportedSpeechLocale(let localeIdentifier):
                return AppLocalization.string(.unsupportedSpeechLocaleFormat, languageID: languageID, localeIdentifier)
            case .unavailableSpeechRecognizer(let localeIdentifier):
                return AppLocalization.string(.unavailableSpeechRecognizerFormat, languageID: languageID, localeIdentifier)
            case .missingMicrophoneDevice:
                return AppLocalization.string(.missingMicrophoneDevice, languageID: languageID)
            case .missingApplication(let appName):
                return AppLocalization.string(.missingApplicationFormat, languageID: languageID, appName)
            case .applicationNotProducingAudio(let appName):
                return AppLocalization.string(.applicationNotProducingAudioFormat, languageID: languageID, appName)
            case .failedToStartCapture(let reason):
                return AppLocalization.string(.failedToStartCaptureFormat, languageID: languageID, reason)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private let captureQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture", qos: .userInitiated)
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Advances whenever a recognizer/backend receives a fresh audio timeline. Both
    /// legacy handlers and modern result tasks capture this epoch before dispatching.
    private var recognitionEpoch: Int = 0
    /// Lock-protected mirror used only when MainActor delivery validates a token.
    private var deliveryRecognitionEpoch: Int = 0
    private var deliveryRecognitionBackend: RecognitionBackend = .legacy
    /// Invalidates all queued transcript deliveries when a session is torn down.
    private var transcriptDeliveryEpoch: Int = 0
    /// Consecutive recognition-task failures since the last delivered result. Restarting
    /// immediately recovers from a one-off fault, but a persistent one — an evicted
    /// on-device asset, an unreachable backend — would otherwise spin the task in a hot
    /// loop, so retries are spaced out and eventually surfaced instead of hidden.
    private var consecutiveRecognitionFailures = 0
    private var lastRecognitionFailureTime = Date.distantPast
    private var pendingRecognitionRestart: DispatchWorkItem?
    /// Delay before the Nth consecutive retry. The first stays immediate so ordinary
    /// hiccups still recover without a visible gap.
    private let recognitionRestartBackoff: [TimeInterval] = [0, 0.5, 1.5, 3, 5]
    /// Failures spaced further apart than this are unrelated, not a failing recognizer.
    private let recognitionFailureWindow: TimeInterval = 60
    private var preprocessingConverter: AVAudioConverter?
    private var preprocessingConverterInputSignature: AudioFormatSignature?
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: AudioFormatSignature?
    private var modernAudioConverter: AVAudioConverter?
    private var modernAudioConverterInputSignature: AudioFormatSignature?
    private var correctionAudioCaptureEnabled = false
    /// Invalidates copied WAV payloads on every capture opt-in transition.
    private var correctionAudioCaptureEpoch: Int = 0
    /// Serializes the final delivery decision with stop/opt-out so a copied WAV cannot
    /// cross the MainActor boundary after either action has taken effect.
    private let transcriptDeliveryLock = NSLock()
    /// Serializes a complete outer emission with privacy state changes. A transaction
    /// holds this gate across every split unit, including its MainActor callback.
    private let committedSequenceDeliveryGate = NSRecursiveLock()
    private let committedDeliveryTestingLock = NSLock()
    private var committedDeliveryPauseForTesting: CommittedDeliveryPauseForTesting?
    private var deliveryMutationAttemptSemaphoreForTesting: DispatchSemaphore?
    private var deliveryMutationWaitingForTesting = false
    private var correctionAudioBuffer = SentenceAudioBuffer(sampleRate: 16_000, maximumDuration: 15)
    /// Legacy Speech timestamps can rebase with their segment array. Keep the audio
    /// cursor boundary independent so a replayed/regressed timestamp cannot consume data.
    private var lastCorrectionAudioBoundaryTime: TimeInterval?
    /// A raw legacy sample bypassed the normalized PCM path. Its utterance cannot safely
    /// receive a partial correction WAV, so the next committed boundary discards it.
    private var legacyCorrectionAudioHasConversionGap = false
    private var queuedCommittedEmissionForTesting: CommittedEmission?
    private var queuedModernPartialDraftDeliveryForTesting: ModernPartialDraftDelivery?
    private var committedSegmentCount = 0
    private let committedBoundaryToleranceSec: TimeInterval = 0.08
    private var committedAudioBoundaryTime: TimeInterval?
    private var recognitionContextualStrings: [String] = []
    private var recognitionBackend: RecognitionBackend = .legacy
    private var activeLocaleIdentifier: String?
    private var interfaceLanguageID = "en"
    private var modernAnalyzerTask: Task<Void, Never>?
    private var modernResultsTask: Task<Void, Never>?
    private var lastModernCommittedResultIdentity: String?
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?
    private var modernAnalyzerInputYieldForTesting: ((AVAudioPCMBuffer, CMTime?) -> ModernAnalyzerInputDeliveryOutcome)?
    private var modernAnalyzerInputFinishForTesting: (() -> Void)?
    private var latestModernText = ""
    private var latestModernTimedText: ModernSpeechTextSnapshot?
    private var modernCommittedPrefixText = ""

    private var microphoneCaptureSession: AVCaptureSession?
    private var applicationAudioCapture: ApplicationAudioCapture?
    /// Recreated for each recognition session so a reader can never cross a restart.
    private var realtimeAudioFanout: RealtimePCM16AudioFanout?
    private var realtimeAudioGeneration: UInt64 = 0
    private var normalizedAudioSampleClock = NormalizedAudioSampleClock()
    private var legacyRecognitionSampleMapping: LegacyRecognitionSampleMapping?
    private var modernRecognitionSampleMapping: ModernRecognitionSampleMapping?

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var partialHandler: (@MainActor (DraftSegment?) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?
    /// Reports an unrecoverable recognition failure after this session has stopped.
    /// The owner uses this separate callback to stop sibling sessions as well.
    private var fatalErrorHandler: (@MainActor (String) -> Void)?
    @MainActor private var recentCommittedSentenceHistory: [RecentCommittedSentence] = []
    @MainActor private var shouldInvalidateCommittedDeliveryAfterAuthorizationForTesting = false
    #if DEBUG
    private var startOperationForTesting: (@Sendable () async throws -> Void)?
    private var stopInvocationCount = 0
    #endif

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: interfaceLanguageID, arguments: arguments)
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: interfaceLanguageID)
    }

    // MARK: Draft state (accessed only on captureQueue)
    private var modeConfig: ModeConfig = .balanced
    private var currentDraftId = UUID()
    private var lastDraftText = ""
    private var lastDraftTextChangeTime = Date.distantPast
    private var lastRecognitionResultTime = Date.distantPast
    private var draftChangeHistory: [(text: String, time: Date)] = []
    private var draftPrefixCandidate = ""
    private var draftPrefixCandidateTime = Date.distantPast
    private var confirmedStablePrefixLength = 0

    // MARK: Silence-commit timer (captureQueue)
    // Fires when the ASR stops delivering new results — i.e. the user has paused.
    // This is more reliable than measuring inter-word gaps because the last word in
    // a sentence has no "next segment" and therefore never triggers a pause boundary.
    private var silenceCommitTimer: DispatchSourceTimer?
    private var latestSegments: [SFTranscriptionSegment] = []
    private var latestFormattedText: NSString = ""

    // MARK: Silero VAD (captureQueue)
    private var vadEngine: SileroVADEngine?
    private var lastVADProbability: Float = 0.0
    private var vadSilenceCommitTimer: DispatchSourceTimer?
    private var noiseFloorRMS: Float = 0.0012
    private var highPassPreviousInput: Float = 0.0
    private var highPassPreviousOutput: Float = 0.0

    private func runOnCaptureQueue<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum SilenceCommitTrigger {
        case asrInactivity
        case vadOffset
    }

    func start(
        source: InputSource,
        localeIdentifier: String,
        interfaceLanguageID: String,
        modeConfig: ModeConfig = .balanced,
        contextualStrings: [String] = [],
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void,
        fatalErrorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        #if DEBUG
        if let startOperationForTesting {
            self.transcriptHandler = transcriptHandler
            self.partialHandler = partialHandler
            self.modeConfig = modeConfig
            self.recognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
            self.activeLocaleIdentifier = localeIdentifier
            self.interfaceLanguageID = interfaceLanguageID
            self.errorHandler = errorHandler
            self.fatalErrorHandler = fatalErrorHandler
            try await startOperationForTesting()
            return
        }
        #endif

        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.recognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
        self.activeLocaleIdentifier = localeIdentifier
        self.interfaceLanguageID = interfaceLanguageID
        self.errorHandler = errorHandler
        self.fatalErrorHandler = fatalErrorHandler
        await MainActor.run {
            recentCommittedSentenceHistory.removeAll()
        }

        let startupEpoch = await beginRecognitionSessionOnCaptureQueue()

        do {
            try await requestRequiredPermissions(for: source)
            let recognizerConfigured: Bool
            if try await configureModernSpeechRecognizer(
                localeIdentifier: localeIdentifier,
                expectedEpoch: startupEpoch
            ) {
                recognizerConfigured = true
            } else {
                recognizerConfigured = try await configureLegacySpeechRecognizer(
                    localeIdentifier: localeIdentifier,
                    expectedEpoch: startupEpoch
                )
            }

            // The session may have stopped while permissions or modern asset setup
            // suspended. Do not revive a recognizer or capture source from that stale start.
            guard recognizerConfigured else {
                return
            }

            switch source.category {
            case .microphone:
                let captureStarted: Bool = try await runOnCaptureQueue {
                    guard self.recognitionEpoch == startupEpoch else { return false }
                    try self.startMicrophoneCapture(deviceUniqueID: source.detail)
                    return true
                }
                guard captureStarted else { return }
            case .application:
                let captureDescriptor = try await MainActor.run {
                    try self.makeApplicationCaptureDescriptor(for: source)
                }
                let captureStarted: Bool = try await runOnCaptureQueue {
                    guard self.recognitionEpoch == startupEpoch else { return false }
                    try self.startApplicationAudioCapture(descriptor: captureDescriptor)
                    return true
                }
                guard captureStarted else { return }
            }
        } catch {
            await resetCorrectionAudioBufferOnCaptureQueue()
            await finishRealtimeAudioFanoutOnCaptureQueue()
            throw error
        }
    }

    func stop() {
        // Keep the session alive until every capture resource has been released. The
        // owner drops its references immediately after calling this method.
        captureQueue.async { [self] in
            stopOnCaptureQueue()
        }
    }

    /// Stops the session and returns only after its capture queue has released all
    /// microphone/Core Audio resources. Used before starting replacement sessions.
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                stopOnCaptureQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnCaptureQueue() {
        #if DEBUG
        stopInvocationCount += 1
        #endif
        beginCommittedDeliveryStateMutation()
        defer { endCommittedDeliveryStateMutation() }

        cancelSilenceTimer()
        cancelVADSilenceTimer()

        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil
        realtimeAudioFanout?.finish()
        realtimeAudioFanout = nil

        stopModernSpeechRecognizer()
        resetRecognitionFailureState()
        invalidateTranscriptDelivery()
        resetRecognitionEpoch()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        activeLocaleIdentifier = nil
        resetAudioProcessingState()
        resetLegacyTranscriptionState()

        vadEngine = nil
        lastVADProbability = 0

        resetModernTranscriptionState()
        partialHandler = nil
        resetDraftState()
        Task { @MainActor [weak self] in
            self?.recentCommittedSentenceHistory.removeAll()
        }
    }

    func setCorrectionAudioCaptureEnabled(_ enabled: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard correctionAudioCaptureEnabled != enabled else { return }
            beginCommittedDeliveryStateMutation()
            defer { endCommittedDeliveryStateMutation() }
            transcriptDeliveryLock.lock()
            correctionAudioCaptureEpoch &+= 1
            correctionAudioCaptureEnabled = enabled
            transcriptDeliveryLock.unlock()
            if enabled == false {
                resetCorrectionAudioBuffer()
            }
        }
    }

    /// Clears provider-bound audio and installs the final capture policy as one
    /// capture-queue transaction. The caller resumes only after the new capture
    /// epoch is visible to committed-emission delivery.
    func resetCorrectionAudioCapture(enabled: Bool) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                beginCommittedDeliveryStateMutation()
                resetCorrectionAudioBuffer()
                transcriptDeliveryLock.lock()
                correctionAudioCaptureEpoch &+= 1
                correctionAudioCaptureEnabled = enabled
                transcriptDeliveryLock.unlock()
                endCommittedDeliveryStateMutation()
                continuation.resume()
            }
        }
    }

    #if DEBUG
    func setStartOperationForTesting(
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        startOperationForTesting = operation
    }

    func stopInvocationCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(returning: self?.stopInvocationCount ?? 0)
            }
        }
    }
    #endif

    func correctionAudioCaptureEnabledForTesting() async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(returning: self?.correctionAudioCaptureEnabled ?? false)
            }
        }
    }

    @MainActor
    func setTranscriptHandlerForTesting(
        _ handler: @escaping @MainActor (RecognizedSentence) -> Void
    ) {
        transcriptHandler = handler
    }

    @MainActor
    func deliverRecognizedSentenceForTesting(_ sentence: RecognizedSentence) {
        transcriptHandler?(sentence)
    }

    @MainActor
    func setPartialHandlerForTesting(
        _ handler: @escaping @MainActor (DraftSegment?) -> Void
    ) {
        partialHandler = handler
    }

    func appendCorrectionAudioBufferForTesting(_ audioBuffer: AVAudioPCMBuffer) async {
        let sendableAudioBuffer = UncheckedSendablePCMBuffer(value: audioBuffer)
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.appendCorrectionAudioBuffer(sendableAudioBuffer.value)
                continuation.resume()
            }
        }
    }

    func makeRealtimePCM16AudioInput() async -> RealtimePCM16AudioInput? {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.realtimeAudioFanout?.makeInput(
                    firstAvailableSampleIndex: self.normalizedAudioSampleClock.nextSampleIndex
                ))
            }
        }
    }

    func appendRealtimePCM16AudioForTesting(_ processingBuffer: AVAudioPCMBuffer) async {
        let sendableBuffer = UncheckedSendablePCMBuffer(value: processingBuffer)
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.publishRealtimePCM16Audio(from: sendableBuffer.value)
                continuation.resume()
            }
        }
    }

    func correctionAudioFrameCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(returning: self?.correctionAudioBuffer.frameCount ?? 0)
            }
        }
    }

    func resetRecognitionGenerationForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.resetRecognitionEpoch()
                continuation.resume()
            }
        }
    }

    func beginModernSetupForTesting() async -> Int {
        await beginRecognitionSessionOnCaptureQueue()
    }

    @available(macOS 26.0, *)
    func installModernAnalyzerInputStreamForTesting(
        bufferingCapacity: Int = 12,
        analyzerFormat: AVAudioFormat? = nil
    ) async -> AsyncStream<ModernAnalyzerInputSummary> {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    let (stream, inputContinuation) = AsyncStream<ModernAnalyzerInputSummary>.makeStream(
                        bufferingPolicy: .bufferingNewest(max(1, bufferingCapacity))
                    )
                    inputContinuation.finish()
                    continuation.resume(returning: stream)
                    return
                }
                let (stream, inputContinuation) = AsyncStream<ModernAnalyzerInputSummary>.makeStream(
                    bufferingPolicy: .bufferingNewest(max(1, bufferingCapacity))
                )
                self.analyzerInputContinuationState = nil
                self.analyzerInputFormat = analyzerFormat
                self.modernAnalyzerInputYieldForTesting = { buffer, bufferStartTime in
                    switch inputContinuation.yield(
                        ModernAnalyzerInputSummary(
                            frameCount: Int(buffer.frameLength),
                            sampleRate: buffer.format.sampleRate,
                            isInt16PCM: buffer.format.commonFormat == .pcmFormatInt16,
                            isInterleaved: buffer.format.isInterleaved,
                            bufferStartTime: bufferStartTime
                        )
                    ) {
                    case .enqueued:
                        return .enqueued
                    case .dropped:
                        return .dropped
                    case .terminated:
                        return .terminated
                    @unknown default:
                        return .terminated
                    }
                }
                self.modernAnalyzerInputFinishForTesting = { inputContinuation.finish() }
                self.modernRecognitionSampleMapping = self.makeModernRecognitionSampleMapping()
                self.setRecognitionBackend(.speechAnalyzer)
                continuation.resume(returning: stream)
            }
        }
    }

    @available(macOS 26.0, *)
    func installRealModernAnalyzerInputStreamForTesting(
        analyzerFormat: AVAudioFormat,
        bufferingCapacity: Int = 12
    ) async -> AsyncStream<AnalyzerInput> {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                let (stream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
                    bufferingPolicy: .bufferingNewest(max(1, bufferingCapacity))
                )
                guard let self else {
                    inputContinuation.finish()
                    continuation.resume(returning: stream)
                    return
                }
                self.analyzerInputContinuationState = inputContinuation
                self.analyzerInputFormat = analyzerFormat
                self.modernAnalyzerInputYieldForTesting = nil
                self.modernAnalyzerInputFinishForTesting = { inputContinuation.finish() }
                self.modernRecognitionSampleMapping = self.makeModernRecognitionSampleMapping()
                self.setRecognitionBackend(.speechAnalyzer)
                continuation.resume(returning: stream)
            }
        }
    }

    func terminateModernAnalyzerInputStreamForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.modernAnalyzerInputFinishForTesting?()
                continuation.resume()
            }
        }
    }

    func appendCapturedAudioBufferForTesting(_ audioBuffer: AVAudioPCMBuffer) async {
        let sendableBuffer = UncheckedSendablePCMBuffer(value: audioBuffer)
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.append(audioBuffer: sendableBuffer.value)
                continuation.resume()
            }
        }
    }

    func modernAudioProvenanceForTesting(_ timeRange: CMTimeRange) async -> RecognizedAudioProvenance? {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(
                    returning: self?.modernRecognitionSampleMapping?.provenance(for: timeRange)
                )
            }
        }
    }

    func finalizeModernSetupForTesting(_ expectedEpoch: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, recognitionEpoch == expectedEpoch else {
                    continuation.resume(returning: false)
                    return
                }
                setRecognitionBackend(.speechAnalyzer)
                continuation.resume(returning: true)
            }
        }
    }

    func isModernRecognizerInstalledForTesting() async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(
                    returning: recognitionBackend == .speechAnalyzer
                        || modernResultsTask != nil
                        || modernAnalyzerTask != nil
                )
            }
        }
    }

    func beginRecognitionSessionForTesting() async {
        _ = await beginRecognitionSessionOnCaptureQueue()
    }

    func beginLegacySampleMappingForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.legacyRecognitionSampleMapping = self?.makeLegacyRecognitionSampleMapping()
                continuation.resume()
            }
        }
    }

    func appendLegacyNormalizedBufferForTesting(
        _ processingBuffer: AVAudioPCMBuffer,
        preservesIdentity: Bool
    ) async -> NormalizedAudioSampleInterval? {
        let sendableBuffer = UncheckedSendablePCMBuffer(value: processingBuffer)
        return await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let interval = publishRealtimePCM16Audio(from: sendableBuffer.value)
                appendCorrectionAudioBuffer(sendableBuffer.value)
                if let interval {
                    _ = legacyRecognitionSampleMapping?.append(
                        captureInterval: interval,
                        preserves16kFrameIdentity: preservesIdentity
                    )
                } else {
                    legacyRecognitionSampleMapping?.invalidate()
                }
                continuation.resume(returning: interval)
            }
        }
    }

    func queueLegacyCommittedEmissionForTesting(
        text: String,
        segments: [LegacySpeechSegmentTiming],
        promotionSegmentID: UUID? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                let audioProvenance = legacyRecognitionSampleMapping?.provenance(for: segments)
                queuedCommittedEmissionForTesting = makeCommittedEmission(
                    text: text,
                    promotionSegmentID: promotionSegmentID,
                    audioWAVData: finishCorrectionAudio(),
                    audioProvenance: audioProvenance
                )
                continuation.resume(returning: audioProvenance != nil)
            }
        }
    }

    @MainActor
    func invalidateNextCommittedDeliveryAfterAuthorizationForTesting() {
        shouldInvalidateCommittedDeliveryAfterAuthorizationForTesting = true
    }

    func pauseNextCommittedDeliveryAfterAuthorizationForTesting() {
        committedDeliveryTestingLock.lock()
        committedDeliveryPauseForTesting = CommittedDeliveryPauseForTesting()
        deliveryMutationAttemptSemaphoreForTesting = DispatchSemaphore(value: 0)
        deliveryMutationWaitingForTesting = false
        committedDeliveryTestingLock.unlock()
    }

    func waitForCommittedDeliveryAuthorizationPauseForTesting() async -> Bool {
        let pause = committedDeliveryPauseForTestingSnapshot()
        guard let pause else { return false }
        return await waitForTestingSemaphore(pause.authorizationReached)
    }

    func resumeCommittedDeliveryAfterAuthorizationForTesting() {
        committedDeliveryTestingLock.lock()
        let pause = committedDeliveryPauseForTesting
        committedDeliveryPauseForTesting = nil
        committedDeliveryTestingLock.unlock()
        pause?.resumeDelivery.signal()
    }

    func waitForDeliveryMutationAttemptForTesting() async -> Bool {
        let semaphore = deliveryMutationAttemptSemaphoreForTestingSnapshot()
        guard let semaphore else { return false }
        return await waitForTestingSemaphore(semaphore)
    }

    func isDeliveryMutationWaitingForTesting() -> Bool {
        committedDeliveryTestingLock.lock()
        defer { committedDeliveryTestingLock.unlock() }
        return deliveryMutationWaitingForTesting
    }

    private func committedDeliveryPauseForTestingSnapshot() -> CommittedDeliveryPauseForTesting? {
        committedDeliveryTestingLock.lock()
        defer { committedDeliveryTestingLock.unlock() }
        return committedDeliveryPauseForTesting
    }

    private func deliveryMutationAttemptSemaphoreForTestingSnapshot() -> DispatchSemaphore? {
        committedDeliveryTestingLock.lock()
        defer { committedDeliveryTestingLock.unlock() }
        return deliveryMutationAttemptSemaphoreForTesting
    }

    private func waitForTestingSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + .seconds(2)) == .success
                )
            }
        }
    }

    func beginSpeechAnalyzerRecognitionForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: -1)
                    return
                }
                setRecognitionBackend(.speechAnalyzer)
                continuation.resume(returning: recognitionEpoch)
            }
        }
    }

    func fallbackSpeechAnalyzerToLegacyForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.beginLegacyRecognitionAfterSpeechAnalyzerFallback()
                continuation.resume()
            }
        }
    }

    func markLegacyCorrectionAudioConversionGapForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.markLegacyCorrectionAudioConversionGap()
                continuation.resume()
            }
        }
    }

    func triggerModernTaskFailureForTesting(epoch: Int) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, acceptsSpeechAnalyzerFallback(for: epoch) else {
                    continuation.resume()
                    return
                }
                beginLegacyRecognitionAfterSpeechAnalyzerFallback()
                continuation.resume()
            }
        }
    }

    func isSpeechAnalyzerRecognitionCurrentForTesting(epoch: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(returning: self?.acceptsModernResult(for: epoch) ?? false)
            }
        }
    }

    func scheduleModernVADSilenceTimerForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, recognitionBackend == .speechAnalyzer else {
                    continuation.resume(returning: -1)
                    return
                }
                let epoch = recognitionEpoch
                scheduleSilenceCommit(trigger: .vadOffset, afterMs: 60_000)
                continuation.resume(returning: epoch)
            }
        }
    }

    func triggerModernVADSilenceTimerForTesting(epoch: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self,
                      acceptsSilenceCommitTimer(for: epoch, backend: .speechAnalyzer) else {
                    continuation.resume(returning: false)
                    return
                }
                forceCommitOnSilence(trigger: .vadOffset)
                continuation.resume(returning: true)
            }
        }
    }

    func enqueueModernCommittedEmissionForTesting(text: String, epoch: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, acceptsModernResult(for: epoch) else {
                    continuation.resume(returning: false)
                    return
                }
                let audioWAVData = finishCorrectionAudio()
                queuedCommittedEmissionForTesting = makeCommittedEmission(
                    text: text,
                    promotionSegmentID: nil,
                    audioWAVData: audioWAVData,
                    modernRecognitionEpoch: epoch
                )
                continuation.resume(returning: true)
            }
        }
    }

    @available(macOS 26.0, *)
    func enqueueModernPartialDraftForTesting(_ draft: DraftSegment?, epoch: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, acceptsModernResult(for: epoch) else {
                    continuation.resume(returning: false)
                    return
                }
                queuedModernPartialDraftDeliveryForTesting = makeModernPartialDraftDelivery(
                    draft,
                    recognitionEpoch: epoch
                )
                continuation.resume(returning: true)
            }
        }
    }

    @available(macOS 26.0, *)
    func deliverQueuedModernPartialDraftForTesting() async {
        let delivery = await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                let delivery = self?.queuedModernPartialDraftDeliveryForTesting
                self?.queuedModernPartialDraftDeliveryForTesting = nil
                continuation.resume(returning: delivery)
            }
        }
        guard let delivery else { return }
        await deliverModernPartialDraft(delivery)
    }

    @available(macOS 26.0, *)
    func enqueueModernTimedCommittedEmissionForTesting(
        snapshot: ModernSpeechTextSnapshot,
        epoch: Int
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self,
                      acceptsModernResult(for: epoch),
                      snapshot.text.isEmpty == false else {
                    continuation.resume(returning: false)
                    return
                }
                queuedCommittedEmissionForTesting = makeCommittedEmission(
                    text: snapshot.text,
                    promotionSegmentID: nil,
                    audioWAVData: finishCorrectionAudio(),
                    modernRecognitionEpoch: epoch,
                    modernTimedText: snapshot
                )
                continuation.resume(returning: true)
            }
        }
    }

    func pendingModernTextForTesting(
        _ snapshot: ModernSpeechTextSnapshot,
        committedPrefixText: String
    ) async -> ModernSpeechTextSnapshot {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: snapshot)
                    return
                }
                let previousPrefix = modernCommittedPrefixText
                modernCommittedPrefixText = committedPrefixText
                let pendingSnapshot = pendingModernText(from: snapshot)
                modernCommittedPrefixText = previousPrefix
                continuation.resume(returning: pendingSnapshot)
            }
        }
    }

    @MainActor
    func prepareModernTimedSentenceForTesting(
        _ snapshot: ModernSpeechTextSnapshot
    ) -> (text: String, audioProvenance: RecognizedAudioProvenance?)? {
        prepareModernTimedSentenceForEmission(snapshot)
    }

    func queueCommittedEmissionForTesting(text: String) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                queuedCommittedEmissionForTesting = makeCommittedEmission(
                    text: text,
                    promotionSegmentID: nil,
                    audioWAVData: finishCorrectionAudio()
                )
                continuation.resume()
            }
        }
    }

    /// Holds an already-tokenized emission for deterministic lifecycle tests. This
    /// models the interval after WAV extraction but before the MainActor delivery task.
    func captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
        text: String,
        through absoluteTime: TimeInterval? = nil
    ) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                let audioWAVData = finishCorrectionAudio(through: absoluteTime)
                queuedCommittedEmissionForTesting = makeCommittedEmission(
                    text: text,
                    promotionSegmentID: nil,
                    audioWAVData: audioWAVData
                )
                continuation.resume()
            }
        }
    }

    func deliverQueuedCommittedEmissionForTesting(clearDraftAfter: Bool = false) async {
        let emission = await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                let emission = self?.queuedCommittedEmissionForTesting
                self?.queuedCommittedEmissionForTesting = nil
                continuation.resume(returning: emission)
            }
        }
        guard let emission else { return }
        await emitCommittedSequence([emission], clearDraftAfter: clearDraftAfter)
    }

    func finishCorrectionAudioThroughForTesting(_ time: TimeInterval) async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                _ = self?.finishCorrectionAudio(through: time)
                continuation.resume()
            }
        }
    }

    func resetLegacyTranscriptionStateForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.resetLegacyTranscriptionState()
                continuation.resume()
            }
        }
    }

    func rebaseLegacySegmentsForTesting() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                committedSegmentCount = 1
                alignCommittedSegmentCount(to: [])
                continuation.resume()
            }
        }
    }

    private func resetCorrectionAudioBufferOnCaptureQueue() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.resetCorrectionAudioBuffer()
                continuation.resume()
            }
        }
    }

    private func beginRecognitionSessionOnCaptureQueue() async -> Int {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: -1)
                    return
                }
                beginCommittedDeliveryStateMutation()
                defer { endCommittedDeliveryStateMutation() }
                invalidateTranscriptDelivery()
                resetRecognitionEpoch()
                self.realtimeAudioFanout?.finish(error: .sourceSuperseded)
                self.realtimeAudioGeneration &+= 1
                self.normalizedAudioSampleClock.reset()
                self.legacyRecognitionSampleMapping = nil
                self.realtimeAudioFanout = RealtimePCM16AudioFanout(
                    sourceToken: UUID(),
                    generation: self.realtimeAudioGeneration
                )
                continuation.resume(returning: recognitionEpoch)
            }
        }
    }

    private func finishRealtimeAudioFanoutOnCaptureQueue() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.realtimeAudioFanout?.finish()
                self?.realtimeAudioFanout = nil
                continuation.resume()
            }
        }
    }

    private func resetCorrectionAudioBuffer() {
        correctionAudioBuffer.reset()
        lastCorrectionAudioBoundaryTime = nil
        legacyCorrectionAudioHasConversionGap = false
    }

    private func resetRecognitionEpoch() {
        recognitionEpoch &+= 1
        legacyRecognitionSampleMapping = nil
        modernRecognitionSampleMapping = nil
        transcriptDeliveryLock.lock()
        deliveryRecognitionEpoch = recognitionEpoch
        transcriptDeliveryLock.unlock()
        resetCorrectionAudioBuffer()
    }

    private func makeLegacyRecognitionSampleMapping() -> LegacyRecognitionSampleMapping? {
        guard let realtimeAudioFanout else { return nil }
        return LegacyRecognitionSampleMapping(
            sourceToken: realtimeAudioFanout.sourceToken,
            captureGeneration: realtimeAudioFanout.generation
        )
    }

    private func makeModernRecognitionSampleMapping() -> ModernRecognitionSampleMapping? {
        guard let realtimeAudioFanout else { return nil }
        return ModernRecognitionSampleMapping(
            sourceToken: realtimeAudioFanout.sourceToken,
            captureGeneration: realtimeAudioFanout.generation
        )
    }

    private func setRecognitionBackend(_ backend: RecognitionBackend) {
        if recognitionBackend != backend {
            legacyCorrectionAudioHasConversionGap = false
        }
        recognitionBackend = backend
        if backend == .speechAnalyzer {
            if modernRecognitionSampleMapping == nil {
                modernRecognitionSampleMapping = makeModernRecognitionSampleMapping()
            }
            legacyRecognitionSampleMapping = nil
        } else {
            modernRecognitionSampleMapping = nil
        }
        transcriptDeliveryLock.lock()
        deliveryRecognitionBackend = backend
        transcriptDeliveryLock.unlock()
    }

    private func invalidateTranscriptDelivery() {
        transcriptDeliveryLock.lock()
        transcriptDeliveryEpoch &+= 1
        transcriptDeliveryLock.unlock()
    }

    private func beginCommittedDeliveryStateMutation() {
        committedDeliveryTestingLock.lock()
        deliveryMutationWaitingForTesting = true
        let semaphore = deliveryMutationAttemptSemaphoreForTesting
        committedDeliveryTestingLock.unlock()
        semaphore?.signal()

        committedSequenceDeliveryGate.lock()

        committedDeliveryTestingLock.lock()
        deliveryMutationWaitingForTesting = false
        committedDeliveryTestingLock.unlock()
    }

    private func endCommittedDeliveryStateMutation() {
        committedSequenceDeliveryGate.unlock()
    }

    private func pauseCommittedDeliveryAfterAuthorizationForTestingIfNeeded() {
        committedDeliveryTestingLock.lock()
        let pause = committedDeliveryPauseForTesting
        committedDeliveryTestingLock.unlock()

        guard let pause else { return }
        pause.authorizationReached.signal()
        _ = pause.resumeDelivery.wait(timeout: .now() + .seconds(2))
    }

    private func requestRequiredPermissions(for source: InputSource) async throws {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestSpeechAuthorization()
            guard granted else {
                throw SessionError.speechPermissionDenied
            }
        case .denied, .restricted:
            throw SessionError.speechPermissionDenied
        @unknown default:
            throw SessionError.speechPermissionDenied
        }

        switch source.category {
        case .microphone:
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

            switch microphoneStatus {
            case .authorized:
                break
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw SessionError.microphonePermissionDenied
                }
            case .denied, .restricted:
                throw SessionError.microphonePermissionDenied
            @unknown default:
                throw SessionError.microphonePermissionDenied
            }
        case .application:
            break
        }
    }

    private func configureSpeechRecognizer(localeIdentifier: String) throws {
        stopModernSpeechRecognizer()
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionError.unsupportedSpeechLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SessionError.unavailableSpeechRecognizer(localeIdentifier)
        }

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        setRecognitionBackend(.legacy)
        legacyRecognitionSampleMapping = makeLegacyRecognitionSampleMapping()
        resetRecognitionFailureState()
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        resetDraftState()

        // Initialize Silero VAD engine.
        do {
            vadEngine = try SileroVADEngine()
        } catch {
            // VAD is optional — fall back to implicit ASR-based silence detection.
            vadEngine = nil
            Task {
                await emitError(
                    localized(
                        .sileroVadUnavailableFallbackFormat,
                        localizedErrorDescription(error)
                    )
                )
            }
        }
    }

    private func configureLegacySpeechRecognizer(
        localeIdentifier: String,
        expectedEpoch: Int
    ) async throws -> Bool {
        try await runOnCaptureQueue {
            guard self.recognitionEpoch == expectedEpoch else {
                return false
            }
            try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            return true
        }
    }

    /// Resolves `requestedLocale` to a locale the modern Speech stack actually carries.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` answers with an equivalent
    /// locale even for languages the stack does not support at all — `ru-RU` resolves
    /// to `ru_RU` on a Mac whose supported list holds no Russian — so its answer only
    /// counts when it appears in `supportedLocales`. Without this check the modern path
    /// is entered for languages only the legacy recognizer can serve.
    @available(macOS 26.0, *)
    static func modernSpeechLocale(equivalentTo requestedLocale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return nil
        }

        let supportedIdentifiers = await Set(SpeechTranscriber.supportedLocales.map(\.identifier))
        return supportedIdentifiers.contains(resolved.identifier) ? resolved : nil
    }

    private func configureModernSpeechRecognizer(
        localeIdentifier: String,
        expectedEpoch: Int
    ) async throws -> Bool {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            return false
        }

        do {
            return try await configureSpeechAnalyzerRecognizer(
                localeIdentifier: localeIdentifier,
                expectedEpoch: expectedEpoch
            )
        } catch {
            return false
        }
    }

    @available(macOS 26.0, *)
    private func configureSpeechAnalyzerRecognizer(
        localeIdentifier: String,
        expectedEpoch: Int
    ) async throws -> Bool {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let resolvedLocale = await Self.modernSpeechLocale(equivalentTo: requestedLocale) else {
            return false
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        try await ensureSpeechAnalyzerAssetsIfNeeded(for: transcriber, locale: resolvedLocale)

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let context = AnalysisContext()
        if recognitionContextualStrings.isEmpty == false {
            context.contextualStrings[.general] = recognitionContextualStrings
        }
        try await analyzer.setContext(context)

        let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: processingFormat
        ) ?? processingFormat
        try await analyzer.prepareToAnalyze(in: preferredFormat)

        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            inputContinuation = continuation
        }

        guard let inputContinuation else {
            return false
        }

        let installed = await installSpeechAnalyzerRecognizer(
            analyzer: analyzer,
            transcriber: transcriber,
            preferredFormat: preferredFormat,
            inputStream: inputStream,
            inputContinuation: inputContinuation,
            expectedEpoch: expectedEpoch
        )
        guard installed else {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            return false
        }
        return true
    }

    /// Installs all modern-recognition state only after confirming this start still owns
    /// the capture queue. Asset setup above can suspend while stop or fallback advances
    /// the epoch; a stale setup must never resurrect the modern backend.
    @available(macOS 26.0, *)
    private func installSpeechAnalyzerRecognizer(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        preferredFormat: AVAudioFormat,
        inputStream: AsyncStream<AnalyzerInput>,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        expectedEpoch: Int
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self, self.recognitionEpoch == expectedEpoch else {
                    continuation.resume(returning: false)
                    return
                }

                self.stopModernSpeechRecognizer()
                self.speechAnalyzerState = analyzer
                self.speechTranscriberState = transcriber
                self.analyzerInputContinuationState = inputContinuation
                self.analyzerInputFormat = preferredFormat
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.speechRecognizer = nil
                self.audioConverter = nil
                self.audioConverterInputSignature = nil
                self.resetLegacyTranscriptionState()
                self.resetModernTranscriptionState()
                self.cancelSilenceTimer()
                self.cancelVADSilenceTimer()
                self.resetDraftState()
                self.lastModernCommittedResultIdentity = nil
                self.setRecognitionBackend(.speechAnalyzer)

                // Initialize Silero VAD engine for draft confidence / silence scoring only.
                do {
                    self.vadEngine = try SileroVADEngine()
                } catch {
                    self.vadEngine = nil
                }

                let modernEpoch = expectedEpoch
                self.modernResultsTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            self?.captureQueue.async { [weak self] in
                                guard let self, self.acceptsModernResult(for: modernEpoch) else { return }
                                self.processModernRecognitionResult(result, epoch: modernEpoch)
                            }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.fallbackFromSpeechAnalyzer(error, epoch: modernEpoch)
                    }
                }

                self.modernAnalyzerTask = Task { [weak self] in
                    do {
                        try await analyzer.start(inputSequence: inputStream)
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.fallbackFromSpeechAnalyzer(error, epoch: modernEpoch)
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAnalyzerAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let installedLocales = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        if installedLocales.contains(locale.identifier) {
            return
        }

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installer.downloadAndInstall()
        }
    }

    private func stopModernSpeechRecognizer() {
        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = nil
        modernResultsTask?.cancel()
        modernResultsTask = nil
        lastModernCommittedResultIdentity = nil
        setRecognitionBackend(.legacy)
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        resetModernTranscriptionState()

        if #available(macOS 26.0, *) {
            (analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            analyzerInputContinuationState = nil
            modernAnalyzerInputFinishForTesting?()
            modernAnalyzerInputFinishForTesting = nil
            modernAnalyzerInputYieldForTesting = nil
            let analyzer = speechAnalyzerState as? SpeechAnalyzer
            speechAnalyzerState = nil
            speechTranscriberState = nil
            analyzerInputFormat = nil

            if let analyzer {
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
    }

    private func fallbackFromSpeechAnalyzer(_ error: Error, epoch: Int) {
        captureQueue.async { [weak self] in
            guard let self,
                  self.acceptsSpeechAnalyzerFallback(for: epoch),
                  let localeIdentifier = self.activeLocaleIdentifier else {
                return
            }

            self.beginLegacyRecognitionAfterSpeechAnalyzerFallback()

            do {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            } catch {
                self.stopRecognitionAndSurface(error)
            }
        }
    }

    private func acceptsSpeechAnalyzerFallback(for epoch: Int) -> Bool {
        acceptsModernResult(for: epoch)
    }

    /// Builds a recognition request, keeping recognition on device wherever the
    /// recognizer has a local model. Languages without one — Chinese on Intel, say —
    /// are only served by Apple's speech service, and refusing that would leave them
    /// with no recognition at all.
    private func makeRecognitionRequest(
        requiresOnDeviceRecognition: Bool
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.contextualStrings = recognitionContextualStrings
        return request
    }

    private func sanitizeContextualStrings(_ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.count <= 40 else {
                continue
            }

            let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(normalized).inserted else {
                continue
            }

            result.append(trimmed)
            if result.count >= 60 {
                break
            }
        }

        return result
    }

    private func resetAudioProcessingState() {
        preprocessingConverter = nil
        preprocessingConverterInputSignature = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        noiseFloorRMS = 0.0012
        highPassPreviousInput = 0
        highPassPreviousOutput = 0
    }

    private func resetModernTranscriptionState() {
        latestModernText = ""
        latestModernTimedText = nil
        modernCommittedPrefixText = ""
    }

    private func resetLegacyTranscriptionState() {
        committedSegmentCount = 0
        self.committedAudioBoundaryTime = nil
        latestSegments = []
        latestFormattedText = ""
    }

    private func startMicrophoneCapture(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddSelectedMicrophoneToCaptureSession)
            )
        }

        guard session.canAddOutput(output) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddMicrophoneAudioOutput)
            )
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        microphoneCaptureSession = session
        session.startRunning()
    }

    @MainActor
    private func makeApplicationCaptureDescriptor(for source: InputSource) throws -> ApplicationCaptureDescriptor {
        ApplicationCaptureDescriptor(
            appName: source.name,
            processObjectIDs: try resolveApplicationProcessObjectIDs(for: source),
            readStreamFailureMessage: localized(.failedToReadCapturedAudioStreamFormat, source.name)
        )
    }

    private func startApplicationAudioCapture(descriptor: ApplicationCaptureDescriptor) throws {
        let capture = ApplicationAudioCapture(
            appName: descriptor.appName,
            processObjectIDs: descriptor.processObjectIDs,
            readStreamFailureMessage: descriptor.readStreamFailureMessage,
            queue: captureQueue,
            audioHandler: { [weak self] buffer in
                self?.append(audioBuffer: buffer)
            },
            errorHandler: { [weak self] message in
                Task {
                    await self?.emitError(message)
                }
            }
        )

        do {
            try capture.start()
            applicationAudioCapture = capture
        } catch let error as ApplicationAudioCapture.CaptureError {
            throw mapApplicationCaptureError(error)
        } catch {
            throw SessionError.failedToStartCapture(
                localized(
                    .failedToStageWithReasonFormat,
                    "start application audio capture",
                    localizedErrorDescription(error)
                )
            )
        }
    }

    private func resolveApplicationProcessObjectIDs(for source: InputSource) throws -> [AudioObjectID] {
        let runningApp = try resolveRunningApplication(for: source)
        let system = AudioHardwareSystem.shared
        let audioProcesses = try system.processes
        let targetAssociation = ApplicationProcessAssociation(runningApplication: runningApp)
        var relatedProcessIDs: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()

        for process in audioProcesses {
            let processID = try process.pid
            let processObjectID = process.id
            let processBundleIdentifier = (try? process.bundleID) ?? ""
            let processAppBundleURL = applicationBundleURL(forProcessID: processID)
            let executablePath = executablePath(forProcessID: processID)

            let matchesMainProcess = processID == runningApp.processIdentifier
            let matchesBundleIdentifier = targetAssociation.matchesExactBundleIdentifier(processBundleIdentifier)
            let matchesBundleURL = targetAssociation.matchesApplicationBundleURL(processAppBundleURL)
            let matchesHelperBundle = targetAssociation.matchesHelperBundleIdentifier(processBundleIdentifier)
            let matchesHelperPath = targetAssociation.matchesHelperExecutablePath(executablePath)

            guard matchesMainProcess
                || matchesBundleIdentifier
                || matchesBundleURL
                || matchesHelperBundle
                || matchesHelperPath else {
                    continue
                }

            if seen.insert(processObjectID).inserted {
                relatedProcessIDs.append(processObjectID)
            }
        }

        if relatedProcessIDs.isEmpty {
            if let exactProcess = try system.process(for: runningApp.processIdentifier) {
                return [exactProcess.id]
            }

            throw SessionError.applicationNotProducingAudio(source.name)
        }

        return relatedProcessIDs
    }

    private func resolveRunningApplication(for source: InputSource) throws -> NSRunningApplication {
        let runningApps = NSWorkspace.shared.runningApplications
        let application: NSRunningApplication?

        if let processIdentifier = source.processIdentifierHint {
            application = runningApps.first(where: { $0.processIdentifier == processIdentifier })
        } else {
            application = runningApps.first(where: { $0.bundleIdentifier == source.detail })
        }

        guard let application else {
            throw SessionError.missingApplication(source.name)
        }

        return application
    }

    private func append(sampleBuffer: CMSampleBuffer) {
        let dataIsReady = CMSampleBufferDataIsReady(sampleBuffer)
        let pcmBuffer = dataIsReady ? pcmBuffer(from: sampleBuffer) : nil
        appendCapturedSampleBuffer(
            dataIsReady: dataIsReady,
            pcmBuffer: pcmBuffer
        ) {
            guard self.recognitionBackend == .legacy,
                  let recognitionRequest = self.recognitionRequest else {
                return
            }
            // Keep legacy recognition alive without inventing a second normalization path.
            recognitionRequest.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    private func appendCapturedSampleBuffer(
        dataIsReady: Bool,
        pcmBuffer: AVAudioPCMBuffer?,
        appendRawSampleBuffer: () -> Void
    ) {
        guard dataIsReady else {
            invalidateRecognitionMappingsForCaptureGap()
            return
        }
        guard let pcmBuffer else {
            invalidateRecognitionMappingsForCaptureGap()
            appendRawSampleBuffer()
            return
        }
        append(audioBuffer: pcmBuffer)
    }

    private func invalidateRecognitionMappingsForCaptureGap() {
        markLegacyCorrectionAudioConversionGap()
        legacyRecognitionSampleMapping?.invalidate()
        modernRecognitionSampleMapping?.invalidate()
    }

    func appendCapturedSampleBufferForTesting(dataIsReady: Bool, convertedPCMBuffer: AVAudioPCMBuffer?) async {
        let sendableBuffer = convertedPCMBuffer.map(UncheckedSendablePCMBuffer.init)
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                appendCapturedSampleBuffer(
                    dataIsReady: dataIsReady,
                    pcmBuffer: sendableBuffer?.value,
                    appendRawSampleBuffer: {}
                )
                continuation.resume()
            }
        }
    }

    /// Converts a CMSampleBuffer from AVCaptureSession into an AVAudioPCMBuffer so it can
    /// share the format-conversion and gain-boost pipeline in append(audioBuffer:).
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        var mutableASBD = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }

    private func append(audioBuffer: AVAudioPCMBuffer) {
        guard audioBuffer.frameLength > 0 else {
            return
        }

        guard let processingBuffer = prepareProcessingBuffer(from: audioBuffer) else {
            if recognitionBackend == .legacy {
                legacyRecognitionSampleMapping?.invalidate()
            } else if recognitionBackend == .speechAnalyzer {
                modernRecognitionSampleMapping?.invalidate()
            }
            return
        }

        let audioLevels = cleanUpSpeechBuffer(processingBuffer)
        boostIfQuiet(buffer: processingBuffer, levels: audioLevels)
        let captureSampleInterval = publishRealtimePCM16Audio(from: processingBuffer)
        appendCorrectionAudioBuffer(processingBuffer)

        if let vadEngine {
            let vadResult = vadEngine.process(buffer: processingBuffer)
            lastVADProbability = vadResult.speechProbability

            if vadResult.containsSpeechOffset {
                scheduleVADSilenceCommit()
            }
            if vadResult.containsSpeechOnset {
                cancelVADSilenceTimer()
            }
        }

        if recognitionBackend == .speechAnalyzer {
            appendToSpeechAnalyzer(processingBuffer, captureSampleInterval: captureSampleInterval)
            return
        }

        guard let recognitionRequest else {
            return
        }

        guard let speechInputBuffer = makeRecognizerBuffer(
            from: processingBuffer,
            nativeFormat: recognitionRequest.nativeAudioFormat
        ) else {
            legacyRecognitionSampleMapping?.invalidate()
            return
        }
        let recognizerBuffer = speechInputBuffer.buffer

        guard let captureSampleInterval else {
            legacyRecognitionSampleMapping?.invalidate()
            recognitionRequest.append(recognizerBuffer)
            return
        }

        let preserves16kFrameIdentity = NormalizedAudioFrameIdentity.preservesNormalizedSamples(
            captureInterval: captureSampleInterval,
            inputSampleRate: processingBuffer.format.sampleRate,
            inputChannelCount: Int(processingBuffer.format.channelCount),
            inputFrameCount: Int(processingBuffer.frameLength),
            outputSampleRate: recognizerBuffer.format.sampleRate,
            outputChannelCount: Int(recognizerBuffer.format.channelCount),
            outputFrameCount: Int(recognizerBuffer.frameLength),
            unchangedBufferObject: processingBuffer === recognizerBuffer,
            verifiedRepackProof: speechInputBuffer.verifiedRepackProof,
            inputBuffer: processingBuffer,
            outputBuffer: recognizerBuffer
        )
        _ = legacyRecognitionSampleMapping?.append(
            captureInterval: captureSampleInterval,
            preserves16kFrameIdentity: preserves16kFrameIdentity
        )

        // Always forward audio to the recognizer — VAD is used only
        // for silence-commit timing, not to gate the audio stream.
        recognitionRequest.append(recognizerBuffer)
    }

    private func appendCorrectionAudioBuffer(_ processingBuffer: AVAudioPCMBuffer) {
        guard correctionAudioCaptureEnabled else { return }
        correctionAudioBuffer.append(processingBuffer)
    }

    @discardableResult
    private func publishRealtimePCM16Audio(
        from processingBuffer: AVAudioPCMBuffer
    ) -> NormalizedAudioSampleInterval? {
        guard processingBuffer.frameLength > 0,
              processingBuffer.format.commonFormat == .pcmFormatFloat32,
              processingBuffer.format.sampleRate == 16_000,
              processingBuffer.format.channelCount == 1,
              let samples = processingBuffer.floatChannelData?[0] else {
            if realtimeAudioFanout?.isActive == true {
                realtimeAudioFanout?.finish(error: .invalidAudioChunk)
            }
            return nil
        }

        let frameCount = Int(processingBuffer.frameLength)
        guard let sampleInterval = normalizedAudioSampleClock.append(frameCount: frameCount) else {
            realtimeAudioFanout?.finish(error: .invalidAudioChunk)
            return nil
        }

        guard let fanout = realtimeAudioFanout, fanout.isActive else {
            return sampleInterval
        }

        guard frameCount <= fanout.maximumBufferedFrames else {
            fanout.finish(error: .backpressureExceeded)
            return sampleInterval
        }

        let pcm16LE = Mono16kPCM16SampleConverter.littleEndianData(from: samples, frameCount: frameCount)

        _ = fanout.offer(
            pcm16LE: pcm16LE,
            frameCount: frameCount,
            sampleInterval: sampleInterval,
            sourceToken: fanout.sourceToken,
            generation: fanout.generation,
            captureTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        return sampleInterval
    }

    private func finishCorrectionAudio(through absoluteTime: TimeInterval? = nil) -> Data? {
        guard correctionAudioCaptureEnabled else { return nil }

        if recognitionBackend == .legacy, legacyCorrectionAudioHasConversionGap {
            legacyCorrectionAudioHasConversionGap = false
            correctionAudioBuffer.reset()
            lastCorrectionAudioBoundaryTime = absoluteTime?.isFinite == true ? absoluteTime : nil
            return nil
        }

        if let absoluteTime {
            guard absoluteTime.isFinite,
                  lastCorrectionAudioBoundaryTime.map({ absoluteTime > $0 }) ?? true else {
                return nil
            }
            lastCorrectionAudioBoundaryTime = absoluteTime
        }

        return correctionAudioBuffer.finish(through: absoluteTime)
    }

    private func markLegacyCorrectionAudioConversionGap() {
        guard recognitionBackend == .legacy else { return }
        legacyRecognitionSampleMapping?.invalidate()
        guard correctionAudioCaptureEnabled else { return }
        legacyCorrectionAudioHasConversionGap = true
    }

    private func makeCommittedEmissionDeliveryToken(
        audioWAVData: Data?,
        modernRecognitionEpoch: Int?
    ) -> CommittedEmissionDeliveryToken {
        transcriptDeliveryLock.lock()
        let deliveryToken = CommittedEmissionDeliveryToken(
            sessionEpoch: transcriptDeliveryEpoch,
            audioCaptureEpoch: audioWAVData == nil ? nil : correctionAudioCaptureEpoch,
            modernRecognitionEpoch: modernRecognitionEpoch
        )
        transcriptDeliveryLock.unlock()
        return deliveryToken
    }

    private func makeModernPartialDraftDelivery(
        _ draft: DraftSegment?,
        recognitionEpoch: Int
    ) -> ModernPartialDraftDelivery {
        ModernPartialDraftDelivery(
            draft: draft,
            deliveryToken: makeCommittedEmissionDeliveryToken(
                audioWAVData: nil,
                modernRecognitionEpoch: recognitionEpoch
            )
        )
    }

    private func scheduleModernPartialDraft(_ draft: DraftSegment?, recognitionEpoch: Int) {
        let delivery = makeModernPartialDraftDelivery(draft, recognitionEpoch: recognitionEpoch)
        Task { @MainActor [weak self] in
            self?.deliverModernPartialDraft(delivery)
        }
    }

    @MainActor
    private func deliverModernPartialDraft(_ delivery: ModernPartialDraftDelivery) {
        committedSequenceDeliveryGate.lock()
        defer { committedSequenceDeliveryGate.unlock() }

        guard committedEmissionDeliveryPermission(for: delivery.deliveryToken) != .suppress else {
            return
        }
        emitPartialDraft(delivery.draft)
    }

    private func makeCommittedEmission(
        text: String,
        promotionSegmentID: UUID?,
        audioWAVData: Data?,
        audioProvenance: RecognizedAudioProvenance? = nil,
        modernRecognitionEpoch: Int? = nil,
        modernTimedText: ModernSpeechTextSnapshot? = nil
    ) -> CommittedEmission {
        let deliveryToken = makeCommittedEmissionDeliveryToken(
            audioWAVData: audioWAVData,
            modernRecognitionEpoch: modernRecognitionEpoch
        )
        return CommittedEmission(
            text: text,
            promotionSegmentID: promotionSegmentID,
            audioWAVData: audioWAVData,
            audioProvenance: audioProvenance,
            modernTimedText: modernTimedText,
            deliveryToken: deliveryToken
        )
    }

    private func committedEmissionDeliveryPermission(
        for token: CommittedEmissionDeliveryToken
    ) -> CommittedEmissionDeliveryPermission {
        transcriptDeliveryLock.lock()
        defer { transcriptDeliveryLock.unlock() }

        guard transcriptDeliveryEpoch == token.sessionEpoch else {
            return .suppress
        }

        if let modernRecognitionEpoch = token.modernRecognitionEpoch,
           (deliveryRecognitionEpoch != modernRecognitionEpoch
               || deliveryRecognitionBackend != .speechAnalyzer) {
            return .suppress
        }

        if let audioCaptureEpoch = token.audioCaptureEpoch,
           (correctionAudioCaptureEnabled == false || correctionAudioCaptureEpoch != audioCaptureEpoch) {
            return .textOnly
        }

        return .textAndAudio
    }

    private func acceptsModernResult(for epoch: Int) -> Bool {
        recognitionEpoch == epoch && recognitionBackend == .speechAnalyzer
    }

    private func beginLegacyRecognitionAfterSpeechAnalyzerFallback() {
        committedSequenceDeliveryGate.lock()
        defer { committedSequenceDeliveryGate.unlock() }

        // A fallback starts a legacy recognizer whose segment timestamps begin at zero.
        // Discard any modern timeline before the legacy task can receive callbacks.
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        invalidateTranscriptDelivery()
        resetRecognitionEpoch()
        stopModernSpeechRecognizer()
    }

    private func appendToSpeechAnalyzer(
        _ processingBuffer: AVAudioPCMBuffer,
        captureSampleInterval: NormalizedAudioSampleInterval?
    ) {
        guard #available(macOS 26.0, *),
              recognitionBackend == .speechAnalyzer else {
            if recognitionBackend == .speechAnalyzer {
                modernRecognitionSampleMapping?.invalidate()
            }
            return
        }

        guard let speechInputBuffer = makeSpeechAnalyzerBuffer(from: processingBuffer) else {
            modernRecognitionSampleMapping?.invalidate()
            return
        }
        let analyzerBuffer = speechInputBuffer.buffer

        let deliver: (CMTime?) -> ModernAnalyzerInputDeliveryOutcome
        if let yieldForTesting = modernAnalyzerInputYieldForTesting {
            deliver = { bufferStartTime in yieldForTesting(analyzerBuffer, bufferStartTime) }
        } else {
            guard let inputContinuation = analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation else {
                modernRecognitionSampleMapping?.invalidate()
                return
            }
            deliver = { bufferStartTime in
                switch inputContinuation.yield(
                    AnalyzerInput(buffer: analyzerBuffer, bufferStartTime: bufferStartTime)
                ) {
                case .enqueued:
                    return .enqueued
                case .dropped:
                    return .dropped
                case .terminated:
                    return .terminated
                @unknown default:
                    return .terminated
                }
            }
        }

        ModernAnalyzerInputAppender.appendAndDeliver(
            mapping: &modernRecognitionSampleMapping,
            captureSampleInterval: captureSampleInterval,
            inputSampleRate: processingBuffer.format.sampleRate,
            inputChannelCount: Int(processingBuffer.format.channelCount),
            inputFrameCount: Int(processingBuffer.frameLength),
            outputSampleRate: analyzerBuffer.format.sampleRate,
            outputChannelCount: Int(analyzerBuffer.format.channelCount),
            outputFrameCount: Int(analyzerBuffer.frameLength),
            unchangedBufferObject: processingBuffer === analyzerBuffer,
            verifiedRepackProof: speechInputBuffer.verifiedRepackProof,
            inputBuffer: processingBuffer,
            outputBuffer: analyzerBuffer,
            deliver: deliver
        )
    }

    private func prepareProcessingBuffer(from audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if audioBuffer.format.matches(processingFormat) {
            guard let copiedBuffer = copyPCMBuffer(audioBuffer) else {
                Task {
                    await emitError(localized(.failedToCopyCapturedAudioForSpeechPreprocessing))
                }
                return nil
            }
            return copiedBuffer
        }

        let inputSignature = AudioFormatSignature(audioBuffer.format)
        if preprocessingConverterInputSignature != inputSignature {
            preprocessingConverter = AVAudioConverter(from: audioBuffer.format, to: processingFormat)
            preprocessingConverterInputSignature = inputSignature
        }

        guard let preprocessingConverter else {
            Task {
                await emitError(localized(.failedToPrepareSpeechPreprocessingAudioConverter))
            }
            return nil
        }

        return convertBuffer(
            audioBuffer,
            using: preprocessingConverter,
            to: processingFormat,
            allocationError: localized(.failedToAllocateSpeechPreprocessingAudioBuffer),
            failurePrefix: localized(.failedToPreprocessCapturedAudio)
        )
    }

    private func makeRecognizerBuffer(
        from processingBuffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat
    ) -> SpeechInputPCMBuffer? {
        if processingBuffer.format.matches(nativeFormat) {
            return SpeechInputPCMBuffer(buffer: processingBuffer, verifiedRepackProof: nil)
        }

        if let repacked = NormalizedMono16kPCM16Repacker.repack(processingBuffer, to: nativeFormat) {
            return SpeechInputPCMBuffer(buffer: repacked.buffer, verifiedRepackProof: repacked.proof)
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: processingBuffer.format, to: nativeFormat)
            audioConverterInputSignature = inputSignature
        }

        guard let audioConverter else {
            Task {
                await emitError(localized(.failedToPrepareAudioConverterForSpeechRecognition))
            }
            return nil
        }

        guard let convertedBuffer = convertBuffer(
            processingBuffer,
            using: audioConverter,
            to: nativeFormat,
            allocationError: localized(.failedToAllocateSpeechRecognitionAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechRecognition)
        ) else { return nil }
        return SpeechInputPCMBuffer(buffer: convertedBuffer, verifiedRepackProof: nil)
    }

    private func makeSpeechAnalyzerBuffer(from processingBuffer: AVAudioPCMBuffer) -> SpeechInputPCMBuffer? {
        guard #available(macOS 26.0, *),
              let analyzerInputFormat else {
            return SpeechInputPCMBuffer(buffer: processingBuffer, verifiedRepackProof: nil)
        }

        if processingBuffer.format.matches(analyzerInputFormat) {
            return SpeechInputPCMBuffer(buffer: processingBuffer, verifiedRepackProof: nil)
        }

        if let repacked = NormalizedMono16kPCM16Repacker.repack(
            processingBuffer,
            to: analyzerInputFormat
        ) {
            return SpeechInputPCMBuffer(buffer: repacked.buffer, verifiedRepackProof: repacked.proof)
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if modernAudioConverterInputSignature != inputSignature {
            modernAudioConverter = AVAudioConverter(from: processingBuffer.format, to: analyzerInputFormat)
            modernAudioConverterInputSignature = inputSignature
        }

        guard let modernAudioConverter else {
            return nil
        }

        guard let convertedBuffer = convertBuffer(
            processingBuffer,
            using: modernAudioConverter,
            to: analyzerInputFormat,
            allocationError: localized(.failedToAllocateSpeechAnalyzerAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechAnalyzer)
        ) else { return nil }
        return SpeechInputPCMBuffer(buffer: convertedBuffer, verifiedRepackProof: nil)
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat,
        allocationError: String,
        failurePrefix: String
    ) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)),
            1
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            Task { await emitError(allocationError) }
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            Task {
                await emitError("\(failurePrefix): \(conversionError.localizedDescription)")
            }
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard outputBuffer.frameLength > 0 else { return nil }
            return outputBuffer
        case .error:
            Task {
                await emitError("\(failurePrefix).")
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                continue
            }

            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
        }

        return copy
    }

    private func cleanUpSpeechBuffer(_ buffer: AVAudioPCMBuffer) -> AudioLevelStats {
        guard let channelData = buffer.floatChannelData else {
            return AudioLevelStats(peak: 0, rms: 0)
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return AudioLevelStats(peak: 0, rms: 0)
        }

        let samples = channelData[0]
        let highPassAlpha: Float = 0.995
        var sumSquares: Float = 0
        var peak: Float = 0

        for index in 0..<frameCount {
            let input = samples[index]
            let filtered = input - highPassPreviousInput + highPassAlpha * highPassPreviousOutput
            highPassPreviousInput = input
            highPassPreviousOutput = filtered
            samples[index] = filtered

            let magnitude = abs(filtered)
            sumSquares += magnitude * magnitude
            if magnitude > peak {
                peak = magnitude
            }
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        updateNoiseFloorEstimate(rms: rms, peak: peak)
        return AudioLevelStats(peak: peak, rms: rms)
    }

    private func updateNoiseFloorEstimate(rms: Float, peak: Float) {
        let clampedRMS = min(max(rms, 0.0003), 0.03)
        let likelyNoiseOnly = peak < 0.02 || rms <= noiseFloorRMS * 1.6
        let smoothing: Float = likelyNoiseOnly ? 0.08 : 0.01
        noiseFloorRMS = max(0.0005, min(0.02, noiseFloorRMS * (1 - smoothing) + clampedRMS * smoothing))
    }

    // MARK: - Audio gain boost

    /// Amplifies a Float32 PCM buffer when the signal is too quiet for the ASR's VAD to
    /// detect reliably. Only applies when the peak is in the "quiet speech" range
    /// (0.002–0.30); leaves silence and normal-to-loud audio untouched.
    ///
    /// - Quiet speech range: peak 0.002 – 0.30 → boost toward target peak 0.35 (up to 4×)
    /// - Silence (< 0.002): no boost (would just amplify noise floor)
    /// - Normal/loud (≥ 0.30): no boost (already loud enough; avoid clipping)
    private func boostIfQuiet(buffer: AVAudioPCMBuffer, levels: AudioLevelStats) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        let peak = levels.peak
        let rms = levels.rms
        let speechFloor = max(0.006, noiseFloorRMS * 4.0)
        let targetPeak: Float = 0.35
        guard peak > speechFloor,
              rms > max(noiseFloorRMS * 1.8, 0.0015),
              peak < targetPeak else {
            return
        }

        let gain = min(targetPeak / peak, 3.0)
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameCount {
                var v = ptr[i] * gain
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                ptr[i] = v
            }
        }
    }

    @MainActor
    private func emitRecognizedSentence(_ sentence: RecognizedSentence) {
        transcriptHandler?(sentence)
    }

    @MainActor
    private func emitCommittedSentence(
        text: String,
        promotionSegmentID: UUID?,
        audioWAVData: Data?,
        audioProvenance: RecognizedAudioProvenance? = nil
    ) -> Bool {
        let handler = transcriptHandler
        guard let handler else {
            return false
        }

        handler(
            RecognizedSentence(
                text: text,
                promotionSegmentID: promotionSegmentID,
                audioWAVData: audioWAVData,
                audioProvenance: audioProvenance
            )
        )
        return true
    }

    @MainActor
    private func emitRecognizedText(
        _ text: String,
        promotionSegmentID: UUID? = nil,
        audioWAVData: Data? = nil
    ) {
        let sentenceTexts = splitCommittedEmissionUnits(in: text)

        for (index, sentenceText) in sentenceTexts.enumerated() {
            emitRecognizedSentence(
                RecognizedSentence(
                    text: sentenceText,
                    promotionSegmentID: index == 0 ? promotionSegmentID : nil,
                    audioWAVData: audioWAVData
                )
            )
        }
    }

    @MainActor
    private func emitCommittedSequence(
        _ emissions: [CommittedEmission],
        clearDraftAfter: Bool = false
    ) {
        pruneRecentCommittedSentenceHistory()

        for emission in emissions {
            emitCommittedEmissionTransaction(emission)
        }

        if clearDraftAfter, let deliveryToken = emissions.last?.deliveryToken {
            committedSequenceDeliveryGate.lock()
            defer { committedSequenceDeliveryGate.unlock() }

            guard committedEmissionDeliveryPermission(for: deliveryToken) != .suppress else {
                return
            }
            emitPartialDraft(nil)
        }
    }

    /// Delivers all units produced by one outer emission as one transaction. Capture
    /// opt-out, stop, and modern fallback take this same gate before mutating their
    /// delivery state, so the audio decision cannot change between split units.
    @MainActor
    private func emitCommittedEmissionTransaction(_ emission: CommittedEmission) {
        committedSequenceDeliveryGate.lock()
        defer { committedSequenceDeliveryGate.unlock() }

        let deliveryPermission = committedEmissionDeliveryPermission(for: emission.deliveryToken)
        guard deliveryPermission != .suppress else {
            return
        }

        if shouldInvalidateCommittedDeliveryAfterAuthorizationForTesting {
            shouldInvalidateCommittedDeliveryAfterAuthorizationForTesting = false
            invalidateTranscriptDelivery()
            return
        }

        let audioWAVData = deliveryPermission == .textAndAudio ? emission.audioWAVData : nil
        pauseCommittedDeliveryAfterAuthorizationForTestingIfNeeded()

        let modernUnits = emission.modernTimedText.map(splitModernTimedEmissionUnits)
        let sentenceUnits: [(text: String, timedText: ModernSpeechTextSnapshot?)]
        if let modernUnits {
            sentenceUnits = modernUnits.map { ($0.text, $0) }
        } else {
            sentenceUnits = splitCommittedEmissionUnits(in: emission.text).map { ($0, nil) }
        }
        var pendingPromotionID = emission.promotionSegmentID

        for unit in sentenceUnits {
            let preparedText: String
            let sentenceProvenance: RecognizedAudioProvenance?
            if let timedText = unit.timedText {
                guard let prepared = prepareModernTimedSentenceForEmission(timedText) else {
                    continue
                }
                preparedText = prepared.text
                sentenceProvenance = prepared.audioProvenance
            } else {
                guard let prepared = prepareCommittedSentenceForEmission(unit.text) else {
                    continue
                }
                preparedText = prepared.text
                sentenceProvenance = sentenceUnits.count == 1 && preparedText == unit.text
                    ? emission.audioProvenance
                    : nil
            }

            if emitCommittedSentence(
                text: preparedText,
                promotionSegmentID: pendingPromotionID,
                audioWAVData: audioWAVData,
                audioProvenance: sentenceProvenance
            ) {
                rememberCommittedSentence(preparedText)
            }
            pendingPromotionID = nil
        }
    }

    @MainActor
    private func prepareModernTimedSentenceForEmission(
        _ timedText: ModernSpeechTextSnapshot
    ) -> (text: String, audioProvenance: RecognizedAudioProvenance?)? {
        guard let prepared = prepareCommittedSentenceForEmission(timedText.text) else {
            return nil
        }
        let preparedTimedText = timedText.slice(relativeUTF16Range: prepared.sourceUTF16Range)
        let provenance = preparedTimedText?.text == prepared.text
            ? preparedTimedText?.audioProvenance
            : nil
        return (prepared.text, provenance)
    }

    private func splitModernTimedEmissionUnits(
        in snapshot: ModernSpeechTextSnapshot
    ) -> [ModernSpeechTextSnapshot] {
        let source = snapshot.text
        guard source.isEmpty == false else { return [] }
        let nsSource = source as NSString
        let ranges = sentenceRanges(in: nsSource)
        let sentenceRanges = ranges.isEmpty
            ? [0..<snapshot.utf16Count]
            : ranges.map { $0.location..<($0.location + $0.length) }

        return sentenceRanges.flatMap { range in
            let sourceUnit = modernSlice(snapshot, relativeRange: range)
            let trimmedUnit = sourceUnit.trimmingWhitespace()
                ?? ModernSpeechTextSnapshot(
                    text: nsSource.substring(with: NSRange(location: range.lowerBound, length: range.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    runs: []
                )
            return splitModernDialogueUnit(trimmedUnit)
        }
    }

    private func splitModernDialogueUnit(
        _ snapshot: ModernSpeechTextSnapshot
    ) -> [ModernSpeechTextSnapshot] {
        let text = snapshot.text
        guard let separatorRange = singleDialogueClauseSeparatorRange(in: text) else {
            return text.isEmpty ? [] : [snapshot]
        }

        let left = String(text[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(text[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldSplitDialogueClauses(left: left, right: right) else {
            return text.isEmpty ? [] : [snapshot]
        }

        let separatorStart = text.utf16.distance(from: text.utf16.startIndex, to: separatorRange.lowerBound)
        let separatorEnd = text.utf16.distance(from: text.utf16.startIndex, to: separatorRange.upperBound)
        let leftSnapshot = trimmedModernSlice(snapshot, relativeRange: 0..<separatorStart)
        let rightSnapshot = trimmedModernSlice(snapshot, relativeRange: separatorEnd..<snapshot.utf16Count)
        guard leftSnapshot.text == left,
              rightSnapshot.text == right else {
            return [
                ModernSpeechTextSnapshot(text: left, runs: []),
                ModernSpeechTextSnapshot(text: right, runs: [])
            ].filter { $0.text.isEmpty == false }
        }
        return [leftSnapshot, rightSnapshot].filter { $0.text.isEmpty == false }
    }

    private func splitCommittedEmissionUnits(in text: String) -> [String] {
        splitRecognizedSentences(in: text).flatMap(splitDialogueClausesIfNeeded)
    }

    private func splitDialogueClausesIfNeeded(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return []
        }

        guard let separatorRange = singleDialogueClauseSeparatorRange(in: trimmed) else {
            return [trimmed]
        }

        let left = String(trimmed[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(trimmed[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldSplitDialogueClauses(left: left, right: right) else {
            return [trimmed]
        }

        return [left, right]
    }

    private func singleDialogueClauseSeparatorRange(in text: String) -> Range<String.Index>? {
        var separatorRange: Range<String.Index>?

        for index in text.indices where Self.dialogueClauseSeparators.contains(text[index]) {
            if separatorRange != nil {
                return nil
            }

            separatorRange = index..<text.index(after: index)
        }

        return separatorRange
    }

    private func shouldSplitDialogueClauses(left: String, right: String) -> Bool {
        guard activeHeuristicLanguage == .japanese,
              left.isEmpty == false,
              right.isEmpty == false,
              left.containsCJKCharacters || right.containsCJKCharacters else {
            return false
        }

        let maxClauseLength = 18
        guard left.count <= maxClauseLength,
              right.count <= maxClauseLength else {
            return false
        }

        let leftLooksComplete = Self.japaneseDialogueClauseEndingSuffixes.contains(where: { left.hasSuffix($0) })
            || left.containsSentenceTerminator
        let rightLooksLikeNewTurn = Self.japaneseDialogueClauseLeadingPhrases.contains(where: { right.hasPrefix($0) })

        return leftLooksComplete || rightLooksLikeNewTurn
    }

    @MainActor
    private func emitPartialDraft(_ draft: DraftSegment?) {
        partialHandler?(draft)
    }

    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    @MainActor
    private func emitFatalError(_ message: String) {
        fatalErrorHandler?(message)
    }

    @MainActor
    private func prepareCommittedSentenceForEmission(
        _ text: String
    ) -> (text: String, sourceUTF16Range: Range<Int>)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let comparable = comparableCommittedSentenceText(trimmed)
        guard comparable.isEmpty == false else {
            return nil
        }

        if recentCommittedSentenceHistory.contains(where: { $0.comparableText == comparable }) {
            return nil
        }

        if let extendedSentence = trimmedCommittedPrefixContinuation(from: trimmed) {
            let extendedComparable = comparableCommittedSentenceText(extendedSentence)
            guard extendedComparable.isEmpty == false,
                  recentCommittedSentenceHistory.contains(where: { $0.comparableText == extendedComparable }) == false else {
                return nil
            }

            guard trimmed.hasSuffix(extendedSentence) else { return nil }
            let start = trimmed.utf16.count - extendedSentence.utf16.count
            return (extendedSentence, start..<trimmed.utf16.count)
        }

        let bestOverlap = recentCommittedSentenceHistory
            .suffix(3)
            .map { leadingOverlapLength(previous: $0.rawText, current: trimmed) }
            .max() ?? 0

        let candidateText: String
        if shouldTrimLeadingOverlap(length: bestOverlap, in: trimmed) {
            candidateText = dropLeadingCharacters(bestOverlap, from: trimmed)
                .trimmingCharacters(in: Self.leadingOverlapTrimCharacterSet)
        } else {
            candidateText = trimmed
        }

        guard candidateText.isEmpty == false else {
            return nil
        }

        let candidateComparable = comparableCommittedSentenceText(candidateText)
        guard candidateComparable.isEmpty == false,
              recentCommittedSentenceHistory.contains(where: { $0.comparableText == candidateComparable }) == false else {
            return nil
        }

        guard trimmed.hasSuffix(candidateText) else { return nil }
        let start = trimmed.utf16.count - candidateText.utf16.count
        return (candidateText, start..<trimmed.utf16.count)
    }

    @MainActor
    private func rememberCommittedSentence(_ text: String) {
        let comparable = comparableCommittedSentenceText(text)
        guard comparable.isEmpty == false else {
            return
        }

        recentCommittedSentenceHistory.append(
            RecentCommittedSentence(
                rawText: text,
                comparableText: comparable,
                time: Date(),
                allowsPrefixContinuation: SentenceBoundaryHeuristics
                    .endsWithLikelySentenceTerminator(in: text) == false
            )
        )
        pruneRecentCommittedSentenceHistory()
    }

    @MainActor
    private func trimmedCommittedPrefixContinuation(from text: String) -> String? {
        let now = Date()

        for previous in recentCommittedSentenceHistory.suffix(3).reversed() {
            guard previous.allowsPrefixContinuation,
                  now.timeIntervalSince(previous.time) <= Self.committedPrefixContinuationWindow,
                  text.count > previous.rawText.count,
                  text.hasPrefix(previous.rawText) else {
                continue
            }

            let remainder = String(
                dropLeadingCharacters(previous.rawText.count, from: text).drop(while: { character in
                    character.unicodeScalars.allSatisfy(Self.leadingOverlapTrimCharacterSet.contains)
                })
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.isEmpty == false else {
                continue
            }

            return remainder
        }

        return nil
    }

    @MainActor
    private func pruneRecentCommittedSentenceHistory() {
        let now = Date()
        recentCommittedSentenceHistory.removeAll { now.timeIntervalSince($0.time) > 8.0 }
        if recentCommittedSentenceHistory.count > Self.recentCommittedSentenceLimit {
            recentCommittedSentenceHistory.removeFirst(
                recentCommittedSentenceHistory.count - Self.recentCommittedSentenceLimit
            )
        }
    }

    private func comparableCommittedSentenceText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: Self.committedComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func leadingOverlapLength(previous: String, current: String) -> Int {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let maxOverlap = min(previousCharacters.count, currentCharacters.count)

        guard maxOverlap > 0 else {
            return 0
        }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(previousCharacters.suffix(overlap)) == Array(currentCharacters.prefix(overlap)) {
                return overlap
            }
        }

        return 0
    }

    private func shouldTrimLeadingOverlap(length: Int, in text: String) -> Bool {
        guard length > 0, text.isEmpty == false else {
            return false
        }

        let minimumOverlap = text.containsCJKCharacters
            ? Self.minimumCJKLeadingOverlapCharacters
            : Self.minimumLatinLeadingOverlapCharacters
        let overlapRatio = Double(length) / Double(text.count)
        return length >= minimumOverlap && overlapRatio >= 0.35
    }

    private func dropLeadingCharacters(_ count: Int, from text: String) -> String {
        guard count > 0 else {
            return text
        }

        var index = text.startIndex
        var remaining = count
        while remaining > 0, index < text.endIndex {
            index = text.index(after: index)
            remaining -= 1
        }

        return String(text[index...])
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func splitRecognizedSentences(in text: String) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            return []
        }

        let nsText = normalizedText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return [normalizedText]
        }

        return sentenceRanges.compactMap { range in
            let sentence = nsText.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }

    private func sentenceRanges(in text: NSString) -> [NSRange] {
        SentenceBoundaryHeuristics.sentenceRanges(in: text)
    }

    private func pendingModernText(from fullText: String) -> String {
        guard modernCommittedPrefixText.isEmpty == false else {
            return fullText
        }
        if fullText.hasPrefix(modernCommittedPrefixText) {
            return String(fullText.dropFirst(modernCommittedPrefixText.count))
        }

        let committedSentences = splitRecognizedSentences(in: modernCommittedPrefixText)
        let nsFullText = fullText as NSString
        let fullSentenceRanges = sentenceRanges(in: nsFullText)
        let fullSentences = fullSentenceRanges.map {
            nsFullText.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard committedSentences.isEmpty == false,
              fullSentences.isEmpty == false else {
            return fullText
        }

        let committedComparable = committedSentences.map(comparableCommittedSentenceText)
        let fullComparable = fullSentences.map(comparableCommittedSentenceText)
        let maxOverlap = min(committedComparable.count, fullComparable.count)

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(committedComparable.suffix(overlap)) == Array(fullComparable.prefix(overlap)) {
                let matchedRange = fullSentenceRanges[overlap - 1]
                let nextLocation = matchedRange.location + matchedRange.length
                guard nextLocation < nsFullText.length else {
                    return ""
                }

                return nsFullText.substring(from: nextLocation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return fullText
    }

    private func committableModernText(in rawText: String) -> (committedRawText: String, remainingRawText: String)? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return nil
        }

        let nsText = rawText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return nil
        }

        if SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: trimmedText) {
            return (rawText, "")
        }

        guard sentenceRanges.count >= 2,
              let trailingSentenceRange = sentenceRanges.last,
              trailingSentenceRange.location > 0 else {
            return nil
        }

        let committedRawText = nsText.substring(to: trailingSentenceRange.location)
        let remainingRawText = nsText.substring(from: trailingSentenceRange.location)
        guard committedRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        return (committedRawText, remainingRawText)
    }

    private func pendingModernText(from snapshot: ModernSpeechTextSnapshot) -> ModernSpeechTextSnapshot {
        let fullText = snapshot.text
        guard modernCommittedPrefixText.isEmpty == false else { return snapshot }
        if fullText.hasPrefix(modernCommittedPrefixText) {
            let prefixLength = modernCommittedPrefixText.utf16.count
            return trimmedModernSlice(snapshot, relativeRange: prefixLength..<snapshot.utf16Count)
        }

        let committedSentences = splitRecognizedSentences(in: modernCommittedPrefixText)
        let nsFullText = fullText as NSString
        let fullSentenceRanges = sentenceRanges(in: nsFullText)
        let fullSentences = fullSentenceRanges.map {
            nsFullText.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard committedSentences.isEmpty == false,
              fullSentences.isEmpty == false else {
            return snapshot
        }

        let committedComparable = committedSentences.map(comparableCommittedSentenceText)
        let fullComparable = fullSentences.map(comparableCommittedSentenceText)
        let maxOverlap = min(committedComparable.count, fullComparable.count)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(committedComparable.suffix(overlap)) == Array(fullComparable.prefix(overlap)) {
                let matchedRange = fullSentenceRanges[overlap - 1]
                let nextLocation = matchedRange.location + matchedRange.length
                guard nextLocation < nsFullText.length else {
                    return ModernSpeechTextSnapshot(text: "", runs: [])
                }
                return trimmedModernSlice(
                    snapshot,
                    relativeRange: nextLocation..<nsFullText.length
                )
            }
        }

        return snapshot
    }

    private func committableModernText(
        in snapshot: ModernSpeechTextSnapshot
    ) -> (committed: ModernSpeechTextSnapshot, remaining: ModernSpeechTextSnapshot)? {
        guard let split = committableModernText(in: snapshot.text) else { return nil }
        let committedLength = split.committedRawText.utf16.count
        guard committedLength <= snapshot.utf16Count else { return nil }

        let committed = trimmedModernSlice(snapshot, relativeRange: 0..<committedLength)
        let remaining = trimmedModernSlice(snapshot, relativeRange: committedLength..<snapshot.utf16Count)
        guard committed.text == split.committedRawText.trimmingCharacters(in: .whitespacesAndNewlines),
              remaining.text == split.remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (
                ModernSpeechTextSnapshot(text: split.committedRawText, runs: []),
                ModernSpeechTextSnapshot(text: split.remainingRawText, runs: [])
            )
        }
        return (committed, remaining)
    }

    private func trimmedModernSlice(
        _ snapshot: ModernSpeechTextSnapshot,
        relativeRange: Range<Int>
    ) -> ModernSpeechTextSnapshot {
        let rawSlice = modernSlice(snapshot, relativeRange: relativeRange)
        if let trimmed = rawSlice.trimmingWhitespace() {
            return trimmed
        }
        return ModernSpeechTextSnapshot(
            text: rawSlice.text.trimmingCharacters(in: .whitespacesAndNewlines),
            runs: []
        )
    }

    private func modernSlice(
        _ snapshot: ModernSpeechTextSnapshot,
        relativeRange: Range<Int>
    ) -> ModernSpeechTextSnapshot {
        if let slice = snapshot.slice(relativeUTF16Range: relativeRange) {
            return slice
        }

        let text = snapshot.text as NSString
        let range = NSRange(
            location: relativeRange.lowerBound,
            length: max(0, relativeRange.upperBound - relativeRange.lowerBound)
        )
        guard range.location >= 0, NSMaxRange(range) <= text.length else {
            return ModernSpeechTextSnapshot(text: "", runs: [])
        }
        return ModernSpeechTextSnapshot(text: text.substring(with: range), runs: [])
    }

    private func hasLikelyPunctuationBoundary(
        afterSegmentAt index: Int,
        in formattedText: NSString,
        segments: [SFTranscriptionSegment]
    ) -> Bool {
        let currentRange = segments[index].substringRange
        let boundaryEndLocation = index < segments.count - 1
            ? segments[index + 1].substringRange.location
            : formattedText.length

        guard boundaryEndLocation > currentRange.location else {
            return false
        }

        let boundaryText = formattedText.substring(
            with: NSRange(location: currentRange.location, length: boundaryEndLocation - currentRange.location)
        )
        let nextText = index < segments.count - 1 ? segments[index + 1].substring : nil

        return SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(
            in: boundaryText,
            followedBy: nextText
        )
    }

    private func emittedTextRange(
        in formattedText: NSString,
        segments: [SFTranscriptionSegment],
        from startIndex: Int,
        to endIndex: Int
    ) -> NSRange {
        let startLocation = segments[startIndex].substringRange.location
        let endLocation = endIndex < segments.count - 1
            ? segments[endIndex + 1].substringRange.location
            : formattedText.length

        return NSRange(location: startLocation, length: max(0, endLocation - startLocation))
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        lastRecognitionResultTime = Date()
        // The recognizer is delivering again — forget any earlier failures.
        consecutiveRecognitionFailures = 0
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let formattedText = transcription.formattedString as NSString
        var committedEmissions: [CommittedEmission] = []

        // Always save the latest transcript so the silence timer can commit it
        latestSegments = segments
        latestFormattedText = formattedText

        alignCommittedSegmentCount(to: segments)

        guard committedSegmentCount < segments.count else {
            cancelSilenceTimer()
            // The task has no more pending text. If it just finished, restart it.
            if result.isFinal { restartRecognitionTask() }
            return
        }

        var sentenceStartIndex = committedSegmentCount

        for index in committedSegmentCount..<segments.count {
            let segment = segments[index]
            let nextPauseDuration: TimeInterval?

            if index < segments.count - 1 {
                let nextSegment = segments[index + 1]
                nextPauseDuration = nextSegment.timestamp - (segment.timestamp + segment.duration)
            } else {
                nextPauseDuration = nil
            }

            let currentSegmentCount = index - sentenceStartIndex + 1
            let sentenceStartTimestamp = segments[sentenceStartIndex].timestamp
            let sentenceEndTimestamp = segment.timestamp + segment.duration
            let currentSentenceDuration = max(sentenceEndTimestamp - sentenceStartTimestamp, 0)
            // Apple may place restored punctuation in the gap before the next segment
            // rather than inside the current segment substring.
            let punctuationBoundary = hasLikelyPunctuationBoundary(
                afterSegmentAt: index,
                in: formattedText,
                segments: segments
            )
            // 0.85 s was too conservative and often merged two short sentences.
            let strongPauseBoundary = (nextPauseDuration ?? 0) >= max(0.55, Double(modeConfig.minSilenceCommitMs) / 1000.0 + 0.24)
            // Char-length limit removed: 40 chars is only ~6 English words and caused
            // false mid-sentence cuts. Segment count + audio duration are sufficient.
            let forcedBoundary = currentSegmentCount >= 18
                || currentSentenceDuration >= modeConfig.maxChunkAudioSec
            let finalBoundary = result.isFinal && index == segments.count - 1

            guard punctuationBoundary || strongPauseBoundary || forcedBoundary || finalBoundary else {
                continue
            }

            // When a purely forced cut lands close to the end of available segments,
            // absorb the tiny tail rather than leaving a 1–2 word orphan that would
            // be emitted as a meaningless standalone sentence by the silence timer.
            var commitEndIndex = index
            if forcedBoundary && !punctuationBoundary && !strongPauseBoundary && !finalBoundary {
                let tailCount = (segments.count - 1) - index
                if tailCount > 0 && tailCount <= 2 {
                    commitEndIndex = segments.count - 1
                }
            }

            let commitRange = emittedTextRange(
                in: formattedText,
                segments: segments,
                from: sentenceStartIndex,
                to: commitEndIndex
            )

            let sentenceText = formattedText.substring(with: commitRange)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let committedDraftID = currentDraftId

            if sentenceText.isEmpty == false {
                let audioWAVData = finishCorrectionAudio(
                    through: segmentEndTime(for: segments[commitEndIndex])
                )
                let segmentTimings = segments[sentenceStartIndex...commitEndIndex].map {
                    LegacySpeechSegmentTiming(timestamp: $0.timestamp, duration: $0.duration)
                }
                let audioProvenance = legacyRecognitionSampleMapping?.provenance(for: segmentTimings)
                committedEmissions.append(
                    makeCommittedEmission(
                        text: sentenceText,
                        promotionSegmentID: committedDraftID,
                        audioWAVData: audioWAVData,
                        audioProvenance: audioProvenance
                    )
                )
            }

            committedAudioBoundaryTime = segmentEndTime(for: segments[commitEndIndex])
            sentenceStartIndex = commitEndIndex + 1
            committedSegmentCount = sentenceStartIndex
            resetDraftState()

            // If we consumed all remaining segments (tail absorption or final boundary),
            // stop iterating to avoid referencing segments beyond the committed range.
            if commitEndIndex >= segments.count - 1 { break }
        }

        let shouldClearDraftAfterCommit = committedSegmentCount >= segments.count

        // Emit draft update for the uncommitted tail
        if committedSegmentCount < segments.count {
            emitDraftUpdate(
                draftRange: committedSegmentCount..<segments.count,
                allSegments: segments,
                formattedText: formattedText
            )
            // Schedule a silence-based commit: if no new ASR result arrives within
            // silenceCommitDeadlineMs, the user has paused → commit whatever we have.
            scheduleSilenceCommit()
        } else {
            cancelSilenceTimer()
        }

        if committedEmissions.isEmpty == false {
            Task { [committedEmissions, shouldClearDraftAfterCommit] in
                await emitCommittedSequence(
                    committedEmissions,
                    clearDraftAfter: shouldClearDraftAfterCommit
                )
            }
        } else if shouldClearDraftAfterCommit {
            Task { await emitPartialDraft(nil) }
        }

        // SFSpeechRecognizer marks isFinal = true when its internal session ends
        // (after a long pause or utterance limit). Once final, the task delivers no
        // more callbacks — new audio is silently ignored. Restart immediately so
        // recognition continues without interruption.
        if result.isFinal {
            restartRecognitionTask()
        }
    }

    /// Replaces the spent recognition task with a fresh one so recording continues
    /// indefinitely. Called on captureQueue whenever isFinal is received or on error recovery.
    private func restartRecognitionTask() {
        guard let recognizer = speechRecognizer else { return }
        beginCommittedDeliveryStateMutation()
        defer { endCommittedDeliveryStateMutation() }

        // A restart from any source supersedes a retry still waiting on its backoff.
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil

        // Cleanly end the old request before discarding it.
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        vadEngine?.reset()

        // Bump the epoch BEFORE creating the new handler so any late callbacks
        // dispatched by the cancelled task are silently ignored.
        resetRecognitionEpoch()

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        recognitionRequest = request
        recognitionTask = task
        legacyRecognitionSampleMapping = makeLegacyRecognitionSampleMapping()
        // Reset the converter — new request may have a different nativeAudioFormat.
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        resetDraftState()
        Task { await emitPartialDraft(nil) }
    }

    private func resetRecognitionFailureState() {
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil
        consecutiveRecognitionFailures = 0
        lastRecognitionFailureTime = .distantPast
    }

    /// Recovers from a recognition-task error on captureQueue.
    ///
    /// Retries are spaced by `recognitionRestartBackoff` so a recognizer that fails the
    /// instant it starts cannot loop at full speed. Once the retries are exhausted the
    /// error reaches the UI — otherwise capture keeps running behind an overlay that
    /// still claims to be waiting for audio.
    private func handleRecognitionFailure(_ error: Error) {
        let now = Date()
        if now.timeIntervalSince(lastRecognitionFailureTime) > recognitionFailureWindow {
            consecutiveRecognitionFailures = 0
        }
        lastRecognitionFailureTime = now
        consecutiveRecognitionFailures += 1

        guard consecutiveRecognitionFailures <= recognitionRestartBackoff.count else {
            stopRecognitionAndSurface(error)
            return
        }

        let delay = recognitionRestartBackoff[consecutiveRecognitionFailures - 1]
        guard delay > 0 else {
            restartRecognitionTask()
            return
        }

        pendingRecognitionRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRecognitionRestart = nil
            self.restartRecognitionTask()
        }
        pendingRecognitionRestart = restart
        captureQueue.asyncAfter(deadline: .now() + delay, execute: restart)
    }

    /// Ends the session after recognition has failed for good, and reports why.
    ///
    /// Capture is torn down along with the recognizer: audio that nothing transcribes is
    /// only a microphone left open, and the surfaced message tells the user the session
    /// has stopped. `stopOnCaptureQueue` keeps `errorHandler` in place, so the message
    /// still reaches the UI.
    private func stopRecognitionAndSurface(_ error: Error) {
        stopOnCaptureQueue()

        Task {
            await self.emitFatalError(
                self.localized(
                    .speechRecognitionStoppedFormat,
                    self.localizedErrorDescription(error)
                )
            )
        }
    }

    /// Builds the result/error handler used by every recognition task.
    ///
    /// On transient errors (no speech detected, internal failure, etc.) the handler
    /// restarts recognition so the pipeline never goes silent. Repeated failures back
    /// off and are eventually surfaced instead of retried forever — see
    /// `handleRecognitionFailure`. Fatal configuration errors (permission denied,
    /// unsupported locale) propagate to the UI so the user knows why things stopped.
    private func makeRecognitionHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        // Capture the epoch at handler-creation time. Any callback arriving
        // after a restart (which advances recognitionEpoch) will be discarded,
        // preventing stale isFinal results from replaying committed sentences.
        let epoch = recognitionEpoch
        return { [weak self] result, error in
            if let error {
                let nsError = error as NSError
                let disposition = Self.legacyRecognitionErrorDisposition(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: nsError.localizedDescription
                )

                // Codes 216/301 are intentional cancellation from our own restart/stop.
                if disposition == .ignore { return }

                self?.captureQueue.async { [weak self] in
                    guard let self, self.speechRecognizer != nil,
                          self.recognitionEpoch == epoch else { return }

                    switch disposition {
                    case .ignore:
                        break
                    case .restartImmediately:
                        // Code 1110 is a normal "no speech detected" timeout.
                        self.restartRecognitionTask()
                    case .stopAndSurface:
                        // An exhausted Apple server quota. Retrying only produces more
                        // rejected requests, so fail fast and tell the user.
                        self.stopRecognitionAndSurface(error)
                    case .retryWithBackoff:
                        self.handleRecognitionFailure(error)
                    }
                }
                return
            }

            guard let result else { return }
            self?.captureQueue.async { [weak self] in
                guard let self, self.recognitionEpoch == epoch else { return }
                self.processRecognitionResult(result)
            }
        }
    }

    @available(macOS 26.0, *)
    private func processModernRecognitionResult(_ result: SpeechTranscriber.Result, epoch: Int) {
        guard acceptsModernResult(for: epoch) else { return }
        let now = Date()
        lastRecognitionResultTime = now
        let resultSnapshot = ModernSpeechTextSnapshot(
            attributedText: result.text,
            mapping: modernRecognitionSampleMapping
        )
        let pendingSnapshot = pendingModernText(from: resultSnapshot)
        let pendingRawText = pendingSnapshot.text
        let text = pendingRawText

        if result.isFinal {
            let identity = modernResultIdentity(for: result)
            guard identity != lastModernCommittedResultIdentity else { return }
            lastModernCommittedResultIdentity = identity

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            resetModernTranscriptionState()
            let committedDraftID = currentDraftId
            resetDraftState()

            if text.isEmpty == false {
                let audioWAVData = finishCorrectionAudio()
                let committedEmission = makeCommittedEmission(
                    text: text,
                    promotionSegmentID: committedDraftID,
                    audioWAVData: audioWAVData,
                    modernRecognitionEpoch: epoch,
                    modernTimedText: pendingSnapshot
                )
                Task { [committedEmission] in
                    await emitCommittedSequence(
                        [committedEmission],
                        clearDraftAfter: true
                    )
                }
            } else {
                scheduleModernPartialDraft(nil, recognitionEpoch: epoch)
            }
            return
        }

        guard text.isEmpty == false else {
            latestModernText = ""
            latestModernTimedText = nil
            cancelSilenceTimer()
            cancelVADSilenceTimer()
            scheduleModernPartialDraft(nil, recognitionEpoch: epoch)
            return
        }

        observeDraftText(text, at: now)
        latestModernText = pendingRawText
        latestModernTimedText = pendingSnapshot
        if let split = committableModernText(in: pendingSnapshot),
           split.remaining.text.isEmpty,
           SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text),
           canFastCommitModernBoundary(at: now) {
            let committedText = split.committed.text
            guard committedText.isEmpty == false else {
                latestModernText = ""
                latestModernTimedText = nil
                scheduleModernPartialDraft(nil, recognitionEpoch: epoch)
                return
            }

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            modernCommittedPrefixText += split.committed.text
            latestModernText = split.remaining.text
            latestModernTimedText = split.remaining
            let committedDraftID = currentDraftId
            resetDraftState()
            let audioWAVData = finishCorrectionAudio()
            let committedEmission = makeCommittedEmission(
                text: committedText,
                promotionSegmentID: committedDraftID,
                audioWAVData: audioWAVData,
                modernRecognitionEpoch: epoch,
                modernTimedText: split.committed
            )
            Task { [committedEmission] in
                await emitCommittedSequence(
                    [committedEmission],
                    clearDraftAfter: true
                )
            }
            return
        }

        emitDraftUpdate(from: result, text: text, recognitionEpoch: epoch)
        scheduleSilenceCommit()
    }

    private func observeDraftText(_ text: String, at now: Date) {
        if text != lastDraftText {
            lastDraftText = text
            lastDraftTextChangeTime = now
            draftChangeHistory.append((text: text, time: now))
        }
        draftChangeHistory.removeAll { now.timeIntervalSince($0.time) > 0.4 }
    }

    private func currentDraftStability(at now: Date) -> (silenceMs: Int, stabilityScore: Float) {
        let silenceMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let recentChanges = draftChangeHistory.count
        let stabilityScore: Float
        switch recentChanges {
        case 0, 1: stabilityScore = 1.0
        case 2:    stabilityScore = 0.7
        default:   stabilityScore = max(0.1, 0.5 - Float(recentChanges - 2) * 0.15)
        }

        return (silenceMs, stabilityScore)
    }

    private func canFastCommitModernBoundary(at now: Date) -> Bool {
        Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000) >= modernBoundaryCommitStabilityDelayMs
    }

    private func canVADCommitModernDraft(_ rawText: String, at now: Date) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return false
        }

        guard shouldHoldModernVADCommit(for: text) == false else {
            return false
        }

        let stableForMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let minimumStableMs = max(vadSilenceCommitDeadlineMs, 260)
        guard stableForMs >= minimumStableMs else {
            return false
        }

        let maxDraftLength = text.containsCJKCharacters ? 14 : 28
        return text.count <= maxDraftLength
    }

    private func shouldHoldModernVADCommit(for text: String) -> Bool {
        guard SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) == false else {
            return false
        }

        if SentenceBoundaryHeuristics.endsWithLikelyNonTerminalAbbreviation(in: text) {
            return true
        }

        switch activeHeuristicLanguage {
        case .japanese:
            return Self.modernVADDeferredJapaneseCommitSuffixes.contains(where: { text.hasSuffix($0) })
        case .english:
            let normalized = text.lowercased()
            return Self.modernVADDeferredEnglishCommitSuffixes.contains(where: { normalized.hasSuffix($0) })
        case .other:
            return false
        }
    }

    private var activeHeuristicLanguage: RecognitionHeuristicLanguage {
        switch activeLanguageCode {
        case "ja":
            return .japanese
        case "en":
            return .english
        default:
            return .other
        }
    }

    private var activeLanguageCode: String? {
        guard let activeLocaleIdentifier else {
            return nil
        }

        let separators = CharacterSet(charactersIn: "-_")
        return activeLocaleIdentifier
            .components(separatedBy: separators)
            .first?
            .lowercased()
    }

    @available(macOS 26.0, *)
    private func emitDraftUpdate(
        from result: SpeechTranscriber.Result,
        text: String,
        recognitionEpoch: Int
    ) {
        let now = Date()
        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45
        let lengthFitScore = draftLengthFitScore(for: text)
        let averageConfidence = transcriberAverageConfidence(result.text)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: averageConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))
        let timeRange = transcriberTimeRange(result.text)
        let startMs = timeRange.map { cmTimeMilliseconds($0.start) } ?? 0

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: averageConfidence,
            startMs: startMs,
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: []
        )

        scheduleModernPartialDraft(draft, recognitionEpoch: recognitionEpoch)
    }

    @available(macOS 26.0, *)
    private func normalizedTranscriberText(_ text: AttributedString) -> String {
        String(text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.0, *)
    private func transcriberAverageConfidence(_ text: AttributedString) -> Float {
        var total: Double = 0
        var count = 0

        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }

        guard count > 0 else { return 0.82 }
        return Float(total / Double(count))
    }

    @available(macOS 26.0, *)
    private func transcriberTimeRange(_ text: AttributedString) -> CMTimeRange? {
        for run in text.runs {
            if let timeRange = run.audioTimeRange {
                return timeRange
            }
        }

        return nil
    }

    @available(macOS 26.0, *)
    private func modernResultIdentity(for result: SpeechTranscriber.Result) -> String {
        let startMs = cmTimeMilliseconds(result.range.start)
        let durationMs = cmTimeMilliseconds(result.range.duration)
        return "\(startMs):\(durationMs):\(normalizedTranscriberText(result.text))"
    }

    private func draftLengthFitScore(for text: String) -> Float {
        let charCount = text.count
        let isCJK = text.containsCJKCharacters

        if isCJK {
            switch charCount {
            case 12...20: return 1.0
            case 5..<12:  return Float(charCount) / 12.0 * 0.6
            case 21...30: return 0.7
            default:      return 0.3
            }
        }

        switch charCount {
        case 28...56: return 1.0
        case 10..<28: return Float(charCount) / 28.0 * 0.6
        case 57...84: return 0.7
        default:      return 0.3
        }
    }

    private func cmTimeMilliseconds(_ time: CMTime) -> Int {
        guard time.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(time) * 1000.0).rounded())
    }

    // MARK: - Silence-commit timer

    /// Time after the last ASR callback before we force-commit pending text.
    ///
    /// 420 ms was too short: SFSpeechRecognizer can take 400–600 ms between consecutive
    /// partial-result callbacks for the same utterance on a loaded device, causing the
    /// timer to fire between two ASR deliveries for the same sentence.
    ///
    /// ~600–690 ms sits safely above:
    ///   • inter-result ASR delivery gaps (typically 100–500 ms during speech)
    ///   • natural within-sentence pauses in Mandarin/Japanese (200–450 ms)
    /// and below clear sentence-ending silences (≥ 600 ms for most speakers).
    ///
    /// Follow ≈ 600 ms · Balanced ≈ 630 ms · Reading ≈ 690 ms.
    private var silenceCommitDeadlineMs: Int {
        max(600, modeConfig.minSilenceCommitMs + 350)
    }

    /// Require a short stable window before promoting a punctuation-ended partial.
    /// This keeps the fast path responsive without freezing a still-revisable boundary.
    private var modernBoundaryCommitStabilityDelayMs: Int {
        max(160, min(modeConfig.minSilenceCommitMs, 240))
    }

    private var vadSilenceCommitDeadlineMs: Int {
        max(280, modeConfig.minSilenceCommitMs)
    }

    private func scheduleSilenceCommit() {
        scheduleSilenceCommit(trigger: .asrInactivity, afterMs: silenceCommitDeadlineMs)
    }

    private func cancelSilenceTimer() {
        silenceCommitTimer?.cancel()
        silenceCommitTimer = nil
    }

    // MARK: - VAD-based silence commit

    /// Schedules a fast commit based on Silero VAD detecting speech offset.
    /// Uses the mode's minSilenceCommitMs (100–200 ms) — much faster than the
    /// ASR-inactivity timer (700+ ms).
    private func scheduleVADSilenceCommit() {
        scheduleSilenceCommit(trigger: .vadOffset, afterMs: vadSilenceCommitDeadlineMs)
    }

    private func cancelVADSilenceTimer() {
        vadSilenceCommitTimer?.cancel()
        vadSilenceCommitTimer = nil
    }

    private func scheduleSilenceCommit(trigger: SilenceCommitTrigger, afterMs: Int) {
        cancelSilenceCommitTimer(for: trigger)
        let timerEpoch = recognitionEpoch
        let timerBackend = recognitionBackend
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(afterMs))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.acceptsSilenceCommitTimer(for: timerEpoch, backend: timerBackend) else {
                return
            }
            self.forceCommitOnSilence(trigger: trigger)
        }
        timer.resume()

        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = timer
        case .vadOffset:
            vadSilenceCommitTimer = timer
        }
    }

    private func acceptsSilenceCommitTimer(
        for epoch: Int,
        backend: RecognitionBackend
    ) -> Bool {
        recognitionEpoch == epoch && recognitionBackend == backend
    }

    private func cancelSilenceCommitTimer(for trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            cancelSilenceTimer()
        case .vadOffset:
            cancelVADSilenceTimer()
        }
    }

    /// Called by the silence timer when no new ASR result has arrived for
    /// silenceCommitDeadlineMs — meaning the user has paused.
    private func forceCommitOnSilence(trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = nil
        case .vadOffset:
            vadSilenceCommitTimer = nil
        }

        if recognitionBackend == .speechAnalyzer {
            let latestSnapshot = latestModernTimedText
                ?? ModernSpeechTextSnapshot(text: latestModernText, runs: [])
            let committedSnapshot: ModernSpeechTextSnapshot
            let remainingSnapshot: ModernSpeechTextSnapshot

            switch trigger {
            case .asrInactivity:
                guard let split = committableModernText(in: latestSnapshot) else {
                    return
                }
                committedSnapshot = split.committed
                remainingSnapshot = split.remaining
            case .vadOffset:
                let now = Date()
                guard canVADCommitModernDraft(latestModernText, at: now) else {
                    return
                }
                committedSnapshot = latestSnapshot
                remainingSnapshot = ModernSpeechTextSnapshot(text: "", runs: [])
            }

            let text = committedSnapshot.text
            guard text.isEmpty == false else {
                latestModernText = remainingSnapshot.text
                latestModernTimedText = remainingSnapshot
                return
            }

            modernCommittedPrefixText += committedSnapshot.text
            latestModernText = remainingSnapshot.text
            latestModernTimedText = remainingSnapshot
            let committedDraftID = currentDraftId
            resetDraftState()
            let audioWAVData = finishCorrectionAudio()
            let committedEmission = makeCommittedEmission(
                text: text,
                promotionSegmentID: committedDraftID,
                audioWAVData: audioWAVData,
                modernRecognitionEpoch: recognitionEpoch,
                modernTimedText: committedSnapshot
            )
            Task { [committedEmission] in
                await emitCommittedSequence(
                    [committedEmission],
                    clearDraftAfter: remainingSnapshot.text.isEmpty
                )
            }
            return
        }

        let segments = latestSegments
        let formattedText = latestFormattedText

        guard committedSegmentCount < segments.count else { return }

        let pendingStartIndex = committedSegmentCount
        let pendingSegments = Array(segments[pendingStartIndex...])
        if let delayMs = requiredCommitDelayMs(trigger: trigger, pendingSegments: pendingSegments) {
            scheduleSilenceCommit(trigger: trigger, afterMs: delayMs)
            return
        }

        let lastIdx = segments.count - 1
        let currentRange = combinedRange(for: segments, from: committedSegmentCount, to: lastIdx)
        let sentenceText = (formattedText.substring(with: currentRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let committedDraftID = currentDraftId

        committedAudioBoundaryTime = segmentEndTime(for: segments[lastIdx])
        committedSegmentCount = segments.count
        resetDraftState()
        if sentenceText.isEmpty == false {
            let audioWAVData = finishCorrectionAudio(
                through: segmentEndTime(for: segments[lastIdx])
            )
            let segmentTimings = pendingSegments.map {
                LegacySpeechSegmentTiming(timestamp: $0.timestamp, duration: $0.duration)
            }
            let audioProvenance = legacyRecognitionSampleMapping?.provenance(for: segmentTimings)
            let committedEmission = makeCommittedEmission(
                text: sentenceText,
                promotionSegmentID: committedDraftID,
                audioWAVData: audioWAVData,
                audioProvenance: audioProvenance
            )
            Task { [committedEmission] in
                await emitCommittedSequence(
                    [committedEmission],
                    clearDraftAfter: true
                )
            }
        } else {
            Task { await emitPartialDraft(nil) }
        }
    }

    private func requiredCommitDelayMs(
        trigger: SilenceCommitTrigger,
        pendingSegments: [SFTranscriptionSegment]
    ) -> Int? {
        guard pendingSegments.isEmpty == false else {
            return nil
        }

        let now = Date()
        let lastUpdateTime = max(lastRecognitionResultTime, lastDraftTextChangeTime)
        let elapsedMs = Int(now.timeIntervalSince(lastUpdateTime) * 1000)
        let averageConfidence = pendingSegments.map(\.confidence).reduce(0, +) / Float(pendingSegments.count)

        var settleWindowMs = trigger == .vadOffset ? 320 : 220
        if pendingSegments.count <= 2 {
            settleWindowMs += 80
        }
        if averageConfidence < 0.78 {
            settleWindowMs += 120
        }

        guard elapsedMs < settleWindowMs else {
            return nil
        }

        return settleWindowMs - max(elapsedMs, 0)
    }

    private func alignCommittedSegmentCount(to segments: [SFTranscriptionSegment]) {
        if segments.count < committedSegmentCount {
            legacyRecognitionSampleMapping?.invalidate()
            resetLegacyTranscriptionState()
            resetCorrectionAudioBuffer()
            resetDraftState()
            return
        }

        guard let committedAudioBoundaryTime else {
            return
        }

        let alignedCount = segments.prefix {
            segmentEndTime(for: $0) <= committedAudioBoundaryTime + committedBoundaryToleranceSec
        }.count

        guard alignedCount != committedSegmentCount else {
            return
        }

        committedSegmentCount = alignedCount
        self.committedAudioBoundaryTime = nil
        resetCorrectionAudioBuffer()
        resetDraftState()
    }

    private func segmentEndTime(for segment: SFTranscriptionSegment) -> TimeInterval {
        segment.timestamp + segment.duration
    }

    // MARK: - Draft helpers (called on captureQueue)

    private func resetDraftState() {
        currentDraftId = UUID()
        lastDraftText = ""
        lastDraftTextChangeTime = Date.distantPast
        lastRecognitionResultTime = Date.distantPast
        draftChangeHistory = []
        draftPrefixCandidate = ""
        draftPrefixCandidateTime = Date.distantPast
        confirmedStablePrefixLength = 0
    }

    private func emitDraftUpdate(
        draftRange: Range<Int>,
        allSegments: [SFTranscriptionSegment],
        formattedText: NSString
    ) {
        let now = Date()
        let lastIdx = draftRange.upperBound - 1
        let draftNSRange = combinedRange(for: allSegments, from: draftRange.lowerBound, to: lastIdx)
        let text = (formattedText.substring(with: draftNSRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            Task { await emitPartialDraft(nil) }
            return
        }

        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        // Boundary score: sentence-terminating punctuation scores highest
        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45

        // Length fit score
        let lengthFitScore = draftLengthFitScore(for: text)

        let draftSegs = Array(allSegments[draftRange])
        let avgConfidence = draftSegs.map(\.confidence).reduce(0, +) / Float(draftSegs.count)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: avgConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))

        let words = draftSegs.map { seg in
            WordToken(
                text: seg.substring,
                startMs: Int(seg.timestamp * 1000),
                endMs: Int((seg.timestamp + seg.duration) * 1000),
                confidence: seg.confidence,
                stable: seg.confidence >= 0.80
            )
        }

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: avgConfidence,
            startMs: Int(draftSegs[0].timestamp * 1000),
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: words
        )

        Task { await emitPartialDraft(draft) }
    }

    /// Returns the character count of the stable (frozen) prefix.
    /// A prefix is stable once it has been unchanged for >= 400 ms.
    private func computeStablePrefixLength(text: String, now: Date) -> Int {
        let mutableLen = mutableTailCharCount(for: text)
        let candidateLen = max(0, text.count - mutableLen)
        let candidate = String(text.prefix(candidateLen))

        if candidate == draftPrefixCandidate {
            if now.timeIntervalSince(draftPrefixCandidateTime) >= 0.4 {
                confirmedStablePrefixLength = candidateLen
            }
        } else if text.hasPrefix(draftPrefixCandidate) {
            // Text grew but prefix region unchanged — slide candidate forward
            draftPrefixCandidate = candidate
        } else {
            // Prefix regressed — reset
            draftPrefixCandidate = candidate
            draftPrefixCandidateTime = now
            confirmedStablePrefixLength = 0
        }

        return confirmedStablePrefixLength
    }

    /// Characters in the mutable tail: last 12 for CJK, last 35 for Latin (≈ 6 words).
    private func mutableTailCharCount(for text: String) -> Int {
        text.containsCJKCharacters ? min(12, text.count) : min(35, text.count)
    }

    private func combinedRange(for segments: [SFTranscriptionSegment], from startIndex: Int, to endIndex: Int) -> NSRange {
        let firstRange = segments[startIndex].substringRange
        let lastRange = segments[endIndex].substringRange
        let endLocation = lastRange.location + lastRange.length
        return NSRange(location: firstRange.location, length: endLocation - firstRange.location)
    }

    private func mapApplicationCaptureError(_ error: ApplicationAudioCapture.CaptureError) -> SessionError {
        switch error {
        case .permissionDenied:
            return .audioCapturePermissionDenied
        case .missingOutputDevice:
            return .failedToStartCapture(localized(.noOutputAudioDeviceForAppCapture))
        case .tapFormatUnavailable:
            return .failedToStartCapture(localized(.selectedAppAudioFormatCouldNotBePrepared))
        case .failed(let stage, let status):
            return .failedToStartCapture(
                localized(.failedToStageWithReasonFormat, stage, status.readableDescription)
            )
        }
    }
}

extension LiveTranscriptionSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        append(sampleBuffer: sampleBuffer)
    }
}

private final class ApplicationAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case missingOutputDevice
        case tapFormatUnavailable
        case failed(stage: String, status: OSStatus)
    }

    private let appName: String
    private let processObjectIDs: [AudioObjectID]
    private let readStreamFailureMessage: String
    private let queue: DispatchQueue
    private let audioHandler: (AVAudioPCMBuffer) -> Void
    private let errorHandler: (String) -> Void

    private let system = AudioHardwareSystem.shared
    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    init(
        appName: String,
        processObjectIDs: [AudioObjectID],
        readStreamFailureMessage: String,
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.readStreamFailureMessage = readStreamFailureMessage
        self.queue = queue
        self.audioHandler = audioHandler
        self.errorHandler = errorHandler
    }

    func start() throws {
        do {
            let tapDescription = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            tapDescription.name = "v2s \(appName)"

            guard let processTap = try system.makeProcessTap(description: tapDescription) else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTap = processTap

            guard let outputDevice = try system.defaultOutputDevice else {
                throw CaptureError.missingOutputDevice
            }

            let outputUID = try outputDevice.uid
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "v2s-\(appName)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: try processTap.uid
                    ]
                ]
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDevice = aggregateDevice

            var streamDescription = try processTap.format
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat

            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDevice.id,
                queue
            ) { [weak self] _, inputData, _, _, _ in
                guard let self else {
                    return
                }

                self.handleCapturedAudio(inputData)
            }

            guard createIOProcStatus == noErr, let deviceIOProcID else {
                throw CaptureError.failed(stage: "create the capture callback", status: createIOProcStatus)
            }

            self.deviceIOProcID = deviceIOProcID

            let startStatus = AudioDeviceStart(aggregateDevice.id, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }
        } catch let error as AudioHardwareError {
            stop()

            if error.error == permErr {
                throw CaptureError.permissionDenied
            }

            throw CaptureError.failed(stage: "configure app audio capture", status: error.error)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let aggregateDevice, let deviceIOProcID {
            AudioDeviceStop(aggregateDevice.id, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, deviceIOProcID)
        }

        deviceIOProcID = nil

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        aggregateDevice = nil

        if let processTap {
            try? system.destroyProcessTap(processTap)
        }

        processTap = nil
        tapFormat = nil
    }

    private func handleCapturedAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              inputData.pointee.mNumberBuffers > 0,
              inputData.pointee.mBuffers.mDataByteSize > 0 else {
            return
        }

        let mutableAudioBufferList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: mutableAudioBufferList,
            deallocator: nil
        ) else {
            errorHandler(readStreamFailureMessage)
            return
        }

        audioHandler(buffer)
    }
}

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }
}

private extension AVAudioFormat {
    func matches(_ other: AVAudioFormat) -> Bool {
        AudioFormatSignature(self) == AudioFormatSignature(other)
    }
}

private extension InputSource {
    var processIdentifierHint: pid_t? {
        guard detail.hasPrefix("pid-") else {
            return nil
        }

        return pid_t(detail.dropFirst(4))
    }
}

private struct ApplicationProcessAssociation {
    let bundleIdentifier: String?
    let applicationBundleURL: URL?
    let helperBundlePrefixes: [String]
    let helperPathFragments: [String]

    init(runningApplication: NSRunningApplication) {
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.applicationBundleURL = runningApplication.bundleURL?.standardizedFileURL

        var helperBundlePrefixes: [String] = []
        var helperPathFragments: [String] = []

        if let bundleIdentifier = runningApplication.bundleIdentifier {
            helperBundlePrefixes.append(bundleIdentifier)

            switch bundleIdentifier {
            case "com.apple.Safari":
                helperBundlePrefixes.append(contentsOf: [
                    "com.apple.WebKit.",
                    "com.apple.Safari"
                ])
                helperPathFragments.append(contentsOf: [
                    "/WebKit.framework/",
                    "/SafariPlatformSupport.framework/",
                    "/Safari.app/"
                ])
            case "com.google.Chrome":
                helperPathFragments.append(contentsOf: [
                    "/Google Chrome.app/",
                    "Google Chrome Helper"
                ])
            case "org.chromium.Chromium":
                helperPathFragments.append(contentsOf: [
                    "/Chromium.app/",
                    "Chromium Helper"
                ])
            case "com.microsoft.edgemac":
                helperPathFragments.append(contentsOf: [
                    "/Microsoft Edge.app/",
                    "Microsoft Edge Helper"
                ])
            case "com.brave.Browser":
                helperPathFragments.append(contentsOf: [
                    "/Brave Browser.app/",
                    "Brave Browser Helper"
                ])
            case "org.mozilla.firefox":
                helperPathFragments.append(contentsOf: [
                    "/Firefox.app/",
                    "plugin-container"
                ])
            default:
                break
            }
        }

        self.helperBundlePrefixes = Array(Set(helperBundlePrefixes))
        self.helperPathFragments = Array(Set(helperPathFragments))
    }

    func matchesExactBundleIdentifier(_ candidate: String) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return candidate == bundleIdentifier
    }

    func matchesApplicationBundleURL(_ candidate: URL?) -> Bool {
        guard let applicationBundleURL else {
            return false
        }

        return candidate == applicationBundleURL
    }

    func matchesHelperBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.isEmpty == false else {
            return false
        }

        return helperBundlePrefixes.contains(where: { candidate.hasPrefix($0) })
    }

    func matchesHelperExecutablePath(_ candidate: String?) -> Bool {
        guard let candidate, candidate.isEmpty == false else {
            return false
        }

        return helperPathFragments.contains(where: { candidate.contains($0) })
    }
}

private extension String {
    var containsSentenceTerminator: Bool {
        contains(where: { ".!?。！？;；".contains($0) })
    }

    var containsCJKCharacters: Bool {
        unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)   // CJK Unified Ideographs
                || (0x3040...0x30FF).contains($0.value) // Hiragana + Katakana
                || (0xAC00...0xD7AF).contains($0.value) // Korean Hangul
        }
    }
}

private extension LiveTranscriptionSession {
    enum RecognitionHeuristicLanguage {
        case japanese
        case english
        case other
    }

    static let minimumLatinLeadingOverlapCharacters = 10
    static let minimumCJKLeadingOverlapCharacters = 4
    static let recentCommittedSentenceLimit = 6
    static let committedPrefixContinuationWindow: TimeInterval = 3.0
    static let dialogueClauseSeparators: Set<Character> = ["、", ",", "，"]
    static let japaneseDialogueClauseEndingSuffixes = [
        "ね", "よ", "の", "な", "さ", "わ", "ぞ", "ぜ", "かな", "かも", "だよ", "だね"
    ]
    static let japaneseDialogueClauseLeadingPhrases = [
        "俺", "私", "僕", "うん", "いや", "や", "でも", "じゃ", "ただいま", "おかえり", "ありがとう", "ごめん"
    ]
    static let modernVADDeferredJapaneseCommitSuffixes = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し"
    ]
    static let modernVADDeferredEnglishCommitSuffixes = [
        " and", " or", " but", " so", " because", " if", " when", " that", " to"
    ]
    static let committedComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    static let leadingOverlapTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
}

private extension OSStatus {
    var readableDescription: String {
        let nsError = NSError(domain: NSOSStatusErrorDomain, code: Int(self))

        if nsError.localizedDescription != "The operation couldn’t be completed. (OSStatus error \(self).)" {
            return nsError.localizedDescription
        }

        if let fourCharacterCode = fourCharacterCode {
            return "\(self) (\(fourCharacterCode))"
        }

        return "\(self)"
    }

    private var fourCharacterCode: String? {
        let bigEndianValue = UInt32(bitPattern: self).bigEndian
        let scalarValues = [
            UInt8((bigEndianValue >> 24) & 0xFF),
            UInt8((bigEndianValue >> 16) & 0xFF),
            UInt8((bigEndianValue >> 8) & 0xFF),
            UInt8(bigEndianValue & 0xFF)
        ]

        guard scalarValues.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return nil
        }

        return String(bytes: scalarValues, encoding: .ascii)
    }
}

private func executablePath(forProcessID processID: pid_t) -> String? {
    let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer {
        pathBuffer.deallocate()
    }

    let pathLength = proc_pidpath(processID, pathBuffer, UInt32(MAXPATHLEN))
    guard pathLength > 0 else {
        return nil
    }

    return String(cString: pathBuffer)
}

private func applicationBundleURL(forProcessID processID: pid_t) -> URL? {
    guard let executablePath = executablePath(forProcessID: processID) else {
        return nil
    }

    return URL(fileURLWithPath: executablePath).owningApplicationBundleURL()
}

private extension URL {
    func owningApplicationBundleURL(maxDepth: Int = 16) -> URL? {
        var depth = 0
        var currentURL = standardizedFileURL

        while depth < maxDepth {
            if currentURL.pathExtension == "app" {
                return currentURL.standardizedFileURL
            }

            currentURL = currentURL.deletingLastPathComponent()
            depth += 1
        }

        return nil
    }
}
