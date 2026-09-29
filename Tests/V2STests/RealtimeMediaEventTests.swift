import Foundation
import Testing
@testable import v2s

@Suite struct RealtimeMediaEventTests {
    @Test func sourceRolesExposeOnlyGenericDescriptions() {
        #expect(RealtimeAudioSourceRole.microphone.providerLabel == "microphone")
        #expect(RealtimeAudioSourceRole.applicationAudio.providerLabel == "application audio")
    }

    @Test func aliasesAreEphemeralAndDoNotExposeSourceIDs() {
        let aliases = RealtimeSourceAliases(
            sourceIDs: ["device-stable-id", "bundle.example.app", "device-stable-id"]
        )
        #expect(aliases.alias(for: "device-stable-id") == "audio-1")
        #expect(aliases.alias(for: "bundle.example.app") == "audio-2")
        #expect(aliases.alias(for: "unselected") == nil)
        #expect(aliases.publicMappings == ["audio-1", "audio-2"])
        #expect(!String(describing: aliases.publicMappings).contains("device-stable-id"))
    }

    @Test func aVideoFrameCarriesOnlyEphemeralIdentityAndBoundedBytes() {
        let frame = RealtimeVideoFrame(
            sourceAlias: "visual-composite",
            capturedAtMonotonicNanoseconds: 12,
            jpegData: Data([1, 2])
        )
        #expect(frame.sourceAlias == "visual-composite")
        #expect(frame.jpegData.count == 2)
    }

    @Test func audioAndUtteranceRetainGenerationAndAlias() {
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
        #expect(chunk.sourceAlias == utterance.sourceAlias)
        #expect(chunk.generation == utterance.generation)
        #expect(utterance.captionID == captionID)
    }

    @Test func correctedTextRetainsItsCompleteUtteranceAttribution() {
        let captionID = UUID(uuidString: "E2BD9B61-5B82-46D6-AC72-48C6FE39AA40")!
        let event = RealtimeProviderEvent.correctedText(
            sourceAlias: "audio-1",
            generation: 7,
            captionID: captionID,
            utteranceID: "turn-1",
            text: "corrected"
        )

        guard case .correctedText(let sourceAlias, let generation, let eventCaptionID, let utteranceID, let text) = event else {
            Issue.record("Expected a corrected text event")
            return
        }
        #expect(sourceAlias == "audio-1")
        #expect(generation == 7)
        #expect(eventCaptionID == captionID)
        #expect(utteranceID == "turn-1")
        #expect(text == "corrected")
    }

    @Test func nonCorrectionProviderEventsRetainSourceAndGeneration() {
        let suggestion = RealtimeProviderEvent.suggestion(
            sourceAlias: "audio-1", generation: 7, text: "possible correction"
        )
        let expired = RealtimeProviderEvent.expired(sourceAlias: "audio-1", generation: 7)
        let failure = RealtimeProviderEvent.failure(
            sourceAlias: "audio-1", generation: 7, .connectionFailed
        )

        #expect(suggestion == .suggestion(
            sourceAlias: "audio-1", generation: 7, text: "possible correction"
        ))
        #expect(expired == .expired(sourceAlias: "audio-1", generation: 7))
        #expect(failure == .failure(
            sourceAlias: "audio-1", generation: 7, .connectionFailed
        ))
        let failureAsError: any Error = RealtimeFailureCode.connectionFailed
        #expect(failureAsError is RealtimeFailureCode)
    }
}
