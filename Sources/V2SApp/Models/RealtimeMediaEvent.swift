import Foundation

struct RealtimeSourceAliases: Sendable {
    private let aliasesBySourceID: [String: String]
    let publicMappings: [String]

    init(sourceIDs: [String]) {
        var aliasesBySourceID: [String: String] = [:]
        var publicMappings: [String] = []
        for sourceID in sourceIDs where aliasesBySourceID[sourceID] == nil {
            let alias = "audio-\(publicMappings.count + 1)"
            aliasesBySourceID[sourceID] = alias
            publicMappings.append(alias)
        }
        self.aliasesBySourceID = aliasesBySourceID
        self.publicMappings = publicMappings
    }

    func alias(for sourceID: String) -> String? {
        aliasesBySourceID[sourceID]
    }
}

struct RealtimeAudioChunk: Equatable, Sendable {
    let sourceAlias: String
    let generation: Int
    /// Capture arrival is provenance only. It must never be used to infer an ASR
    /// sentence boundary because it is not a sample-clock interval.
    let capturedAtMonotonicNanoseconds: UInt64
    /// Exact normalized-16-kHz logical sample span, when the capture fanout can
    /// prove one. The interval is half-open: [start, end).
    let startMonotonicNanoseconds: UInt64
    let endMonotonicNanoseconds: UInt64
    let hasPreciseSampleSpan: Bool
    let hasIncompleteSampleSpan: Bool
    let pcm16LEData: Data
    let sampleRate: Int

    init(
        sourceAlias: String,
        generation: Int,
        capturedAtMonotonicNanoseconds: UInt64,
        startMonotonicNanoseconds: UInt64? = nil,
        endMonotonicNanoseconds: UInt64? = nil,
        pcm16LEData: Data,
        sampleRate: Int
    ) {
        self.sourceAlias = sourceAlias
        self.generation = generation
        self.capturedAtMonotonicNanoseconds = capturedAtMonotonicNanoseconds
        self.startMonotonicNanoseconds = startMonotonicNanoseconds ?? capturedAtMonotonicNanoseconds
        self.endMonotonicNanoseconds = endMonotonicNanoseconds ?? capturedAtMonotonicNanoseconds
        self.hasPreciseSampleSpan = startMonotonicNanoseconds != nil && endMonotonicNanoseconds != nil
        self.hasIncompleteSampleSpan = (startMonotonicNanoseconds == nil) != (endMonotonicNanoseconds == nil)
        self.pcm16LEData = pcm16LEData
        self.sampleRate = sampleRate
    }
}

enum RealtimeAudioSourceRole: Equatable, Sendable {
    case microphone
    case applicationAudio

    var providerLabel: String {
        switch self {
        case .microphone: "microphone"
        case .applicationAudio: "application audio"
        }
    }
}

struct RealtimeVideoFrame: Equatable, Sendable {
    let sourceAlias: String
    let capturedAtMonotonicNanoseconds: UInt64
    let jpegData: Data
}

struct RealtimeUtterance: Equatable, Sendable {
    let sourceAlias: String
    let generation: Int
    let captionID: UUID
    let utteranceID: String
    let startMonotonicNanoseconds: UInt64
    let endMonotonicNanoseconds: UInt64
    let requiresPreciseSampleCoverage: Bool

    init(
        sourceAlias: String,
        generation: Int,
        captionID: UUID,
        utteranceID: String,
        startMonotonicNanoseconds: UInt64,
        endMonotonicNanoseconds: UInt64,
        requiresPreciseSampleCoverage: Bool = false
    ) {
        self.sourceAlias = sourceAlias
        self.generation = generation
        self.captionID = captionID
        self.utteranceID = utteranceID
        self.startMonotonicNanoseconds = startMonotonicNanoseconds
        self.endMonotonicNanoseconds = endMonotonicNanoseconds
        self.requiresPreciseSampleCoverage = requiresPreciseSampleCoverage
    }
}

enum RealtimeFailureCode: String, Error, Equatable, Sendable {
    case invalidConfiguration
    case permissionDenied
    case connectionFailed
    case rateLimited
    case capabilityRejected
    case sessionExpired
    case backpressure
    case malformedResponse
}

enum RealtimeProviderEvent: Equatable, Sendable {
    case correctedText(
        sourceAlias: String,
        generation: Int,
        captionID: UUID,
        utteranceID: String,
        text: String
    )
    case suggestion(sourceAlias: String, generation: Int, text: String)
    case expired(sourceAlias: String, generation: Int)
    case failure(sourceAlias: String, generation: Int, RealtimeFailureCode)
}

protocol RealtimeSessionDriving: Sendable {
    func start(sourceAlias: String, generation: Int) async throws
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws
    func commit(_ utterance: RealtimeUtterance) async throws
    func sendVideoFrame(_ frame: RealtimeVideoFrame) async throws
    func revokeVideoPermission() async
    func events() async -> AsyncStream<RealtimeProviderEvent>
    func stop() async
}
