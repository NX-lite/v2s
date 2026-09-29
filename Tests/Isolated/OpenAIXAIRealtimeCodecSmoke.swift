import Foundation

@main struct OpenAIXAIRealtimeCodecSmoke {
    static func main() throws {
        let setup = try OpenAIXAIRealtimeCodec.sessionUpdate(
            profile: .openAIMini, sourceAlias: "audio-1"
        )
        guard case .text(let text) = setup else { preconditionFailure("expected JSON") }
        precondition(text.contains("output_modalities"))
        let chunk = RealtimeAudioChunk(
            sourceAlias: "audio-1", generation: 1,
            capturedAtMonotonicNanoseconds: 1,
            pcm16LEData: Data([1, 2]), sampleRate: 16_000
        )
        _ = try OpenAIXAIRealtimeCodec.audioAppend(chunk, sourceAlias: "audio-1", generation: 1)
        let event = try OpenAIXAIRealtimeCodec.parse(
            .text(#"{"type":"response.text.delta","delta":"ok"}"#)
        )
        precondition(event == .textDelta("ok"))
    }
}
