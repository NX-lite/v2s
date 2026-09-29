import Foundation

@main struct QwenGeminiRealtimeCodecSmoke {
    static func main() throws {
        let qwenSetup = try QwenRealtimeCodec.setup(sourceAlias: "audio-1", sourceRole: .microphone)
        precondition(jsonObject(qwenSetup)?["type"] as? String == "session.update")
        precondition(jsonObject(qwenSetup)?["session"] as? [String: Any] != nil)

        let chunk = RealtimeAudioChunk(
            sourceAlias: "audio-1",
            generation: 2,
            capturedAtMonotonicNanoseconds: 100,
            pcm16LEData: Data([0x01, 0x02]),
            sampleRate: 16_000
        )
        let audio = try QwenRealtimeCodec.audio(chunk, sourceAlias: "audio-1", generation: 2)
        precondition(jsonObject(audio)?["audio"] as? String == "AQI=")

        let frame = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 200,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )
        let qwenFrame = try QwenRealtimeCodec.frame(frame)
        precondition(jsonObject(qwenFrame)?["type"] as? String == "input_image_buffer.append")

        let utterance = RealtimeUtterance(
            sourceAlias: "audio-1",
            generation: 2,
            captionID: UUID(),
            utteranceID: "utterance-2",
            startMonotonicNanoseconds: 100,
            endMonotonicNanoseconds: 200
        )
        let qwenCommit = try QwenRealtimeCodec.commit(utterance)
        precondition(jsonObject(qwenCommit)?["type"] as? String == "input_audio_buffer.commit")
        let committed = try QwenRealtimeCodec.parse(.text(#"{"type":"input_audio_buffer.committed"}"#))
        precondition(committed == [.audioCommitted])
        let qwenResponse = try QwenRealtimeCodec.responseCreate()
        precondition(jsonObject(qwenResponse)?["type"] as? String == "response.create")
        let qwenEvents = try QwenRealtimeCodec.parse(.text(#"{"type":"response.text.delta","delta":"hello"}"#))
        precondition(qwenEvents == [.textDelta(responseID: nil, text: "hello")])

        let geminiSetup = try GeminiRealtimeCodec.setup(sourceAlias: "audio-1", sourceRole: .microphone)
        let setupBody = jsonObject(geminiSetup)?["setup"] as? [String: Any]
        precondition((setupBody?["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["AUDIO"])
        let geminiAudio = try GeminiRealtimeCodec.audio(chunk, sourceAlias: "audio-1", generation: 2)
        precondition((jsonObject(geminiAudio)?["realtimeInput"] as? [String: Any])?["audio"] != nil)
        let activityStart = try GeminiRealtimeCodec.activityStart()
        precondition(jsonObject(activityStart) != nil)
        let geminiCommit = try GeminiRealtimeCodec.commit(utterance)
        precondition(jsonObject(geminiCommit) != nil)
        let geminiEvents = try GeminiRealtimeCodec.parse(.text(#"{"serverContent":{"outputTranscription":{"text":"caption"},"turnComplete":true}}"#))
        precondition(geminiEvents == [.outputTranscription("caption"), .turnComplete])
        let expiryEvents = try GeminiRealtimeCodec.parse(.text(#"{"goAway":{"timeLeft":{"seconds":"1","nanos":250000000}}}"#))
        precondition(expiryEvents == [.sessionExpiring(millisecondsRemaining: 1_250)])
    }

    private static func jsonObject(_ message: RealtimeSocketMessage) -> [String: Any]? {
        guard case .text(let text) = message,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
