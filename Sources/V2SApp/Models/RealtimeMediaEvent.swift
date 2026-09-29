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
    let capturedAtMonotonicNanoseconds: UInt64
    let pcm16LEData: Data
    let sampleRate: Int
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
}

enum RealtimeFailureCode: String, Equatable, Sendable {
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
    case correctedText(utteranceID: String, text: String)
    case suggestion(text: String)
    case expired
    case failure(RealtimeFailureCode)
}

protocol RealtimeSessionDriving: Sendable {
    func start(sourceAlias: String, generation: Int) async throws
    func sendAudioChunk(_ chunk: RealtimeAudioChunk) async throws
    func commit(_ utterance: RealtimeUtterance) async throws
    func sendVideoFrame(_ frame: RealtimeVideoFrame) async throws
    func events() async -> AsyncStream<RealtimeProviderEvent>
    func stop() async
}
