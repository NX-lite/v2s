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

    @Test @MainActor func staleModernEpochAfterFallbackCannotConsumeLegacyAudioOrEmit() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let oldBuffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])
        let legacyBuffer = try makeMono16KBuffer(samples: [0.5, -0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        let modernEpoch = await session.beginSpeechAnalyzerRecognitionForTesting()
        await session.appendCorrectionAudioBufferForTesting(oldBuffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 3)
        #expect(
            await session.enqueueModernCommittedEmissionForTesting(
                text: "Queued modern result.",
                epoch: modernEpoch
            )
        )
        await session.appendCorrectionAudioBufferForTesting(oldBuffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 3)

        await session.fallbackSpeechAnalyzerToLegacyForTesting()
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        await session.appendCorrectionAudioBufferForTesting(legacyBuffer)
        #expect(await session.correctionAudioFrameCountForTesting() == 2)
        #expect(
            await session.enqueueModernCommittedEmissionForTesting(
                text: "Stale modern result.",
                epoch: modernEpoch
            ) == false
        )
        #expect(await session.correctionAudioFrameCountForTesting() == 2)
        await session.deliverQueuedCommittedEmissionForTesting()
        #expect(recorder.texts.isEmpty)
    }

    @Test @MainActor func disablingCaptureStripsAudioFromQueuedEmissionButRetainsText() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.queueCommittedEmissionForTesting(text: "Keep text after opt-out.")

        session.setCorrectionAudioCaptureEnabled(false)
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts == ["Keep text after opt-out."])
        #expect(recorder.receivedAudio == [false])
    }

    @Test @MainActor func stoppingSuppressesQueuedEmissionWithCapturedAudio() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.queueCommittedEmissionForTesting(text: "Do not deliver after stop.")

        await session.stopAndWait()
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts.isEmpty)
        #expect(recorder.receivedAudio.isEmpty)
    }

    @Test func regressedLegacyAudioBoundaryDoesNotConsumeLaterFrames() async throws {
        let session = LiveTranscriptionSession()
        let firstBuffer = try makeMono16KBuffer(samples: Array(repeating: 0.25, count: 8))
        let laterBuffer = try makeMono16KBuffer(samples: Array(repeating: 0.5, count: 4))

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(firstBuffer)
        await session.finishCorrectionAudioThroughForTesting(0.00025)
        #expect(await session.correctionAudioFrameCountForTesting() == 4)

        await session.resetLegacyTranscriptionStateForTesting()
        await session.finishCorrectionAudioThroughForTesting(0.000125)
        #expect(await session.correctionAudioFrameCountForTesting() == 4)

        await session.appendCorrectionAudioBufferForTesting(laterBuffer)
        await session.finishCorrectionAudioThroughForTesting(0.0005)
        #expect(await session.correctionAudioFrameCountForTesting() == 4)
    }

    @Test func staleModernSetupCannotInstallAfterSessionStops() async {
        let session = LiveTranscriptionSession()
        let startupEpoch = await session.beginModernSetupForTesting()

        await session.stopAndWait()

        #expect(await session.finalizeModernSetupForTesting(startupEpoch) == false)
        #expect(await session.isModernRecognizerInstalledForTesting() == false)
    }

    @Test @MainActor func invalidationAfterSequenceAuthorizationDoesNotPoisonDuplicateHistory() async {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }

        await session.queueCommittedEmissionForTesting(text: "Deliver once.")
        session.invalidateNextCommittedDeliveryAfterAuthorizationForTesting()
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts.isEmpty)

        await session.beginRecognitionSessionForTesting()
        await session.queueCommittedEmissionForTesting(text: "Deliver once.")
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts == ["Deliver once."])
    }

    @Test func disablingCaptureWaitsForAnAuthorizedSplitDeliveryTransaction() async throws {
        let session = LiveTranscriptionSession()
        let recorder = ThreadSafeRecognizedSentenceRecorder()
        await MainActor.run {
            session.setTranscriptHandlerForTesting { recorder.record($0) }
        }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.queueCommittedEmissionForTesting(text: "First sentence. Second sentence.")
        session.pauseNextCommittedDeliveryAfterAuthorizationForTesting()

        let delivery = Task {
            await session.deliverQueuedCommittedEmissionForTesting()
        }
        await session.waitForCommittedDeliveryAuthorizationPauseForTesting()

        session.setCorrectionAudioCaptureEnabled(false)
        await session.waitForDeliveryMutationAttemptForTesting()
        #expect(session.isDeliveryMutationWaitingForTesting())

        session.resumeCommittedDeliveryAfterAuthorizationForTesting()
        await delivery.value
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        let sentences = recorder.snapshot()
        #expect(sentences.map(\.text) == ["First sentence.", "Second sentence."])
        let expectedWAV = try #require(sentences.first?.audioWAVData)
        #expect(sentences.allSatisfy { $0.audioWAVData == expectedWAV })
    }

    @Test func stoppingDuringAuthorizedSplitDeliveryCompletesTheWholeTransactionBeforeStop() async throws {
        let session = LiveTranscriptionSession()
        let recorder = ThreadSafeRecognizedSentenceRecorder()
        await MainActor.run {
            session.setTranscriptHandlerForTesting { recorder.record($0) }
        }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.queueCommittedEmissionForTesting(text: "First sentence. Second sentence.")
        session.pauseNextCommittedDeliveryAfterAuthorizationForTesting()

        let delivery = Task {
            await session.deliverQueuedCommittedEmissionForTesting()
        }
        await session.waitForCommittedDeliveryAuthorizationPauseForTesting()

        session.stop()
        await session.waitForDeliveryMutationAttemptForTesting()
        #expect(session.isDeliveryMutationWaitingForTesting())

        session.resumeCommittedDeliveryAfterAuthorizationForTesting()
        await delivery.value
        await session.stopAndWait()

        let sentences = recorder.snapshot()
        #expect(sentences.map(\.text) == ["First sentence.", "Second sentence."])
        let expectedWAV = try #require(sentences.first?.audioWAVData)
        #expect(sentences.allSatisfy { $0.audioWAVData == expectedWAV })
    }

    @Test @MainActor func snapshottedAudioEmissionCannotDeliverAfterStopDuringDeferredDelivery() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Do not revive after stop."
        )

        await session.stopAndWait()
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts.isEmpty)
        #expect(recorder.receivedAudio.isEmpty)
    }

    @Test @MainActor func snapshottedAudioEmissionCannotAcquireReenabledCaptureEpoch() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Keep only text after re-enable."
        )

        session.setCorrectionAudioCaptureEnabled(false)
        session.setCorrectionAudioCaptureEnabled(true)
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts == ["Keep only text after re-enable."])
        #expect(recorder.receivedAudio == [false])
    }

    @Test func beginningRecognitionWaitsForAnAuthorizedSplitDeliveryTransaction() async throws {
        let session = LiveTranscriptionSession()
        let recorder = ThreadSafeRecognizedSentenceRecorder()
        await MainActor.run {
            session.setTranscriptHandlerForTesting { recorder.record($0) }
        }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.queueCommittedEmissionForTesting(text: "First sentence. Second sentence.")
        session.pauseNextCommittedDeliveryAfterAuthorizationForTesting()

        let delivery = Task {
            await session.deliverQueuedCommittedEmissionForTesting()
        }
        await session.waitForCommittedDeliveryAuthorizationPauseForTesting()

        let beginSession = Task {
            await session.beginRecognitionSessionForTesting()
        }
        await session.waitForDeliveryMutationAttemptForTesting()
        #expect(session.isDeliveryMutationWaitingForTesting())

        session.resumeCommittedDeliveryAfterAuthorizationForTesting()
        await delivery.value
        await beginSession.value

        let sentences = recorder.snapshot()
        #expect(sentences.map(\.text) == ["First sentence.", "Second sentence."])
        let expectedWAV = try #require(sentences.first?.audioWAVData)
        #expect(sentences.allSatisfy { $0.audioWAVData == expectedWAV })
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

@MainActor private final class RecognizedSentenceRecorder {
    private(set) var texts: [String] = []
    private(set) var receivedAudio: [Bool] = []

    func record(_ sentence: RecognizedSentence) {
        texts.append(sentence.text)
        receivedAudio.append(sentence.audioWAVData != nil)
    }
}

private final class ThreadSafeRecognizedSentenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sentences: [RecognizedSentence] = []

    func record(_ sentence: RecognizedSentence) {
        lock.lock()
        sentences.append(sentence)
        lock.unlock()
    }

    func snapshot() -> [RecognizedSentence] {
        lock.lock()
        defer { lock.unlock() }
        return sentences
    }
}
