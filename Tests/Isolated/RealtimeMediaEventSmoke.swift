import Foundation

@main struct RealtimeMediaEventSmoke {
    static func main() {
        let aliases = RealtimeSourceAliases(sourceIDs: ["stable-device-id", "bundle.example", "stable-device-id"])
        precondition(aliases.publicMappings == ["audio-1", "audio-2"])
        precondition(aliases.alias(for: "stable-device-id") == "audio-1")
        precondition(aliases.alias(for: "unselected") == nil)

        let frame = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 12,
            jpegData: Data([1, 2])
        )
        precondition(frame.jpegData.count == 2)

        let captionID = UUID()
        let chunk = RealtimeAudioChunk(
            sourceAlias: "audio-2",
            generation: 3,
            capturedAtMonotonicNanoseconds: 100,
            pcm16LEData: Data([1, 0]),
            sampleRate: 16_000
        )
        let utterance = RealtimeUtterance(
            sourceAlias: "audio-2",
            generation: 3,
            captionID: captionID,
            utteranceID: "utterance-1",
            startMonotonicNanoseconds: 100,
            endMonotonicNanoseconds: 200
        )
        precondition(chunk.sourceAlias == utterance.sourceAlias)
        precondition(chunk.generation == utterance.generation)
        precondition(utterance.captionID == captionID)
    }
}
