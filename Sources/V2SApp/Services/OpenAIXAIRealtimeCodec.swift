import Foundation

enum RealtimeCodecError: Error, Equatable, Sendable {
    case unsupportedProfile
    case invalidAlias
    case invalidAudio
    case malformedMessage
    case oversizedMessage
    case unsupportedMessage
}

enum OpenAIXAIRealtimeEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case audioCommitted
    case responseCreated(id: String?)
    case textDelta(responseID: String?, text: String)
    case textDone(responseID: String?, text: String?)
    case responseDone(responseID: String?)
    case audioOutputDetected
    case failure(RealtimeFailureCode)
    case ignored
}

/// Pure JSON wire codec. No socket, credentials, diagnostics, or media retention.
enum OpenAIXAIRealtimeCodec {
    static let maximumAudioChunkBytes = 32_000
    static let maximumIncomingBytes = 1_048_576
    private static let maximumTextCharacters = 8_192

    static func sessionUpdate(
        profile: NativeRealtimeProfile,
        sourceAlias: String,
        sourceRole: RealtimeAudioSourceRole = .microphone
    ) throws -> RealtimeSocketMessage {
        guard isOpenAI(profile) || isXAI(profile) else {
            throw RealtimeCodecError.unsupportedProfile
        }
        guard validAlias(sourceAlias) else {
            throw RealtimeCodecError.invalidAlias
        }

        let instructions = "You are correcting speech from \(sourceRole.providerLabel) " +
            "source \(sourceAlias) only. " +
            "Return only a concise, faithful corrected transcript of the current utterance " +
            "in its spoken language. Do not answer, explain, infer a speaker identity, " +
            "describe a scene, or include a source identifier."
        if isOpenAI(profile) {
            return try encode([
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "model": profile.modelID,
                    "output_modalities": ["text"],
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": 16_000],
                            "turn_detection": NSNull(),
                        ] as [String: Any],
                    ],
                    "instructions": instructions,
                ] as [String: Any],
            ])
        }
        return try encode([
            "type": "session.update",
            "session": [
                "turn_detection": NSNull(),
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": 16_000]],
                ],
                "instructions": instructions,
            ] as [String: Any],
        ])
    }

    static func audioAppend(
        _ chunk: RealtimeAudioChunk,
        sourceAlias: String,
        generation: Int
    ) throws -> RealtimeSocketMessage {
        guard validAlias(sourceAlias), chunk.sourceAlias == sourceAlias,
              chunk.generation == generation, chunk.sampleRate == 16_000,
              !chunk.pcm16LEData.isEmpty,
              chunk.pcm16LEData.count.isMultiple(of: 2),
              chunk.pcm16LEData.count <= maximumAudioChunkBytes else {
            throw RealtimeCodecError.invalidAudio
        }
        return try encode([
            "type": "input_audio_buffer.append",
            "audio": chunk.pcm16LEData.base64EncodedString(),
        ])
    }

    static func commit() throws -> RealtimeSocketMessage {
        try encode(["type": "input_audio_buffer.commit"])
    }

    static func responseCreate(profile: NativeRealtimeProfile) throws -> RealtimeSocketMessage {
        if isOpenAI(profile) {
            return try encode([
                "type": "response.create",
                "response": ["output_modalities": ["text"]],
            ])
        }
        if isXAI(profile) {
            return try encode([
                "type": "response.create",
                "response": ["modalities": ["text"]],
            ])
        }
        throw RealtimeCodecError.unsupportedProfile
    }

    static func parse(_ message: RealtimeSocketMessage) throws -> OpenAIXAIRealtimeEvent {
        guard case .text(let text) = message else {
            throw RealtimeCodecError.unsupportedMessage
        }
        guard text.utf8.count <= maximumIncomingBytes else {
            throw RealtimeCodecError.oversizedMessage
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else {
                throw RealtimeCodecError.malformedMessage
            }
            object = parsed
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
        guard let type = object["type"] as? String else {
            throw RealtimeCodecError.malformedMessage
        }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.committed": return .audioCommitted
        case "response.created":
            return .responseCreated(id: try nestedResponseID(object))
        case "response.output_text.delta", "response.text.delta":
            return .textDelta(
                responseID: try responseID(object, key: "response_id"),
                text: try boundedText(object["delta"])
            )
        case "response.output_text.done", "response.text.done":
            let responseID = try responseID(object, key: "response_id")
            if let value = object["text"] {
                return .textDone(responseID: responseID, text: try boundedText(value))
            }
            return .textDone(responseID: responseID, text: nil)
        case "response.output_audio.delta", "response.audio.delta",
             "response.output_audio_transcript.delta", "response.output_audio.done":
            return .audioOutputDetected
        case "response.done":
            let responseID = try nestedResponseID(object)
            guard let response = object["response"] as? [String: Any],
                  response["status"] as? String == "completed" else {
                return .failure(.capabilityRejected)
            }
            return .responseDone(responseID: responseID)
        case "error":
            let code = (object["error"] as? [String: Any])?["code"] as? String ?? ""
            return .failure(allowedFailure(for: code))
        default:
            return .ignored
        }
    }

    private static func boundedText(_ value: Any?) throws -> String {
        guard let text = value as? String,
              !text.isEmpty, text.count <= maximumTextCharacters else {
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

    private static func allowedFailure(for code: String) -> RealtimeFailureCode {
        switch code {
        case "rate_limit_exceeded", "rate_limit", "too_many_requests":
            return .rateLimited
        case "session_expired", "session_timeout":
            return .sessionExpired
        case "unsupported_modalities", "unsupported_model", "invalid_request_error",
             "invalid_value":
            return .capabilityRejected
        default:
            return .connectionFailed
        }
    }

    private static func encode(_ object: [String: Any]) throws -> RealtimeSocketMessage {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeCodecError.malformedMessage
            }
            return .text(text)
        } catch {
            throw RealtimeCodecError.malformedMessage
        }
    }

    private static func isOpenAI(_ profile: NativeRealtimeProfile) -> Bool {
        profile.provider == .openAI
    }

    private static func isXAI(_ profile: NativeRealtimeProfile) -> Bool {
        profile.provider == .xAI
    }

    private static func validAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("audio-"),
              let number = Int(alias.dropFirst("audio-".count)),
              (1...999).contains(number) else {
            return false
        }
        return alias == "audio-\(number)"
    }
}
