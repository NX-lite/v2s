import Foundation
import Testing
@testable import v2s

@Suite struct QwenGeminiRealtimeCodecTests {
    @Test func qwenSetupRequestsOnlyTextAndManualPCM16Input() throws {
        let setup = try #require(jsonObject(QwenRealtimeCodec.setup(
            sourceAlias: "audio-2", sourceRole: .applicationAudio
        )))
        let session = try #require(setup["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])

        #expect(setup["type"] as? String == "session.update")
        #expect(session["modalities"] as? [String] == ["text"])
        #expect(session["turn_detection"] is NSNull)
        #expect(format["sample_rate"] as? Int == 16_000)
        #expect(format["sample_format"] as? String == "s16le")
        #expect(format["channels"] as? Int == 1)
        let instructions = try #require(session["instructions"] as? String)
        #expect(instructions.contains("application audio source audio-2"))
        #expect(instructions.contains("corrected transcript"))
        #expect(!instructions.contains("bundle.example"))
        #expect(throws: RealtimeCodecError.invalidAlias) {
            try QwenRealtimeCodec.setup(sourceAlias: "bundle.example.app", sourceRole: .applicationAudio)
        }
    }

    @Test func qwenAudioEncodesOnlyValidMono16KPCM16() throws {
        let chunk = audioChunk(bytes: [0x01, 0x02, 0xFF, 0x7F])
        let message = try #require(jsonObject(QwenRealtimeCodec.audio(
            chunk, sourceAlias: "audio-1", generation: 4
        )))
        #expect(message["type"] as? String == "input_audio_buffer.append")
        #expect(message["audio"] as? String == Data([0x01, 0x02, 0xFF, 0x7F]).base64EncodedString())
        #expect(message["generation"] == nil)
        #expect(message["sourceAlias"] == nil)

        #expect(throws: RealtimeCodecError.invalidAudio) {
            try QwenRealtimeCodec.audio(
                audioChunk(bytes: [0x01, 0x02], sampleRate: 48_000),
                sourceAlias: "audio-1", generation: 4
            )
        }
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try QwenRealtimeCodec.audio(audioChunk(bytes: [0x01]), sourceAlias: "audio-1", generation: 4)
        }
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try QwenRealtimeCodec.audio(audioChunk(bytes: []), sourceAlias: "audio-1", generation: 4)
        }
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try QwenRealtimeCodec.audio(chunk, sourceAlias: "audio-2", generation: 4)
        }
        #expect(throws: RealtimeCodecError.invalidAudio) {
            try QwenRealtimeCodec.audio(chunk, sourceAlias: "audio-1", generation: 5)
        }
    }

    @Test func qwenFramesAreJPEGBase64AndRespectProviderEncodedLimit() throws {
        let frame = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 9,
            jpegData: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        )
        let message = try #require(jsonObject(QwenRealtimeCodec.frame(frame)))
        #expect(message["type"] as? String == "input_image_buffer.append")
        #expect(message["image"] as? String == frame.jpegData.base64EncodedString())
        #expect(message["sourceAlias"] == nil)
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try QwenRealtimeCodec.frame(RealtimeVideoFrame(
                sourceAlias: "display-stable-id",
                capturedAtMonotonicNanoseconds: 9,
                jpegData: frame.jpegData
            ))
        }
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try QwenRealtimeCodec.frame(RealtimeVideoFrame(
                sourceAlias: "visual-composite",
                capturedAtMonotonicNanoseconds: 9,
                jpegData: Data([0xFF, 0xD8, 0x01, 0x02])
            ))
        }

        let oversized = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 10,
            jpegData: Data(repeating: 0x01, count: 200 * 1024)
        )
        #expect(throws: RealtimeCodecError.oversizedMessage) {
            try QwenRealtimeCodec.frame(oversized)
        }
        let empty = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 11,
            jpegData: Data()
        )
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try QwenRealtimeCodec.frame(empty)
        }
    }

    @Test func qwenManualCommitOrdersCommitBeforeResponseCreate() throws {
        let utterance = realtimeUtterance()
        let commit = try QwenRealtimeCodec.commit(utterance)
        #expect(jsonObject(commit)?["type"] as? String == "input_audio_buffer.commit")
        #expect(!text(commit).contains(utterance.utteranceID))
        #expect(!text(commit).contains(utterance.sourceAlias))
        let acknowledgement = try QwenRealtimeCodec.parse(.text(#"{"type":"input_audio_buffer.committed","item_id":"private-item"}"#))
        #expect(acknowledgement == [.audioCommitted])
        let response = try QwenRealtimeCodec.responseCreate()
        #expect(jsonObject(response)?["type"] as? String == "response.create")
    }

    @Test func qwenParserReturnsOnlyTextAndAllowlistedControlEvents() throws {
        let delta = try QwenRealtimeCodec.parse(.text(#"{"type":"response.text.delta","delta":"hello","event_id":"secret-id"}"#))
        #expect(delta == [.textDelta("hello")])
        let done = try QwenRealtimeCodec.parse(.text(#"{"type":"response.done","response":{"id":"private-response"}}"#))
        #expect(done == [.responseComplete])
        let audio = try QwenRealtimeCodec.parse(.text(#"{"type":"response.audio.delta","delta":"c2VjcmV0LW1lZGlh"}"#))
        #expect(audio == [.audioOutputDetected])
        let audioTranscript = try QwenRealtimeCodec.parse(.text(#"{"type":"response.audio_transcript.delta","delta":"private transcript"}"#))
        #expect(audioTranscript == [.audioOutputDetected])
        let unknown = try QwenRealtimeCodec.parse(.text(#"{"type":"conversation.item.created","item":{"id":"private-id"}}"#))
        #expect(unknown.isEmpty)

        let failure = try QwenRealtimeCodec.parse(.text(#"{"type":"error","error":{"message":"private-key-echo"}}"#))
        #expect(failure == [.providerError])
        #expect(!String(describing: failure).contains("private-key-echo"))
    }

    @Test func qwenMalformedPayloadErrorsDoNotRetainPayload() {
        let raw = #"{"type":"response.text.delta","delta":{"secret":"payload"}}"#
        do {
            _ = try QwenRealtimeCodec.parse(.text(raw))
            Issue.record("Expected malformed text event to fail")
        } catch {
            #expect(error as? RealtimeCodecError == .malformedMessage)
            #expect(!String(describing: error).contains("secret"))
            #expect(!String(describing: error).contains("payload"))
        }
    }

    @Test func geminiSetupRequestsAudioWithOutputTranscriptionAndManualBoundaries() throws {
        let setup = try #require(jsonObject(GeminiRealtimeCodec.setup(
            sourceAlias: "audio-1", sourceRole: .microphone
        )))
        let body = try #require(setup["setup"] as? [String: Any])
        let generation = try #require(body["generationConfig"] as? [String: Any])
        let realtime = try #require(body["realtimeInputConfig"] as? [String: Any])
        let detection = try #require(realtime["automaticActivityDetection"] as? [String: Any])

        #expect(body["model"] as? String == "models/gemini-3.8-live")
        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        #expect(body["outputAudioTranscription"] is [String: Any])
        #expect(detection["disabled"] as? Bool == true)
        let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
        let parts = try #require(systemInstruction["parts"] as? [[String: Any]])
        let instructions = try #require(parts.first?["text"] as? String)
        #expect(instructions.contains("microphone source audio-1"))
        #expect(instructions.contains("corrected transcript"))
    }

    @Test func geminiAudioAndJPEGUseRealtimeInputBlobs() throws {
        let chunk = audioChunk(bytes: [0x11, 0x22])
        let audioMessage = try #require(jsonObject(GeminiRealtimeCodec.audio(
            chunk, sourceAlias: "audio-1", generation: 4
        )))
        let realtimeAudio = try #require(audioMessage["realtimeInput"] as? [String: Any])
        let audioBlob = try #require(realtimeAudio["audio"] as? [String: Any])
        #expect(audioBlob["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(audioBlob["data"] as? String == chunk.pcm16LEData.base64EncodedString())

        let frame = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 12,
            jpegData: Data([0xFF, 0xD8, 0x03, 0xFF, 0xD9])
        )
        let imageMessage = try #require(jsonObject(GeminiRealtimeCodec.frame(frame)))
        let realtimeVideo = try #require(imageMessage["realtimeInput"] as? [String: Any])
        let imageBlob = try #require(realtimeVideo["video"] as? [String: Any])
        #expect(imageBlob["mimeType"] as? String == "image/jpeg")
        #expect(imageBlob["data"] as? String == frame.jpegData.base64EncodedString())
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try GeminiRealtimeCodec.frame(RealtimeVideoFrame(
                sourceAlias: "window-stable-id",
                capturedAtMonotonicNanoseconds: 12,
                jpegData: frame.jpegData
            ))
        }

        #expect(throws: RealtimeCodecError.invalidAudio) {
            try GeminiRealtimeCodec.audio(
                audioChunk(bytes: [0x11], sampleRate: 8_000),
                sourceAlias: "audio-1", generation: 4
            )
        }
        #expect(throws: RealtimeCodecError.unsupportedMessage) {
            try GeminiRealtimeCodec.frame(RealtimeVideoFrame(
                sourceAlias: "visual-composite",
                capturedAtMonotonicNanoseconds: 13,
                jpegData: Data()
            ))
        }
    }

    @Test func geminiManualActivityEventsAndExpiryAreAllowlisted() throws {
        let start = try #require(jsonObject(GeminiRealtimeCodec.activityStart()))
        #expect(start["realtimeInput"] as? [String: Any] != nil)
        let end = try #require(jsonObject(GeminiRealtimeCodec.commit(realtimeUtterance())))
        let realtime = try #require(end["realtimeInput"] as? [String: Any])
        #expect(realtime["activityEnd"] as? [String: Any] != nil)

        let events = try GeminiRealtimeCodec.parse(.text(#"{"serverContent":{"outputTranscription":{"text":"caption"},"turnComplete":true,"modelTurn":{"parts":[{"inlineData":{"data":"private-audio"}}]}}}"#))
        #expect(events == [.outputTranscription("caption"), .turnComplete])
        let interrupted = try GeminiRealtimeCodec.parse(.text(#"{"serverContent":{"interrupted":true}}"#))
        #expect(interrupted == [.interrupted])
        let expiry = try GeminiRealtimeCodec.parse(.text(#"{"goAway":{"timeLeft":{"seconds":"12","nanos":500000000}}}"#))
        #expect(expiry == [.sessionExpiring(millisecondsRemaining: 12_500)])
        #expect(!String(describing: expiry).contains("token"))
        let ignoredAudio = try GeminiRealtimeCodec.parse(.text(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"private-audio"}}]}}}"#))
        #expect(ignoredAudio.isEmpty)
    }

    @Test func geminiMalformedPayloadErrorsDoNotRetainPayload() {
        let raw = #"{"serverContent":{"outputTranscription":{"text":{"secret":"payload"}}}}"#
        do {
            _ = try GeminiRealtimeCodec.parse(.text(raw))
            Issue.record("Expected malformed transcription to fail")
        } catch {
            #expect(error as? RealtimeCodecError == .malformedMessage)
            #expect(!String(describing: error).contains("secret"))
            #expect(!String(describing: error).contains("payload"))
        }
    }
}

private func audioChunk(bytes: [UInt8], sampleRate: Int = 16_000) -> RealtimeAudioChunk {
    RealtimeAudioChunk(
        sourceAlias: "audio-1",
        generation: 4,
        capturedAtMonotonicNanoseconds: 100,
        pcm16LEData: Data(bytes),
        sampleRate: sampleRate
    )
}

private func realtimeUtterance() -> RealtimeUtterance {
    RealtimeUtterance(
        sourceAlias: "audio-1",
        generation: 4,
        captionID: UUID(),
        utteranceID: "private-utterance-id",
        startMonotonicNanoseconds: 100,
        endMonotonicNanoseconds: 200
    )
}

private func jsonObject(_ message: String) -> [String: Any]? {
    guard let data = message.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func jsonObject(_ message: RealtimeSocketMessage) -> [String: Any]? {
    guard case .text(let value) = message else { return nil }
    return jsonObject(value)
}

private func text(_ message: RealtimeSocketMessage) -> String {
    guard case .text(let value) = message else { return "" }
    return value
}
