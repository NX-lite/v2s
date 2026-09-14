import AVFoundation
import Foundation
import Testing
@testable import v2s

@Suite struct LiveTranscriptionSessionTests {
    @Test func legacyRecognitionErrorDispositionIgnoresCancellationErrors() {
        #expect(disposition(code: 216) == .ignore)
        #expect(disposition(code: 301) == .ignore)
    }

    @Test func legacyRecognitionErrorDispositionRestartsAfterSilence() {
        #expect(disposition(code: 1110) == .restartImmediately)
    }

    @Test func legacyRecognitionErrorDispositionStopsAfterServerQuotaError() {
        #expect(
            disposition(
                code: 203,
                message: "Quota limit reached for resource: speech_api, actor_type: user"
            ) == .stopAndSurface
        )
    }

    // Code 203 also covers transient faults that a restart clears, so the code alone
    // must not end the session.
    @Test func legacyRecognitionErrorDispositionRetriesNonQuotaCode203() {
        #expect(disposition(code: 203, message: "Retry") == .retryWithBackoff)
        #expect(disposition(code: 203, message: "Corrupt") == .retryWithBackoff)
    }

    @Test func legacyRecognitionErrorDispositionStopsOnQuotaRegardlessOfCode() {
        #expect(
            disposition(code: 1700, message: "Quota limit reached for resource: speech_api") == .stopAndSurface
        )
    }

    @Test func legacyRecognitionErrorDispositionBacksOffOtherErrors() {
        #expect(disposition(code: 999) == .retryWithBackoff)
        #expect(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet
            ) == .retryWithBackoff
        )
    }

    // A cancellation code from another domain is a real failure, not our own teardown.
    @Test func legacyRecognitionErrorDispositionDoesNotIgnoreForeignDomains() {
        #expect(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: 216
            ) == .retryWithBackoff
        )
    }

    @Test func recognizedSentenceRetainsOptionalWAVDataWithoutChangingTextOrPromotionIdentity() {
        let promotionSegmentID = UUID()
        let wav = Data("RIFF\u{00}\u{00}\u{00}\u{00}WAVE".utf8)

        let sentence = RecognizedSentence(
            text: "Recognized text.",
            promotionSegmentID: promotionSegmentID,
            audioWAVData: wav
        )

        #expect(sentence.text == "Recognized text.")
        #expect(sentence.promotionSegmentID == promotionSegmentID)
        #expect(sentence.audioWAVData == wav)
        #expect(RecognizedSentence(text: "Recognized text.").audioWAVData == nil)
    }

    @Test func correctionAudioCaptureIsDisabledByDefaultAndDisablingClearsCapturedFrames() async throws {
        let session = LiveTranscriptionSession()
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        await session.appendCorrectionAudioBufferForTesting(buffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 3)

        session.setCorrectionAudioCaptureEnabled(false)
        #expect(await session.correctionAudioFrameCountForTesting() == 0)
    }

    @Test func stoppingAndResettingRecognitionGenerationClearCorrectionAudioFrames() async throws {
        let session = LiveTranscriptionSession()
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 3)

        await session.resetRecognitionGenerationForTesting()
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        await session.appendCorrectionAudioBufferForTesting(buffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 3)

        await session.stopAndWait()
        #expect(await session.correctionAudioFrameCountForTesting() == 0)
    }

    private func disposition(
        code: Int,
        message: String = ""
    ) -> LiveTranscriptionSession.LegacyRecognitionErrorDisposition {
        LiveTranscriptionSession.legacyRecognitionErrorDisposition(
            domain: "kAFAssistantErrorDomain",
            code: code,
            message: message
        )
    }

    private func makeMono16KBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
