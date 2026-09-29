import Foundation

enum QwenRealtimeCodecEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case audioCommitted
    case responseCreated(id: String?)
    case textDelta(responseID: String?, text: String)
    case textComplete(responseID: String?, text: String)
    case responseComplete(responseID: String?)
    case audioOutputDetected
    case providerError
}

enum GeminiRealtimeCodecEvent: Equatable, Sendable {
    case setupComplete
    case outputTranscription(String)
    case turnComplete
    case interrupted
    case sessionExpiring(millisecondsRemaining: Int?)
    case providerError
}

/// Pure Qwen WebSocket JSON codec. It does not own a socket or retain media.
enum QwenRealtimeCodec {
    static let maximumAudioChunkBytes = 32_000
    static let maximumEncodedImageBytes = 256 * 1024
    static let maximumIncomingMessageBytes = 1_048_576
    private static let maximumTextCharacters = 8_192
    static func setup(
        sourceAlias: String,
        sourceRole: RealtimeAudioSourceRole = .microphone
    ) throws -> RealtimeSocketMessage {
        guard validAlias(sourceAlias) else {
            throw RealtimeCodecError.invalidAlias
        }
        let instructions = "You are transcribing audio from \(sourceRole.providerLabel) " +
            "source \(sourceAlias) only. Return only a concise, faithful corrected transcript " +
            "of the current utterance in its spoken language. Do not answer, explain, infer a " +
            "speaker identity, describe a scene, or include a source identifier."
        return try encode([
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "turn_detection": NSNull(),
                "audio": [
                    "input": [
                        "format": [
                            "type": "pcm",
                            "sample_rate": 16_000,
                            "sample_format": "s16le",
                            "channels": 1,
                            "packing": "interleaved",
                            "channel_layout": "mono",
                        ],
                    ],
                ],
                "instructions": instructions,
            ] as [String: Any],
        ])
    }

    static func audio(
        _ chunk: RealtimeAudioChunk,
        sourceAlias: String,
        generation: Int
    ) throws -> RealtimeSocketMessage {
        try validateAudio(chunk, sourceAlias: sourceAlias, generation: generation)
        return try encode([
            "type": "input_audio_buffer.append",
            "audio": chunk.pcm16LEData.base64EncodedString(),
        ])
    }

    static func frame(_ frame: RealtimeVideoFrame) throws -> RealtimeSocketMessage {
        guard !frame.jpegData.isEmpty else {
            throw RealtimeCodecError.unsupportedMessage
        }
        let encodedByteCount = ((frame.jpegData.count + 2) / 3) * 4
        guard encodedByteCount <= maximumEncodedImageBytes else {
            throw RealtimeCodecError.oversizedMessage
        }
        guard frame.sourceAlias == "visual-composite", isJPEG(frame.jpegData) else {
            throw RealtimeCodecError.unsupportedMessage
        }
        return try encode([
            "type": "input_image_buffer.append",
            "image": frame.jpegData.base64EncodedString(),
        ])
    }

    /// Manual Qwen Omni mode commits the buffered user turn.
    /// Wait for `audioCommitted` before requesting a response.
    static func commit(_ utterance: RealtimeUtterance) throws -> RealtimeSocketMessage {
        guard validAlias(utterance.sourceAlias), !utterance.utteranceID.isEmpty,
              utterance.endMonotonicNanoseconds >= utterance.startMonotonicNanoseconds else {
            throw RealtimeCodecError.unsupportedMessage
        }
        return try encode(["type": "input_audio_buffer.commit"])
    }

    static func responseCreate() throws -> RealtimeSocketMessage {
        try encode(["type": "response.create"])
    }

    static func parse(_ message: RealtimeSocketMessage) throws -> [QwenRealtimeCodecEvent] {
        let object = try decode(message)
        guard let type = object["type"] as? String else {
            throw RealtimeCodecError.malformedMessage
        }
        switch type {
        case "session.created":
            return [.sessionCreated]
        case "session.updated":
            return [.sessionUpdated]
        case "input_audio_buffer.committed":
            return [.audioCommitted]
        case "response.created":
            return [.responseCreated(id: try nestedResponseID(object))]
        case "response.text.delta":
            return [.textDelta(
                responseID: try responseID(object, key: "response_id"),
                text: try boundedText(object["delta"])
            )]
        case "response.text.done":
            return [.textComplete(
                responseID: try responseID(object, key: "response_id"),
                text: try boundedText(object["text"])
            )]
        case "response.audio.delta", "response.audio.done",
             "response.audio_transcript.delta", "response.audio_transcript.done":
            return [.audioOutputDetected]
        case "response.done":
            return [.responseComplete(responseID: try nestedResponseID(object))]
        case "error":
            return [.providerError]
        default:
            // Unrecognized provider fields and media never escape.
            return []
        }
    }

    private static func validateAudio(
        _ chunk: RealtimeAudioChunk,
        sourceAlias: String,
        generation: Int
    ) throws {
        guard validAlias(sourceAlias), chunk.sourceAlias == sourceAlias,
              chunk.generation == generation, chunk.sampleRate == 16_000,
              !chunk.pcm16LEData.isEmpty,
              chunk.pcm16LEData.count.isMultiple(of: 2),
              chunk.pcm16LEData.count <= maximumAudioChunkBytes else {
            throw RealtimeCodecError.invalidAudio
        }
    }

    private static func decode(_ message: RealtimeSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else {
            throw RealtimeCodecError.unsupportedMessage
        }
        guard text.utf8.count <= maximumIncomingMessageBytes else {
            throw RealtimeCodecError.oversizedMessage
        }
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw RealtimeCodecError.malformedMessage
            }
            return value
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
    }

    private static func encode(_ object: [String: Any]) throws -> RealtimeSocketMessage {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeCodecError.malformedMessage
            }
            return .text(text)
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
    }

    private static func boundedText(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.isEmpty,
              text.count <= maximumTextCharacters else {
            throw RealtimeCodecError.malformedMessage
        }
        return text
    }

    private static func nestedResponseID(_ object: [String: Any]) throws -> String? {
        guard let response = object["response"] else { return nil }
        guard let response = response as? [String: Any] else {
            throw RealtimeCodecError.malformedMessage
        }
        return try responseID(response, key: "id")
    }

    private static func responseID(_ object: [String: Any], key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let value = value as? String, validResponseID(value) else {
            throw RealtimeCodecError.malformedMessage
        }
        return value
    }

    private static func validResponseID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) ||
                (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D
        }
    }

    private static func validAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("audio-"),
              let number = Int(alias.dropFirst("audio-".count)),
              (1...999).contains(number) else {
            return false
        }
        return alias == "audio-\(number)"
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(2) == Data([0xFF, 0xD8]) &&
            data.suffix(2) == Data([0xFF, 0xD9])
    }
}

/// Pure Gemini Live JSON codec. AUDIO output is requested as required by the
/// native audio model, but generated audio payloads are intentionally ignored.
enum GeminiRealtimeCodec {
    static let defaultModel = "models/gemini-3.8-live"
    static let maximumAudioChunkBytes = 32_000
    static let maximumFrameBytes = 1_048_576
    static let maximumIncomingMessageBytes = 1_048_576
    private static let maximumTextCharacters = 8_192
    static func setup(
        sourceAlias: String,
        sourceRole: RealtimeAudioSourceRole = .microphone,
        model: String = defaultModel
    ) throws -> RealtimeSocketMessage {
        guard validAlias(sourceAlias) else {
            throw RealtimeCodecError.invalidAlias
        }
        guard validModel(model) else {
            throw RealtimeCodecError.unsupportedMessage
        }
        let instructions = "You are transcribing audio from \(sourceRole.providerLabel) " +
            "source \(sourceAlias) only. Return only a concise, faithful corrected transcript " +
            "of the current utterance in its spoken language. Do not answer, explain, infer a " +
            "speaker identity, describe a scene, or include a source identifier."
        return try encode([
            "setup": [
                "model": model,
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "outputAudioTranscription": [String: String](),
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": true],
                ],
                "systemInstruction": ["parts": [["text": instructions]]],
            ],
        ])
    }

    static func activityStart() throws -> RealtimeSocketMessage {
        try encode(["realtimeInput": ["activityStart": [String: String]()]] )
    }

    static func audio(
        _ chunk: RealtimeAudioChunk,
        sourceAlias: String,
        generation: Int
    ) throws -> RealtimeSocketMessage {
        try validateAudio(chunk, sourceAlias: sourceAlias, generation: generation)
        return try encode([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": chunk.pcm16LEData.base64EncodedString(),
                ],
            ],
        ])
    }

    static func frame(_ frame: RealtimeVideoFrame) throws -> RealtimeSocketMessage {
        guard !frame.jpegData.isEmpty else {
            throw RealtimeCodecError.unsupportedMessage
        }
        guard frame.jpegData.count <= maximumFrameBytes else {
            throw RealtimeCodecError.oversizedMessage
        }
        guard frame.sourceAlias == "visual-composite", isJPEG(frame.jpegData) else {
            throw RealtimeCodecError.unsupportedMessage
        }
        return try encode([
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": frame.jpegData.base64EncodedString(),
                ],
            ],
        ])
    }

    /// Gemini's manual utterance boundary is activityEnd; no response.create exists.
    static func commit(_ utterance: RealtimeUtterance) throws -> RealtimeSocketMessage {
        guard validAlias(utterance.sourceAlias), !utterance.utteranceID.isEmpty,
              utterance.endMonotonicNanoseconds >= utterance.startMonotonicNanoseconds else {
            throw RealtimeCodecError.unsupportedMessage
        }
        return try encode(["realtimeInput": ["activityEnd": [String: String]()]] )
    }

    static func parse(_ message: RealtimeSocketMessage) throws -> [GeminiRealtimeCodecEvent] {
        let object = try decode(message)
        if object["setupComplete"] != nil {
            return [.setupComplete]
        }
        if let goAway = object["goAway"] as? [String: Any] {
            return [.sessionExpiring(millisecondsRemaining: milliseconds(goAway["timeLeft"]))]
        }
        if object["error"] != nil {
            return [.providerError]
        }
        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return []
        }

        var events: [GeminiRealtimeCodecEvent] = []
        if let transcription = serverContent["outputTranscription"] {
            guard let transcription = transcription as? [String: Any] else {
                throw RealtimeCodecError.malformedMessage
            }
            events.append(.outputTranscription(try boundedText(transcription["text"])))
        }
        if let interrupted = serverContent["interrupted"] {
            guard let interrupted = interrupted as? Bool else {
                throw RealtimeCodecError.malformedMessage
            }
            if interrupted { events.append(.interrupted) }
        }
        if let turnComplete = serverContent["turnComplete"] {
            guard let turnComplete = turnComplete as? Bool else {
                throw RealtimeCodecError.malformedMessage
            }
            if turnComplete { events.append(.turnComplete) }
        }
        return events
    }

    private static func validateAudio(
        _ chunk: RealtimeAudioChunk,
        sourceAlias: String,
        generation: Int
    ) throws {
        guard validAlias(sourceAlias), chunk.sourceAlias == sourceAlias,
              chunk.generation == generation, chunk.sampleRate == 16_000,
              !chunk.pcm16LEData.isEmpty,
              chunk.pcm16LEData.count.isMultiple(of: 2),
              chunk.pcm16LEData.count <= maximumAudioChunkBytes else {
            throw RealtimeCodecError.invalidAudio
        }
    }

    private static func decode(_ message: RealtimeSocketMessage) throws -> [String: Any] {
        guard case .text(let text) = message else {
            throw RealtimeCodecError.unsupportedMessage
        }
        guard text.utf8.count <= maximumIncomingMessageBytes else {
            throw RealtimeCodecError.oversizedMessage
        }
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw RealtimeCodecError.malformedMessage
            }
            return value
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
    }

    private static func encode(_ object: [String: Any]) throws -> RealtimeSocketMessage {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeCodecError.malformedMessage
            }
            return .text(text)
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
    }

    private static func boundedText(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.isEmpty,
              text.count <= maximumTextCharacters else {
            throw RealtimeCodecError.malformedMessage
        }
        return text
    }

    private static func milliseconds(_ value: Any?) -> Int? {
        guard let duration = value as? [String: Any],
              let seconds = integer(duration["seconds"]),
              seconds >= 0 else {
            return nil
        }
        let nanos = integer(duration["nanos"]) ?? 0
        guard (0..<1_000_000_000).contains(nanos),
              seconds <= (Int.max - nanos / 1_000_000) / 1_000 else {
            return nil
        }
        return seconds * 1_000 + nanos / 1_000_000
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func validModel(_ model: String) -> Bool {
        model == defaultModel
    }

    private static func validAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("audio-"),
              let number = Int(alias.dropFirst("audio-".count)),
              (1...999).contains(number) else {
            return false
        }
        return alias == "audio-\(number)"
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(2) == Data([0xFF, 0xD8]) &&
            data.suffix(2) == Data([0xFF, 0xD9])
    }
}
