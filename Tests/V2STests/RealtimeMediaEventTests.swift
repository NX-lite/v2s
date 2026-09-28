import Foundation
import Testing
@testable import v2s

@Suite struct RealtimeMediaEventTests {
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
}
