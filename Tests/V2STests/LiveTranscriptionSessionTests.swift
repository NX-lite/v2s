import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import v2s

private final class WeakNormalizedRepackBuffers {
    weak var input: AVAudioPCMBuffer?
    weak var output: AVAudioPCMBuffer?
}

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

    @Test func modernRecognitionClockRequiresMatchingContiguousAnalyzerFrames() {
        let sourceToken = UUID()
        var valid = ModernRecognitionSampleMapping(
            sourceToken: sourceToken,
            captureGeneration: 11
        )
        let validAppendSucceeded = valid.appendBuffer(
            captureInterval: 4..<8,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: true
        )
        valid.recordDelivery(.enqueued)
        let exactProvenance = valid.provenance(for: sampleTimeRange(start: 4, duration: 2))
        #expect(validAppendSucceeded)
        #expect(exactProvenance?.sourceToken == sourceToken)
        #expect(exactProvenance?.captureGeneration == 11)
        #expect(exactProvenance?.sampleInterval == 4..<6)
        #expect(valid.provenance(for: sampleTimeRange(start: 3, duration: 1)) == nil)
        #expect(valid.provenance(for: sampleTimeRange(start: 7, duration: 2)) == nil)

        var mapping = ModernRecognitionSampleMapping(
            sourceToken: UUID(),
            captureGeneration: 12
        )

        let firstAppendSucceeded = mapping.appendBuffer(
            captureInterval: 4..<8,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: true
        )
        let secondAppendSucceeded = mapping.appendBuffer(
            captureInterval: 8..<12,
            outputSampleRate: 48_000,
            outputFrameCount: 12,
            preservesFrameIdentity: true
        )

        #expect(firstAppendSucceeded)
        #expect(secondAppendSucceeded == false)
        #expect(mapping.isValid == false)
        #expect(mapping.provenance(for: sampleTimeRange(start: 4, duration: 2)) == nil)
    }

    @Test func modernRecognitionClockRejectsTimeFromDifferentCMTimeEpochButKeepsLocalText() {
        var mapping = ModernRecognitionSampleMapping(sourceToken: UUID(), captureGeneration: 22)
        let appendSucceeded = mapping.appendBuffer(
            captureInterval: 0..<8,
            outputSampleRate: 16_000,
            outputFrameCount: 8,
            preservesFrameIdentity: true
        )
        mapping.recordDelivery(.enqueued)
        let foreignEpochRange = CMTimeRange(
            start: CMTime(value: 0, timescale: 16_000, flags: .valid, epoch: 1),
            duration: CMTime(value: 2, timescale: 16_000)
        )
        let foreignEpochProvenance = mapping.provenance(for: foreignEpochRange)
        let snapshot = ModernSpeechTextSnapshot(
            text: "声。",
            runs: [ModernSpeechTimedTextRun(utf16Range: 0..<2, audioProvenance: foreignEpochProvenance)]
        )

        #expect(appendSucceeded)
        #expect(snapshot.text == "声。")
        #expect(snapshot.audioProvenance == nil)
    }

    @Test @available(macOS 26.0, *) func modernAnalyzerInputUsesCaptureStartForEnqueuedUnchangedPCM() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let stream = await session.installModernAnalyzerInputStreamForTesting()
        await session.appendCapturedAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.1, 0.2, 0.3, 0.4])
        )

        var iterator = stream.makeAsyncIterator()
        let input = try #require(await iterator.next())
        let provenance = await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 0, duration: 4))
        #expect(input.bufferStartTime == CMTime(value: 0, timescale: 16_000))
        #expect(input.sampleRate == 16_000)
        #expect(input.frameCount == 4)
        #expect(provenance?.sampleInterval == 0..<4)
    }

    @Test @available(macOS 26.0, *) func modernAnalyzerStreamDropInvalidatesMappingButRetainsNewestLocalBuffer() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let stream = await session.installModernAnalyzerInputStreamForTesting()
        for frame in 0..<13 {
            await session.appendCapturedAudioBufferForTesting(
                try makeMono16KBuffer(samples: [Float(frame) / 13])
            )
        }

        var iterator = stream.makeAsyncIterator()
        var retainedInputs: [ModernAnalyzerInputSummary] = []
        for _ in 0..<12 {
            if let input = await iterator.next() {
                retainedInputs.append(input)
            }
        }
        let provenance = await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 12, duration: 1))
        #expect(retainedInputs.count == 12)
        #expect(retainedInputs.first?.bufferStartTime == CMTime(value: 1, timescale: 16_000))
        #expect(retainedInputs.last?.frameCount == 1)
        #expect(retainedInputs.last?.bufferStartTime == CMTime(value: 12, timescale: 16_000))
        #expect(provenance == nil)
    }

    @Test @available(macOS 26.0, *) func modernAnalyzerChannelConversionKeepsLocalPCMWithoutInventingCaptureStart() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let convertedFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            )
        )
        let stream = await session.installModernAnalyzerInputStreamForTesting(analyzerFormat: convertedFormat)
        await session.appendCapturedAudioBufferForTesting(
            try makeMono16KBuffer(samples: Array(repeating: 0.25, count: 160))
        )

        var iterator = stream.makeAsyncIterator()
        let retainedInput = try #require(await iterator.next())
        let provenance = await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 0, duration: 160))
        #expect(retainedInput.frameCount == 160)
        #expect(retainedInput.sampleRate == 16_000)
        #expect(retainedInput.isInt16PCM)
        #expect(retainedInput.isInterleaved)
        #expect(retainedInput.bufferStartTime == nil)
        #expect(provenance == nil)
    }

    @Test @available(macOS 26.0, *) func normalizedMono16kToInt16RepackPreservesCaptureClockAndFrames() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let convertedFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let analyzerStream = await session.installRealModernAnalyzerInputStreamForTesting(analyzerFormat: convertedFormat)
        let nativeInput = try #require(await session.makeRealtimePCM16AudioInput())
        await session.appendCapturedAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.5, -0.5, 1, -1])
        )

        var analyzerIterator = analyzerStream.makeAsyncIterator()
        let analyzerInput = try #require(await analyzerIterator.next())
        let nativeChunk = try #require(try await nativeInput.nextChunk())
        let provenance = await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 0, duration: 4))
        let analyzerPCM16 = try int16PCM16LittleEndianBytes(analyzerInput.buffer)

        #expect(analyzerInput.buffer.frameLength == 4)
        #expect(analyzerInput.buffer.format.sampleRate == 16_000)
        #expect(analyzerInput.buffer.format.commonFormat == .pcmFormatInt16)
        #expect(analyzerInput.buffer.format.isInterleaved)
        #expect(analyzerInput.bufferStartTime == CMTime(value: 0, timescale: 16_000))
        #expect(analyzerPCM16.count == 8)
        #expect(analyzerPCM16 == nativeChunk.pcm16LE)
        #expect(nativeChunk.frameCount == 4)
        #expect(nativeChunk.sampleInterval == 0..<4)
        #expect(provenance?.sampleInterval == 0..<4)
        #expect(provenance?.sourceToken == nativeInput.sourceToken)
        #expect(provenance?.captureGeneration == nativeInput.generation)
    }

    @Test func normalizedPCM16RepackUsesExactNativeQuantizerAndPreservesEveryFrame() throws {
        let samples: [Float] = [.nan, .infinity, -.infinity, -1.5, -1, -0.5, 0, 0.5, 1, 1.5]
        let source = try makeMono16KBuffer(samples: samples)
        let targetFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let repacked = try #require(NormalizedMono16kPCM16Repacker.repack(source, to: targetFormat))
        let values = try #require(repacked.buffer.int16ChannelData?[0])
        let actualSamples = Array(UnsafeBufferPointer(start: values, count: Int(repacked.buffer.frameLength)))
        let expectedSamples: [Int16] = [0, 0, 0, .min, .min, -16_384, 0, 16_384, .max, .max]
        let expectedBytes = Data(expectedSamples.flatMap { sample in
            let bits = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
        })

        #expect(repacked.buffer.frameLength == AVAudioFrameCount(samples.count))
        #expect(actualSamples == expectedSamples)
        #expect(try int16PCM16LittleEndianBytes(repacked.buffer) == expectedBytes)
    }

    @Test func modernAnalyzerWithoutMappingStillYieldsLocalPCM() async throws {
        let (stream, continuation) = AsyncStream<ModernAnalyzerInputSummary>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var mapping: ModernRecognitionSampleMapping?
        var deliveryCount = 0
        let timestamp = ModernAnalyzerInputAppender.appendAndDeliver(
            mapping: &mapping,
            captureSampleInterval: nil,
            inputSampleRate: 16_000,
            inputChannelCount: 1,
            inputFrameCount: 8,
            outputSampleRate: 16_000,
            outputChannelCount: 1,
            outputFrameCount: 8,
            unchangedBufferObject: true
        ) { bufferStartTime in
            deliveryCount += 1
            switch continuation.yield(
                ModernAnalyzerInputSummary(
                    frameCount: 8,
                    sampleRate: 16_000,
                    isInt16PCM: false,
                    isInterleaved: false,
                    bufferStartTime: bufferStartTime
                )
            ) {
            case .enqueued:
                return .enqueued
            case .dropped:
                return .dropped
            case .terminated:
                return .terminated
            @unknown default:
                return .terminated
            }
        }

        #expect(deliveryCount == 1)
        var iterator = stream.makeAsyncIterator()
        let retainedInput = deliveryCount == 1 ? await iterator.next() : nil
        #expect(timestamp == nil)
        #expect(retainedInput?.frameCount == 8)
        #expect(retainedInput?.bufferStartTime == nil)
    }

    @Test @available(macOS 26.0, *) func modernAnalyzerTerminatedStreamInvalidatesMapping() async throws {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        _ = await session.installModernAnalyzerInputStreamForTesting()
        await session.terminateModernAnalyzerInputStreamForTesting()
        await session.appendCapturedAudioBufferForTesting(
            try makeMono16KBuffer(samples: [0.1, 0.2, 0.3])
        )

        let provenance = await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 0, duration: 3))
        #expect(provenance == nil)
    }

    @Test @available(macOS 26.0, *)
    func captureSampleBufferGapsInvalidateModernProvenanceButPreserveLaterLocalInput() async throws {
        for gap in ["not ready", "conversion failed"] {
            let session = LiveTranscriptionSession()
            await session.beginRecognitionSessionForTesting()
            let stream = await session.installModernAnalyzerInputStreamForTesting()
            await session.appendCapturedAudioBufferForTesting(
                try makeMono16KBuffer(samples: [0.1, 0.2])
            )

            var iterator = stream.makeAsyncIterator()
            let beforeGap = try #require(await iterator.next())
            #expect(beforeGap.bufferStartTime == CMTime(value: 0, timescale: 16_000))

            await session.appendCapturedSampleBufferForTesting(
                dataIsReady: gap != "not ready",
                convertedPCMBuffer: nil
            )
            await session.appendCapturedAudioBufferForTesting(
                try makeMono16KBuffer(samples: [0.3, 0.4])
            )

            let afterGap = try #require(await iterator.next())
            let provenance = await session.modernAudioProvenanceForTesting(
                sampleTimeRange(start: 2, duration: 2)
            )
            #expect(afterGap.frameCount == 2)
            #expect(afterGap.bufferStartTime == nil)
            #expect(provenance == nil)
        }
    }

    @Test func normalizedRepackProofKeepsExactBuffersAliveForItsLifetime() throws {
        let weakBuffers = WeakNormalizedRepackBuffers()
        var proof: NormalizedPCM16RepackProof?
        do {
            let source = try makeMono16KBuffer(samples: [0.1, 0.2, 0.3, 0.4])
            let targetFormat = try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: true
                )
            )
            let result = try #require(NormalizedMono16kPCM16Repacker.repack(source, to: targetFormat))
            weakBuffers.input = source
            weakBuffers.output = result.buffer
            proof = result.proof
        }

        #expect(weakBuffers.input != nil)
        #expect(weakBuffers.output != nil)
        let proofStillIdentifiesItsBuffers = NormalizedAudioFrameIdentity.preservesNormalizedSamples(
            captureInterval: 20..<24,
            inputSampleRate: 16_000,
            inputChannelCount: 1,
            inputFrameCount: 4,
            outputSampleRate: 16_000,
            outputChannelCount: 1,
            outputFrameCount: 4,
            unchangedBufferObject: false,
            verifiedRepackProof: proof,
            inputBuffer: weakBuffers.input,
            outputBuffer: weakBuffers.output
        )
        #expect(proofStillIdentifiesItsBuffers)
        proof = nil
        #expect(weakBuffers.input == nil)
        #expect(weakBuffers.output == nil)
    }

    @Test func normalizedSampleIdentityAcceptsOnlyItsTypedDirectRepackProof() throws {
        let captureInterval: NormalizedAudioSampleInterval = 20..<24
        let source = try makeMono16KBuffer(samples: [0.1, 0.2, 0.3, 0.4])
        let targetFormat = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let repacked = try #require(NormalizedMono16kPCM16Repacker.repack(source, to: targetFormat))
        let unrelatedConvertedBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(4))
        )
        unrelatedConvertedBuffer.frameLength = 4
        let unchangedBufferIsValid = NormalizedAudioFrameIdentity.preservesNormalizedSamples(
            captureInterval: captureInterval,
            inputSampleRate: 16_000,
            inputChannelCount: 1,
            inputFrameCount: 4,
            outputSampleRate: 16_000,
            outputChannelCount: 1,
            outputFrameCount: 4,
            unchangedBufferObject: true
        )
        let sameShapeConvertedBufferIsValid = NormalizedAudioFrameIdentity.preservesNormalizedSamples(
            captureInterval: captureInterval,
            inputSampleRate: 16_000,
            inputChannelCount: 1,
            inputFrameCount: 4,
            outputSampleRate: 16_000,
            outputChannelCount: 1,
            outputFrameCount: 4,
            unchangedBufferObject: false,
            inputBuffer: source,
            outputBuffer: unrelatedConvertedBuffer
        )
        let verifiedRepackIsValid = NormalizedAudioFrameIdentity.preservesNormalizedSamples(
            captureInterval: captureInterval,
            inputSampleRate: 16_000,
            inputChannelCount: 1,
            inputFrameCount: 4,
            outputSampleRate: 16_000,
            outputChannelCount: 1,
            outputFrameCount: 4,
            unchangedBufferObject: false,
            verifiedRepackProof: repacked.proof,
            inputBuffer: source,
            outputBuffer: repacked.buffer
        )

        #expect(unchangedBufferIsValid)
        #expect(sameShapeConvertedBufferIsValid == false)
        #expect(verifiedRepackIsValid)

        var unprovenMapping = ModernRecognitionSampleMapping(sourceToken: UUID(), captureGeneration: 19)
        let unprovenAppendSucceeded = unprovenMapping.appendBuffer(
            captureInterval: captureInterval,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: sameShapeConvertedBufferIsValid
        )
        #expect(unprovenAppendSucceeded == false)
        #expect(unprovenMapping.isValid == false)
    }

    @Test func modernRecognitionClockInvalidatesSkippedBuffersAndStreamDrops() {
        var skipped = ModernRecognitionSampleMapping(sourceToken: UUID(), captureGeneration: 13)
        let initialAppendSucceeded = skipped.appendBuffer(
            captureInterval: 0..<4,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: true
        )
        let skippedAppendSucceeded = skipped.appendBuffer(
            captureInterval: 5..<7,
            outputSampleRate: 16_000,
            outputFrameCount: 2,
            preservesFrameIdentity: true
        )
        #expect(initialAppendSucceeded)
        #expect(skippedAppendSucceeded == false)
        #expect(skipped.provenance(for: sampleTimeRange(start: 0, duration: 1)) == nil)

        var dropped = ModernRecognitionSampleMapping(sourceToken: UUID(), captureGeneration: 14)
        let droppedAppendSucceeded = dropped.appendBuffer(
            captureInterval: 0..<4,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: true
        )
        #expect(droppedAppendSucceeded)
        dropped.recordDelivery(.dropped)
        #expect(dropped.isValid == false)
        #expect(dropped.provenance(for: sampleTimeRange(start: 0, duration: 1)) == nil)

        var terminated = ModernRecognitionSampleMapping(sourceToken: UUID(), captureGeneration: 18)
        let terminatedAppendSucceeded = terminated.appendBuffer(
            captureInterval: 0..<4,
            outputSampleRate: 16_000,
            outputFrameCount: 4,
            preservesFrameIdentity: true
        )
        #expect(terminatedAppendSucceeded)
        terminated.recordDelivery(.terminated)
        #expect(terminated.isValid == false)
        #expect(terminated.provenance(for: sampleTimeRange(start: 0, duration: 1)) == nil)
    }

    @Test func modernTimedTextRetainsExactUTF16RunsAcrossUnicodeAndTrimming() throws {
        let sourceToken = UUID()
        let generation: UInt64 = 15
        let secondRange = RecognizedAudioProvenance(
            sourceToken: sourceToken,
            captureGeneration: generation,
            sampleInterval: 40..<70
        )
        let snapshot = ModernSpeechTextSnapshot(
            text: "  中🙂e\u{301}。次の文!  ",
            runs: [
                ModernSpeechTimedTextRun(utf16Range: 0..<2, audioProvenance: nil),
                ModernSpeechTimedTextRun(
                    utf16Range: 2..<5,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: sourceToken,
                        captureGeneration: generation,
                        sampleInterval: 0..<20
                    )
                ),
                ModernSpeechTimedTextRun(
                    utf16Range: 5..<8,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: sourceToken,
                        captureGeneration: generation,
                        sampleInterval: 20..<40
                    )
                ),
                ModernSpeechTimedTextRun(utf16Range: 8..<12, audioProvenance: secondRange),
                ModernSpeechTimedTextRun(utf16Range: 12..<14, audioProvenance: nil)
            ]
        )

        let firstSentence = try #require(snapshot.slice(relativeUTF16Range: 0..<6))
        let secondSentence = try #require(snapshot.slice(relativeUTF16Range: 6..<10))
        #expect(snapshot.text == "中🙂e\u{301}。次の文!")
        #expect(firstSentence.text == "中🙂e\u{301}。")
        #expect(secondSentence.text == "次の文!")
        #expect(firstSentence.audioProvenance?.sampleInterval == 0..<40)
        #expect(secondSentence.audioProvenance == secondRange)
        #expect(firstSentence.audioProvenance?.sampleInterval != secondSentence.audioProvenance?.sampleInterval)
    }

    @Test @available(macOS 26.0, *) func modernTimedTextSnapshotsActualSpeechAttributeRuns() throws {
        let sourceToken = UUID()
        var mapping = ModernRecognitionSampleMapping(sourceToken: sourceToken, captureGeneration: 21)
        let appendSucceeded = mapping.appendBuffer(
            captureInterval: 0..<70,
            outputSampleRate: 16_000,
            outputFrameCount: 70,
            preservesFrameIdentity: true
        )
        mapping.recordDelivery(.enqueued)
        #expect(appendSucceeded)

        var attributedText = AttributedString("中🙂e\u{301}。次の文!")
        let firstRunRange = try #require(attributedText.range(of: "中🙂"))
        attributedText[firstRunRange].audioTimeRange = sampleTimeRange(start: 0, duration: 20)
        let secondRunRange = try #require(attributedText.range(of: "e\u{301}。"))
        attributedText[secondRunRange].audioTimeRange = sampleTimeRange(start: 20, duration: 20)
        let thirdRunRange = try #require(attributedText.range(of: "次の文!"))
        attributedText[thirdRunRange].audioTimeRange = sampleTimeRange(start: 40, duration: 30)

        let snapshot = ModernSpeechTextSnapshot(attributedText: attributedText, mapping: mapping)
        let firstSentence = try #require(snapshot.slice(relativeUTF16Range: 0..<6))
        let secondSentence = try #require(snapshot.slice(relativeUTF16Range: 6..<10))
        #expect(firstSentence.text == "中🙂e\u{301}。")
        #expect(secondSentence.text == "次の文!")
        #expect(firstSentence.audioProvenance?.sampleInterval == 0..<40)
        #expect(secondSentence.audioProvenance?.sampleInterval == 40..<70)
    }

    @Test @MainActor @available(macOS 26.0, *)
    func modernTimedEmissionKeepsSentenceIntervalsAfterMappingInvalidationAndAudioOptOut() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        await session.beginRecognitionSessionForTesting()
        session.setCorrectionAudioCaptureEnabled(true)
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
        _ = await session.installModernAnalyzerInputStreamForTesting(bufferingCapacity: 2)

        await session.appendCapturedAudioBufferForTesting(try makeMono16KBuffer(samples: [0.1, 0.2]))
        await session.appendCapturedAudioBufferForTesting(try makeMono16KBuffer(samples: [0.3, 0.4]))
        let firstProvenance = RecognizedAudioProvenance(
            sourceToken: input.sourceToken,
            captureGeneration: input.generation,
            sampleInterval: 0..<2
        )
        let secondProvenance = RecognizedAudioProvenance(
            sourceToken: input.sourceToken,
            captureGeneration: input.generation,
            sampleInterval: 2..<4
        )
        let snapshot = ModernSpeechTextSnapshot(
            text: "中。次。",
            runs: [
                ModernSpeechTimedTextRun(utf16Range: 0..<2, audioProvenance: firstProvenance),
                ModernSpeechTimedTextRun(utf16Range: 2..<4, audioProvenance: secondProvenance)
            ]
        )

        #expect(firstProvenance.sourceToken == input.sourceToken)
        #expect(firstProvenance.captureGeneration == input.generation)
        #expect(await session.enqueueModernTimedCommittedEmissionForTesting(snapshot: snapshot, epoch: epoch))

        _ = await session.installModernAnalyzerInputStreamForTesting(bufferingCapacity: 1)
        await session.appendCapturedAudioBufferForTesting(try makeMono16KBuffer(samples: [0.5, 0.6]))
        await session.appendCapturedAudioBufferForTesting(try makeMono16KBuffer(samples: [0.7, 0.8]))
        #expect(
            await session.modernAudioProvenanceForTesting(sampleTimeRange(start: 0, duration: 2)) == nil
        )

        session.setCorrectionAudioCaptureEnabled(false)
        await session.deliverQueuedCommittedEmissionForTesting()

        #expect(recorder.texts == ["中。", "次。"])
        #expect(recorder.sentences.map(\.audioProvenance) == [firstProvenance, secondProvenance])
        #expect(recorder.receivedAudio == [false, false])
    }

    @Test @MainActor @available(macOS 26.0, *)
    func modernTimedPrefixContinuationDoesNotReuseWholePriorIntervalForTail() async throws {
        let session = LiveTranscriptionSession()
        let recorder = RecognizedSentenceRecorder()
        session.setTranscriptHandlerForTesting { recorder.record($0) }
        await session.beginRecognitionSessionForTesting()
        let input = try #require(await session.makeRealtimePCM16AudioInput())
        let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
        let knownPrefix = ModernSpeechTextSnapshot(
            text: "Known",
            runs: [ModernSpeechTimedTextRun(utf16Range: 0..<5, audioProvenance: nil)]
        )
        #expect(
            await session.enqueueModernTimedCommittedEmissionForTesting(snapshot: knownPrefix, epoch: epoch)
        )
        await session.deliverQueuedCommittedEmissionForTesting()

        let wholePriorInterval = RecognizedAudioProvenance(
            sourceToken: input.sourceToken,
            captureGeneration: input.generation,
            sampleInterval: 40..<80
        )
        let continuedText = ModernSpeechTextSnapshot(
            text: "Known new.",
            runs: [ModernSpeechTimedTextRun(utf16Range: 0..<10, audioProvenance: wholePriorInterval)]
        )
        let preparedTail = try #require(session.prepareModernTimedSentenceForTesting(continuedText))

        #expect(preparedTail.text == "new.")
        #expect(preparedTail.audioProvenance == nil)
        #expect(recorder.texts == ["Known"])
    }

    @Test func pendingModernPrefixStrippingKeepsOnlyTheExactTailInterval() async throws {
        let token = UUID()
        let firstProvenance = RecognizedAudioProvenance(
            sourceToken: token,
            captureGeneration: 24,
            sampleInterval: 0..<10
        )
        let tailProvenance = RecognizedAudioProvenance(
            sourceToken: token,
            captureGeneration: 24,
            sampleInterval: 10..<20
        )
        let snapshot = ModernSpeechTextSnapshot(
            text: "中。次。",
            runs: [
                ModernSpeechTimedTextRun(utf16Range: 0..<2, audioProvenance: firstProvenance),
                ModernSpeechTimedTextRun(utf16Range: 2..<4, audioProvenance: tailProvenance)
            ]
        )
        let pending = await LiveTranscriptionSession().pendingModernTextForTesting(
            snapshot,
            committedPrefixText: "中。"
        )

        #expect(pending.text == "次。")
        #expect(pending.audioProvenance == tailProvenance)
    }

    @Test func modernTimedTextRejectsMissingOverlappingAndStraddlingAudioRuns() throws {
        let token = UUID()
        let generation: UInt64 = 16
        let missing = ModernSpeechTextSnapshot(
            text: "First. Second.",
            runs: [
                ModernSpeechTimedTextRun(utf16Range: 0..<7, audioProvenance: nil),
                ModernSpeechTimedTextRun(
                    utf16Range: 7..<14,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 10..<20
                    )
                )
            ]
        )
        let overlap = ModernSpeechTextSnapshot(
            text: "First. Second.",
            runs: [
                ModernSpeechTimedTextRun(
                    utf16Range: 0..<7,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 0..<12
                    )
                ),
                ModernSpeechTimedTextRun(
                    utf16Range: 7..<14,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 8..<20
                    )
                )
            ]
        )
        let straddling = ModernSpeechTextSnapshot(
            text: "First. Second.",
            runs: [
                ModernSpeechTimedTextRun(
                    utf16Range: 0..<14,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 0..<30
                    )
                )
            ]
        )

        #expect(try #require(missing.slice(relativeUTF16Range: 0..<7)).audioProvenance == nil)
        #expect(try #require(overlap.slice(relativeUTF16Range: 0..<7)).audioProvenance == nil)
        #expect(try #require(overlap.slice(relativeUTF16Range: 7..<14)).audioProvenance == nil)
        #expect(try #require(straddling.slice(relativeUTF16Range: 0..<7)).audioProvenance == nil)
        #expect(try #require(straddling.slice(relativeUTF16Range: 7..<14)).audioProvenance == nil)
    }

    @Test func modernTimedTextRejectsAttributeRunsThatSplitAComposedGrapheme() throws {
        let token = UUID()
        let generation: UInt64 = 17
        let snapshot = ModernSpeechTextSnapshot(
            text: "e\u{301} word.",
            runs: [
                ModernSpeechTimedTextRun(
                    utf16Range: 0..<1,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 0..<4
                    )
                ),
                ModernSpeechTimedTextRun(
                    utf16Range: 1..<2,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 4..<8
                    )
                ),
                ModernSpeechTimedTextRun(
                    utf16Range: 2..<8,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: generation,
                        sampleInterval: 8..<20
                    )
                )
            ]
        )

        let ambiguousUnit = try #require(snapshot.slice(relativeUTF16Range: 0..<8))
        #expect(ambiguousUnit.text == "e\u{301} word.")
        #expect(ambiguousUnit.audioProvenance == nil)
    }

    @Test func modernTimedTextRejectsNegativeAndEmptySampleIntervalsWithoutDroppingText() throws {
        let token = UUID()
        let negative = ModernSpeechTextSnapshot(
            text: "A.",
            runs: [
                ModernSpeechTimedTextRun(
                    utf16Range: 0..<2,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: 20,
                        sampleInterval: -1..<1
                    )
                )
            ]
        )
        let empty = ModernSpeechTextSnapshot(
            text: "B.",
            runs: [
                ModernSpeechTimedTextRun(
                    utf16Range: 0..<2,
                    audioProvenance: RecognizedAudioProvenance(
                        sourceToken: token,
                        captureGeneration: 20,
                        sampleInterval: 5..<5
                    )
                )
            ]
        )

        let negativeUnit = try #require(negative.slice(relativeUTF16Range: 0..<2))
        let emptyUnit = try #require(empty.slice(relativeUTF16Range: 0..<2))
        #expect(negativeUnit.text == "A.")
        #expect(emptyUnit.text == "B.")
        #expect(negativeUnit.audioProvenance == nil)
        #expect(emptyUnit.audioProvenance == nil)
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

    @Test @MainActor @available(macOS 26.0, *)
    func deferredModernEmptyResultsCannotClearDraftAfterFallbackOrNewCapture() async {
        for resultKind in ["empty final", "empty nonfinal"] {
            for transition in ["fallback", "new capture"] {
                let session = LiveTranscriptionSession()
                await session.beginRecognitionSessionForTesting()
                let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
                #expect(await session.enqueueModernPartialDraftForTesting(nil, epoch: epoch))

                switch transition {
                case "fallback":
                    await session.fallbackSpeechAnalyzerToLegacyForTesting()
                default:
                    await session.beginRecognitionSessionForTesting()
                }

                var callbackCount = 0
                session.setPartialHandlerForTesting { _ in callbackCount += 1 }
                await session.deliverQueuedModernPartialDraftForTesting()
                #expect(callbackCount == 0, "\(resultKind) callback reached after \(transition)")
            }
        }

        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
        var acceptedClearCount = 0
        session.setPartialHandlerForTesting { draft in
            if draft == nil { acceptedClearCount += 1 }
        }
        #expect(await session.enqueueModernPartialDraftForTesting(nil, epoch: epoch))
        await session.deliverQueuedModernPartialDraftForTesting()
        #expect(acceptedClearCount == 1)
    }

    @Test @MainActor @available(macOS 26.0, *)
    func deferredModernDraftUpdateIsSuppressedAfterCaptureChanges() async {
        let session = LiveTranscriptionSession()
        await session.beginRecognitionSessionForTesting()
        let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
        let draft = DraftSegment(
            segmentId: UUID(),
            sourceText: "Old draft",
            stablePrefixLength: 3,
            mutableTailText: " draft",
            avgConfidence: 0.9,
            startMs: 0,
            lastUpdateMs: 1,
            silenceMs: 0,
            stabilityScore: 1,
            boundaryScore: 0.45,
            chunkScore: 0.8,
            vadProbability: 0.8,
            words: []
        )
        #expect(await session.enqueueModernPartialDraftForTesting(draft, epoch: epoch))

        await session.beginRecognitionSessionForTesting()
        var callbackCount = 0
        session.setPartialHandlerForTesting { _ in callbackCount += 1 }
        await session.deliverQueuedModernPartialDraftForTesting()
        #expect(callbackCount == 0)
    }

    @Test @MainActor @available(macOS 26.0, *)
    func deferredModernTimedEmissionIsSuppressedAfterFallbackStopOrNewCapture() async throws {
        for transition in ["fallback", "stop", "new capture"] {
            let session = LiveTranscriptionSession()
            let recorder = RecognizedSentenceRecorder()
            session.setTranscriptHandlerForTesting { recorder.record($0) }
            await session.beginRecognitionSessionForTesting()
            let input = try #require(await session.makeRealtimePCM16AudioInput())
            let epoch = await session.beginSpeechAnalyzerRecognitionForTesting()
            let provenance = RecognizedAudioProvenance(
                sourceToken: input.sourceToken,
                captureGeneration: input.generation,
                sampleInterval: 0..<10
            )
            let snapshot = ModernSpeechTextSnapshot(
                text: "Queued.",
                runs: [ModernSpeechTimedTextRun(utf16Range: 0..<7, audioProvenance: provenance)]
            )
            #expect(
                await session.enqueueModernTimedCommittedEmissionForTesting(snapshot: snapshot, epoch: epoch)
            )

            switch transition {
            case "fallback":
                await session.fallbackSpeechAnalyzerToLegacyForTesting()
            case "stop":
                await session.stopAndWait()
            default:
                await session.beginRecognitionSessionForTesting()
            }

            var partialClearCallbacks = 0
            session.setPartialHandlerForTesting { draft in
                if draft == nil { partialClearCallbacks += 1 }
            }
            await session.deliverQueuedCommittedEmissionForTesting(clearDraftAfter: true)
            #expect(recorder.texts.isEmpty)
            #expect(partialClearCallbacks == 0)
        }

        let acceptedSession = LiveTranscriptionSession()
        let acceptedRecorder = RecognizedSentenceRecorder()
        var acceptedPartialClearCallbacks = 0
        acceptedSession.setTranscriptHandlerForTesting { acceptedRecorder.record($0) }
        acceptedSession.setPartialHandlerForTesting { draft in
            if draft == nil { acceptedPartialClearCallbacks += 1 }
        }
        await acceptedSession.beginRecognitionSessionForTesting()
        let acceptedEpoch = await acceptedSession.beginSpeechAnalyzerRecognitionForTesting()
        let acceptedSnapshot = ModernSpeechTextSnapshot(text: "Accepted.", runs: [])
        #expect(
            await acceptedSession.enqueueModernTimedCommittedEmissionForTesting(
                snapshot: acceptedSnapshot,
                epoch: acceptedEpoch
            )
        )
        await acceptedSession.deliverQueuedCommittedEmissionForTesting(clearDraftAfter: true)
        #expect(acceptedRecorder.texts == ["Accepted."])
        #expect(acceptedPartialClearCallbacks == 1)
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

    private func sampleTimeRange(start: Int64, duration: Int64) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(value: start, timescale: 16_000),
            duration: CMTime(value: duration, timescale: 16_000)
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

    private func int16PCM16LittleEndianBytes(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.channelCount == 1,
              let samples = buffer.int16ChannelData?[0] else {
            throw TestError.unexpectedAudioBufferFormat
        }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private enum TestError: Error {
        case unexpectedAudioBufferFormat
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
