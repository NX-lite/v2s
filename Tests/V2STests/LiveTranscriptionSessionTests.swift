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

    @Test func recognizedSentenceWithoutProvenProvenanceRemainsLocalOnly() {
        let sentence = RecognizedSentence(text: "Local caption.")

        #expect(sentence.audioProvenance == nil)
    }

    @Test func realtimePCMChunkCarriesSampleIntervalAfterPreInputAudio() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()

        // Capture advances its normalized sample clock before the native input is activated.
        await session.appendRealtimePCM16AudioForTesting(
            try makeMono16KBuffer(samples: [0.125, -0.25, 0.5])
        )
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        await session.appendRealtimePCM16AudioForTesting(
            try makeMono16KBuffer(samples: [-0.5, 0.75])
        )
        let chunk = try #require(try await input.nextChunk())

        #expect(chunk.sourceToken == input.sourceToken)
        #expect(chunk.generation == input.generation)
        #expect(chunk.sampleInterval == 3..<5)
    }

    @Test func realtimePCMChunkSampleClockRestartsWithCaptureGeneration() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let oldInput = try #require(await session.makeRealtimePCM16AudioInput())
        await session.appendRealtimePCM16AudioForTesting(
            try makeMono16KBuffer(samples: [0.1, 0.2])
        )
        let oldChunk = try #require(try await oldInput.nextChunk())

        await session.beginRecognitionSessionForTesting()
        let newInput = try #require(await session.makeRealtimePCM16AudioInput())
        await session.appendRealtimePCM16AudioForTesting(
            try makeMono16KBuffer(samples: [-0.1])
        )
        let newChunk = try #require(try await newInput.nextChunk())

        #expect(oldChunk.sampleInterval == 0..<2)
        #expect(newInput.sourceToken != oldInput.sourceToken)
        #expect(newInput.generation > oldInput.generation)
        #expect(newChunk.sourceToken == newInput.sourceToken)
        #expect(newChunk.generation == newInput.generation)
        #expect(newChunk.sampleInterval == 0..<1)
    }

    @Test func legacyRecognitionClockMapsRequestTimeToCaptureSamples() {
        let sourceToken = UUID()
        var mapping = LegacyRecognitionSampleMapping(
            sourceToken: sourceToken,
            captureGeneration: 9
        )

        let firstAppendSucceeded = mapping.append(captureInterval: 3..<7, preserves16kFrameIdentity: true)
        let secondAppendSucceeded = mapping.append(captureInterval: 7..<10, preserves16kFrameIdentity: true)
        #expect(firstAppendSucceeded)
        #expect(secondAppendSucceeded)
        let provenance = mapping.provenance(for: [
            LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 1.0 / 16_000),
            LegacySpeechSegmentTiming(timestamp: 3.0 / 16_000, duration: 1.0 / 16_000)
        ])

        #expect(provenance?.sourceToken == sourceToken)
        #expect(provenance?.captureGeneration == 9)
        #expect(provenance?.sampleInterval == 5..<7)
    }

    @Test func legacyRecognitionClockInvalidatesSkippedOrConvertedAudio() {
        let sourceToken = UUID()
        var skipped = LegacyRecognitionSampleMapping(sourceToken: sourceToken, captureGeneration: 4)
        let initialAppendSucceeded = skipped.append(captureInterval: 0..<3, preserves16kFrameIdentity: true)
        #expect(initialAppendSucceeded)
        #expect(skipped.append(captureInterval: 4..<6, preserves16kFrameIdentity: true) == false)
        #expect(skipped.provenance(startSeconds: 0, durationSeconds: 2.0 / 16_000) == nil)

        var converted = LegacyRecognitionSampleMapping(sourceToken: sourceToken, captureGeneration: 4)
        let convertedInitialAppendSucceeded = converted.append(captureInterval: 0..<3, preserves16kFrameIdentity: true)
        #expect(convertedInitialAppendSucceeded)
        #expect(converted.append(captureInterval: 3..<5, preserves16kFrameIdentity: false) == false)
        #expect(converted.provenance(startSeconds: 0, durationSeconds: 2.0 / 16_000) == nil)

        var malformedSegmentsMapping = LegacyRecognitionSampleMapping(
            sourceToken: sourceToken,
            captureGeneration: 4
        )
        let malformedAppendSucceeded = malformedSegmentsMapping.append(
            captureInterval: 0..<4,
            preserves16kFrameIdentity: true
        )
        #expect(malformedAppendSucceeded)
        #expect(malformedSegmentsMapping.provenance(for: [
            LegacySpeechSegmentTiming(timestamp: 1.0 / 16_000, duration: 2.0 / 16_000),
            LegacySpeechSegmentTiming(timestamp: 2.0 / 16_000, duration: 1.0 / 16_000)
        ]) == nil)

        var extreme = LegacyRecognitionSampleMapping(sourceToken: sourceToken, captureGeneration: 4)
        let extremeAppendSucceeded = extreme.append(captureInterval: 0..<1, preserves16kFrameIdentity: true)
        #expect(extremeAppendSucceeded)
        #expect(
            extreme.provenance(
                startSeconds: 0,
                durationSeconds: Double(Int64.max) / 16_000
            ) == nil
        )
    }

    @Test @MainActor func committedLegacyProvenanceSurvivesRecognitionRestart() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        session.setCorrectionAudioCaptureEnabled(true)
        await session.beginRecognitionSessionForTesting()
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        await session.beginLegacySampleMappingForTesting()

        let first = try makeMono16KBuffer(samples: [0.25, -0.25])
        let second = try makeMono16KBuffer(samples: [0.5, -0.5])
        #expect(await session.appendLegacyNormalizedBufferForTesting(first, preservesIdentity: true) == 0..<2)
        #expect(await session.appendLegacyNormalizedBufferForTesting(second, preservesIdentity: true) == 2..<4)
        #expect(
            await session.queueLegacyCommittedEmissionForTesting(
                text: "Final legacy sentence.",
                segments: [LegacySpeechSegmentTiming(timestamp: 1.0 / 16_000, duration: 2.0 / 16_000)]
            ) == true
        )

        await session.resetRecognitionGenerationForTesting()
        await session.deliverQueuedCommittedEmissionForTesting()

        let sentence = try #require(recorder.sentences.first)
        #expect(sentence.text == "Final legacy sentence.")
        #expect(sentence.audioProvenance?.sourceToken == input.sourceToken)
        #expect(sentence.audioProvenance?.captureGeneration == input.generation)
        #expect(sentence.audioProvenance?.sampleInterval == 1..<3)
        let wav = try #require(sentence.audioWAVData)
        #expect(pcm16Samples(from: wav) == [8_192, -8_192, 16_384, -16_384])
    }

    @Test @MainActor func unprovenLegacyMappingKeepsLocalTextAndEligibleWAV() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        session.setCorrectionAudioCaptureEnabled(true)
        await session.beginRecognitionSessionForTesting()
        await session.beginLegacySampleMappingForTesting()

        let first = try makeMono16KBuffer(samples: [0.25, -0.25])
        let changedFormat = try makeMono16KBuffer(samples: [0.5, -0.5])
        _ = await session.appendLegacyNormalizedBufferForTesting(first, preservesIdentity: true)
        _ = await session.appendLegacyNormalizedBufferForTesting(changedFormat, preservesIdentity: false)
        #expect(
            await session.queueLegacyCommittedEmissionForTesting(
                text: "Keep local text and audio.",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            ) == false
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        let sentence = try #require(recorder.sentences.first)
        #expect(sentence.text == "Keep local text and audio.")
        #expect(sentence.audioProvenance == nil)
        let wav = try #require(sentence.audioWAVData)
        #expect(pcm16Samples(from: wav) == [8_192, -8_192, 16_384, -16_384])
    }

    @Test @MainActor func legacyCaptureOptOutStripsWAVButRetainsSnapshottedNativeProvenance() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        await session.resetCorrectionAudioCapture(enabled: true)
        await session.beginRecognitionSessionForTesting()
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        await session.beginLegacySampleMappingForTesting()

        _ = await session.appendLegacyNormalizedBufferForTesting(
            try makeMono16KBuffer(samples: [0.25, -0.25]),
            preservesIdentity: true
        )
        #expect(
            await session.queueLegacyCommittedEmissionForTesting(
                text: "Preserve native timing.",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 2.0 / 16_000)]
            )
        )

        await session.resetCorrectionAudioCapture(enabled: false)
        await session.deliverQueuedCommittedEmissionForTesting()

        let sentence = try #require(recorder.sentences.first)
        #expect(sentence.text == "Preserve native timing.")
        #expect(sentence.audioWAVData == nil)
        #expect(sentence.audioProvenance?.sourceToken == input.sourceToken)
        #expect(sentence.audioProvenance?.captureGeneration == input.generation)
        #expect(sentence.audioProvenance?.sampleInterval == 0..<2)
    }

    @Test @MainActor func splitLegacyEmissionDoesNotCopyItsWholeIntervalToEachUnit() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        await session.beginRecognitionSessionForTesting()
        await session.beginLegacySampleMappingForTesting()
        _ = await session.appendLegacyNormalizedBufferForTesting(
            try makeMono16KBuffer(samples: [0.25, -0.25, 0.5, -0.5]),
            preservesIdentity: true
        )
        #expect(
            await session.queueLegacyCommittedEmissionForTesting(
                text: "First unit. Second unit.",
                segments: [LegacySpeechSegmentTiming(timestamp: 0, duration: 4.0 / 16_000)]
            )
        )

        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.sentences.map(\.text) == ["First unit.", "Second unit."])
        #expect(recorder.sentences.allSatisfy { $0.audioProvenance == nil })
    }

    @Test func realtimeInputPublishesRawPCM16LEWithItsSourceAndGeneration() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        let buffer = try makeMono16KBuffer(samples: [0.5, -0.5, 1, -1])

        await session.appendRealtimePCM16AudioForTesting(buffer)
        let chunk = try #require(try await input.nextChunk())

        #expect(chunk.sourceToken == input.sourceToken)
        #expect(chunk.generation == input.generation)
        #expect(chunk.sampleRate == 16_000)
        #expect(chunk.frameCount == 4)
        #expect(chunk.pcm16LE == Data([0x00, 0x40, 0x00, 0xc0, 0xff, 0x7f, 0x00, 0x80]))
    }

    @Test func realtimeCaptureQueueDoesNotWaitForSlowNetworkConsumer() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25])
        await session.appendRealtimePCM16AudioForTesting(buffer)

        let networkStarted = DispatchSemaphore(value: 0)
        let allowNetworkToContinue = RealtimeTestGate()
        let consumer = Task.detached {
            let chunk = try await input.nextChunk()
            networkStarted.signal()
            await allowNetworkToContinue.wait()
            return chunk
        }
        #expect(await waitForRealtimeTestSemaphore(networkStarted, timeout: 2))

        let captureCompleted = DispatchSemaphore(value: 0)
        let captureTask = Task.detached {
            await session.appendRealtimePCM16AudioForTesting(buffer)
            captureCompleted.signal()
        }
        let captureReturnedWithoutNetwork = await waitForRealtimeTestSemaphore(captureCompleted, timeout: 1)
        await allowNetworkToContinue.open()

        #expect(captureReturnedWithoutNetwork)
        await captureTask.value
        _ = try await consumer.value
        await session.stopAndWait()
    }

    @Test func realtimeQueueOverflowEndsTheInputInsteadOfDroppingOldAudio() async throws {
        let sourceToken = UUID()
        let fanout = RealtimePCM16AudioFanout(
            sourceToken: sourceToken,
            generation: 7,
            maximumBufferedFrames: 4,
            maximumBufferedChunks: 2
        )
        let input = try #require(fanout.makeInput())

        #expect(fanout.offer(
            pcm16LE: Data(repeating: 0x11, count: 6),
            frameCount: 3,
            sampleInterval: 0..<3,
            sourceToken: sourceToken,
            generation: 7,
            captureTimestampNanoseconds: 10
        ) == .enqueued)
        #expect(fanout.offer(
            pcm16LE: Data(repeating: 0x22, count: 4),
            frameCount: 2,
            sampleInterval: 3..<5,
            sourceToken: sourceToken,
            generation: 7,
            captureTimestampNanoseconds: 20
        ) == .backpressureExceeded)

        var streamError: RealtimePCM16AudioStreamError?
        do {
            _ = try await input.nextChunk()
        } catch let error as RealtimePCM16AudioStreamError {
            streamError = error
        }
        #expect(streamError == .backpressureExceeded)
        #expect(fanout.offer(
            pcm16LE: Data([0x33, 0x33]),
            frameCount: 1,
            sampleInterval: 5..<6,
            sourceToken: sourceToken,
            generation: 7,
            captureTimestampNanoseconds: 30
        ) == .closed)
    }

    @Test func realtimeFanoutRejectsNegativeExtremeSampleIntervalWithoutOverflowing() async throws {
        let sourceToken = UUID()
        let fanout = RealtimePCM16AudioFanout(sourceToken: sourceToken, generation: 2)
        _ = try #require(fanout.makeInput())

        let result = fanout.offer(
            pcm16LE: Data(repeating: 0, count: 2),
            frameCount: 1,
            sampleInterval: Int64.min..<Int64.max,
            sourceToken: sourceToken,
            generation: 2,
            captureTimestampNanoseconds: 0
        )

        #expect(result == .invalidAudioChunk)
        #expect(fanout.terminationError == .invalidAudioChunk)

        let largestFanout = RealtimePCM16AudioFanout(sourceToken: sourceToken, generation: 3)
        _ = try #require(largestFanout.makeInput())
        let largestRangeResult = largestFanout.offer(
            pcm16LE: Data(repeating: 0, count: 2),
            frameCount: 1,
            sampleInterval: 0..<Int64.max,
            sourceToken: sourceToken,
            generation: 3,
            captureTimestampNanoseconds: 0
        )
        #expect(largestRangeResult == .invalidAudioChunk)
        #expect(largestFanout.terminationError == .invalidAudioChunk)
    }

    @Test func realtimeInputRejectsOtherSourcesAndStaleGenerations() async throws {
        let sourceToken = UUID()
        let fanout = RealtimePCM16AudioFanout(
            sourceToken: sourceToken,
            generation: 12,
            maximumBufferedFrames: 8,
            maximumBufferedChunks: 4
        )
        let input = try #require(fanout.makeInput())

        #expect(fanout.offer(
            pcm16LE: Data([0x01, 0x02]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: UUID(),
            generation: 12,
            captureTimestampNanoseconds: 1
        ) == .rejectedSource)
        #expect(fanout.offer(
            pcm16LE: Data([0x03, 0x04]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: sourceToken,
            generation: 11,
            captureTimestampNanoseconds: 2
        ) == .rejectedGeneration)
        #expect(fanout.offer(
            pcm16LE: Data([0x05, 0x06]),
            frameCount: 1,
            sampleInterval: 0..<1,
            sourceToken: sourceToken,
            generation: 12,
            captureTimestampNanoseconds: 3
        ) == .enqueued)

        let chunk = try #require(try await input.nextChunk())
        #expect(chunk.sourceToken == sourceToken)
        #expect(chunk.generation == 12)
        #expect(chunk.pcm16LE == Data([0x05, 0x06]))
    }

    @Test func restartingSessionInvalidatesOldRealtimeInputAndCreatesNewGeneration() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let oldInput = try #require(await session.makeRealtimePCM16AudioInput())

        await session.beginRecognitionSessionForTesting()
        let newInput = try #require(await session.makeRealtimePCM16AudioInput())
        #expect(oldInput.sourceToken != newInput.sourceToken)
        #expect(oldInput.generation < newInput.generation)

        let buffer = try makeMono16KBuffer(samples: [0.125])
        await session.appendRealtimePCM16AudioForTesting(buffer)
        let newChunk = try #require(try await newInput.nextChunk())
        #expect(newChunk.sourceToken == newInput.sourceToken)
        #expect(newChunk.generation == newInput.generation)

        var oldStreamError: RealtimePCM16AudioStreamError?
        do {
            _ = try await oldInput.nextChunk()
        } catch let error as RealtimePCM16AudioStreamError {
            oldStreamError = error
        }
        #expect(oldStreamError == .sourceSuperseded)
        await session.stopAndWait()
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

    @Test @MainActor func resettingCorrectionAudioCaptureInvalidatesOldWAVAndRearmsBeforeReturning() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        let buffer = try makeMono16KBuffer(samples: [0.25, -0.25, 0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Old provider sentence."
        )

        await session.resetCorrectionAudioCapture(enabled: true)

        #expect(await session.correctionAudioCaptureEnabledForTesting())
        #expect(await session.correctionAudioFrameCountForTesting() == 0)
        await session.deliverQueuedCommittedEmissionForTesting()
        #expect(recorder.texts == ["Old provider sentence."])
        #expect(recorder.receivedAudio == [false])

        await session.appendCorrectionAudioBufferForTesting(buffer)
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "New provider sentence."
        )
        await session.deliverQueuedCommittedEmissionForTesting()
        #expect(recorder.texts == ["Old provider sentence.", "New provider sentence."])
        #expect(recorder.receivedAudio == [false, true])
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
        #expect(await session.waitForCommittedDeliveryAuthorizationPauseForTesting())

        session.setCorrectionAudioCaptureEnabled(false)
        #expect(await session.waitForDeliveryMutationAttemptForTesting())
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
        #expect(await session.waitForCommittedDeliveryAuthorizationPauseForTesting())

        session.stop()
        #expect(await session.waitForDeliveryMutationAttemptForTesting())
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
        #expect(await session.waitForCommittedDeliveryAuthorizationPauseForTesting())

        let beginSession = Task {
            await session.beginRecognitionSessionForTesting()
        }
        #expect(await session.waitForDeliveryMutationAttemptForTesting())
        #expect(session.isDeliveryMutationWaitingForTesting())

        session.resumeCommittedDeliveryAfterAuthorizationForTesting()
        await delivery.value
        await beginSession.value

        let sentences = recorder.snapshot()
        #expect(sentences.map(\.text) == ["First sentence.", "Second sentence."])
        let expectedWAV = try #require(sentences.first?.audioWAVData)
        #expect(sentences.allSatisfy { $0.audioWAVData == expectedWAV })
    }

    @Test func staleModernTaskFailureCannotFallbackANewerModernSession() async throws {
        let session = LiveTranscriptionSession()
        let newSessionBuffer = try makeMono16KBuffer(samples: [0.5, -0.5])

        session.setCorrectionAudioCaptureEnabled(true)
        let epochA = await session.beginSpeechAnalyzerRecognitionForTesting()
        await session.beginRecognitionSessionForTesting()
        let epochB = await session.beginSpeechAnalyzerRecognitionForTesting()
        await session.appendCorrectionAudioBufferForTesting(newSessionBuffer)

        await session.triggerModernTaskFailureForTesting(epoch: epochA)

        #expect(await session.isSpeechAnalyzerRecognitionCurrentForTesting(epoch: epochB))
        #expect(await session.correctionAudioFrameCountForTesting() == 2)
    }

    @Test func staleModernVADTimerCannotCommitAfterLegacyFallback() async throws {
        let session = LiveTranscriptionSession()
        let modernEpoch = await session.beginSpeechAnalyzerRecognitionForTesting()

        #expect(await session.scheduleModernVADSilenceTimerForTesting() == modernEpoch)
        await session.fallbackSpeechAnalyzerToLegacyForTesting()
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.5, -0.5])
        )

        #expect(await session.triggerModernVADSilenceTimerForTesting(epoch: modernEpoch) == false)
    }

    @Test @MainActor func legacySegmentRebaseDropsPreRebaseCorrectionAudio() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.125, -0.25])
        )
        await session.rebaseLegacySegmentsForTesting()
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.75, -0.5])
        )
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Post-rebase only.",
            through: 0.000125
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        let wav = try #require(recorder.sentences.first?.audioWAVData)
        #expect(pcm16Samples(from: wav) == [24_575, -16_384])
    }

    @Test @MainActor func legacyConversionGapDropsAffectedAudioBoundaryAndStartsFreshWAV() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }

        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.125, -0.25])
        )
        await session.markLegacyCorrectionAudioConversionGapForTesting()
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.5, -0.5])
        )
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Gap boundary.",
            through: 0.00025
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.sentences.map(\.audioWAVData) == [nil])
        #expect(await session.correctionAudioFrameCountForTesting() == 0)

        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.75, -0.5])
        )
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "Clean boundary.",
            through: 0.0005
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        let freshWAV = try #require(recorder.sentences.last?.audioWAVData)
        #expect(pcm16Samples(from: freshWAV) == [24_575, -16_384])
    }

    @Test @MainActor func disablingOrResettingRecognitionClearsLegacyConversionGap() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }

        session.setCorrectionAudioCaptureEnabled(true)
        await session.markLegacyCorrectionAudioConversionGapForTesting()
        session.setCorrectionAudioCaptureEnabled(false)
        session.setCorrectionAudioCaptureEnabled(true)
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.25, -0.25])
        )
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "After disable.",
            through: 0.000125
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        await session.markLegacyCorrectionAudioConversionGapForTesting()
        await session.resetRecognitionGenerationForTesting()
        await session.appendCorrectionAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.5, -0.5])
        )
        await session.captureCommittedEmissionForDeferredDeliveryAfterAudioExtractionForTesting(
            text: "After reset.",
            through: 0.000125
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.sentences.count == 2)
        #expect(recorder.sentences.allSatisfy { $0.audioWAVData != nil })
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

    private func pcm16Samples(from wav: Data) -> [Int16] {
        guard wav.count >= 44 else { return [] }
        return stride(from: 44, to: wav.count - 1, by: 2).map { index in
            Int16(bitPattern: UInt16(wav[index]) | UInt16(wav[index + 1]) << 8)
        }
    }
}

private func waitForRealtimeTestSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

private actor RealtimeTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class RecognizedSentenceRecorder {
    private(set) var texts: [String] = []
    private(set) var receivedAudio: [Bool] = []
    private(set) var sentences: [RecognizedSentence] = []

    func record(_ sentence: RecognizedSentence) {
        texts.append(sentence.text)
        receivedAudio.append(sentence.audioWAVData != nil)
        sentences.append(sentence)
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
