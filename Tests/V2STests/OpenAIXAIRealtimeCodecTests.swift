import Foundation
import Testing
@testable import v2s

@Suite struct OpenAIXAIRealtimeCodecTests {
    @Test func openAISetupIsManualTextOnlyAndSourceScoped() throws {
        let object = try json(OpenAIXAIRealtimeCodec.sessionUpdate(
            profile: .openAIMini, sourceAlias: "audio-1", sourceRole: .applicationAudio
        ))
        #expect(object["type"] as? String == "session.update")
        let session = try #require(object["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")
        #expect(session["model"] as? String == "gpt-realtime-2.1-mini")
        #expect(session["output_modalities"] as? [String] == ["text"])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        #expect(input["turn_detection"] is NSNull)
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 16_000)
        #expect((session["instructions"] as? String)?.contains("audio-1") == true)
        #expect((session["instructions"] as? String)?.contains("application audio") == true)
        #expect(!(session["instructions"] as? String ?? "").contains("bundle.example"))
        #expect(throws: RealtimeCodecError.invalidAlias) {
            try OpenAIXAIRealtimeCodec.sessionUpdate(
                profile: .openAIMini, sourceAlias: "bundle.example.app"
            )
        }
    }

    @Test func xAISetupAndResponseRequestDoNotAskForSpeech() throws {
        let object = try json(OpenAIXAIRealtimeCodec.sessionUpdate(
            profile: .xAIVoice, sourceAlias: "audio-2"
        ))
        let session = try #require(object["session"] as? [String: Any])
        #expect(session["turn_detection"] is NSNull)
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["rate"] as? Int == 16_000)
        let response = try json(OpenAIXAIRealtimeCodec.responseCreate(profile: .xAIVoice))
        #expect((response["response"] as? [String: Any])?["modalities"] as? [String] == ["text"])
        let openAIResponse = try json(OpenAIXAIRealtimeCodec.responseCreate(profile: .openAI))
        #expect((openAIResponse["response"] as? [String: Any])?["output_modalities"] as? [String] == ["text"])
        #expect(try json(OpenAIXAIRealtimeCodec.commit())["type"] as? String == "input_audio_buffer.commit")
    }

    @Test func audioAppendRejectsWrongSourceGenerationFormatAndSize() throws {
        let valid = RealtimeAudioChunk(
            sourceAlias: "audio-1", generation: 7,
            capturedAtMonotonicNanoseconds: 10,
            pcm16LEData: Data([1, 2, 3, 4]), sampleRate: 16_000
        )
        let event = try json(OpenAIXAIRealtimeCodec.audioAppend(
            valid, sourceAlias: "audio-1", generation: 7
        ))
        #expect(event["type"] as? String == "input_audio_buffer.append")
        #expect(event["audio"] as? String == "AQIDBA==")
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try OpenAIXAIRealtimeCodec.audioAppend(valid, sourceAlias: "audio-2", generation: 7)
        }
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try OpenAIXAIRealtimeCodec.audioAppend(valid, sourceAlias: "audio-1", generation: 8)
        }
        let odd = RealtimeAudioChunk(
            sourceAlias: "audio-1", generation: 7,
            capturedAtMonotonicNanoseconds: 11,
            pcm16LEData: Data([1, 2, 3]), sampleRate: 16_000
        )
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try OpenAIXAIRealtimeCodec.audioAppend(odd, sourceAlias: "audio-1", generation: 7)
        }
        let wrongRate = RealtimeAudioChunk(
            sourceAlias: "audio-1", generation: 7,
            capturedAtMonotonicNanoseconds: 11,
            pcm16LEData: Data([1, 2]), sampleRate: 24_000
        )
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try OpenAIXAIRealtimeCodec.audioAppend(wrongRate, sourceAlias: "audio-1", generation: 7)
        }
        let oversized = RealtimeAudioChunk(
            sourceAlias: "audio-1", generation: 7,
            capturedAtMonotonicNanoseconds: 12,
            pcm16LEData: Data(count: OpenAIXAIRealtimeCodec.maximumAudioChunkBytes + 2),
            sampleRate: 16_000
        )
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try OpenAIXAIRealtimeCodec.audioAppend(oversized, sourceAlias: "audio-1", generation: 7)
        }
    }

    @Test func parserAllowlistsTextAndRejectsAudioOutput() throws {
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"session.created"}"#)) == .sessionCreated)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"session.updated"}"#)) == .sessionUpdated)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"input_audio_buffer.committed"}"#)) == .audioCommitted)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.output_text.delta","delta":"hello"}"#)) == .textDelta("hello"))
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.text.delta","delta":"world"}"#)) == .textDelta("world"))
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.output_text.done","text":"hello"}"#)) == .textDone("hello"))
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.output_audio.delta","delta":"AQID"}"#)) == .audioOutputDetected)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.output_audio_transcript.delta","delta":"spoken reply"}"#)) == .audioOutputDetected)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"response.done","response":{"status":"completed"}}"#)) == .responseDone)
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"rate_limits.updated"}"#)) == .ignored)
    }

    @Test func parserNeverReturnsRawProviderErrorsOrMedia() throws {
        let raw = #"{"type":"error","error":{"code":"rate_limit_exceeded","message":"secret response AQID"}}"#
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(raw)) == .failure(.rateLimited))
        #expect(try OpenAIXAIRealtimeCodec.parse(.text(#"{"type":"error","error":{"code":"unexpected","message":"secret response AQID"}}"#)) == .failure(.connectionFailed))
        #expect(throws: RealtimeCodecError.malformedMessage) {
            try OpenAIXAIRealtimeCodec.parse(.text("not json secret"))
        }
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try OpenAIXAIRealtimeCodec.parse(.binary(Data([1, 2, 3])))
        }
        #expect(throws: RealtimeCodecError.oversizedMessage) {
            try OpenAIXAIRealtimeCodec.parse(.text(String(repeating: "x", count: OpenAIXAIRealtimeCodec.maximumIncomingBytes + 1)))
        }
    }

    private func json(_ message: RealtimeSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else { throw RealtimeCodecError.unsupportedMessage }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
