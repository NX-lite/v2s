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
        _ = try OpenAIXAIRealtimeCodec.xAIAppend(chunk, sourceAlias: "audio-1", generation: 1)
        let openAIWire = try OpenAIXAIRealtimeCodec.openAIWirePCM16(
            fromCanonicalPCM16LE: chunk.pcm16LEData, sourceAlias: "audio-1", generation: 1
        )
        _ = try OpenAIXAIRealtimeCodec.openAIAppend(openAIWire, sourceAlias: "audio-1", generation: 1)
        let event = try OpenAIXAIRealtimeCodec.parse(
            .text(#"{"type":"response.text.delta","delta":"ok"}"#)
        )
        precondition(event == .textDelta(responseID: nil, text: "ok"))
    }
}
