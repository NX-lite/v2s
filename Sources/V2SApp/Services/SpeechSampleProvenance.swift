import Foundation
import CoreMedia
import Speech

/// An interval on the normalized mono 16-kHz capture sample clock.
typealias NormalizedAudioSampleInterval = Range<Int64>

struct RecognizedAudioProvenance: Equatable, Sendable {
    let sourceToken: UUID
    let captureGeneration: UInt64
    let sampleInterval: NormalizedAudioSampleInterval
}

struct LegacySpeechSegmentTiming: Equatable, Sendable {
    let timestamp: TimeInterval
    let duration: TimeInterval
}

/// Advances only for normalized buffers that are actually published to the local
/// processing path. The range start is captured before an optional consumer is checked.
struct NormalizedAudioSampleClock: Sendable {
    private(set) var nextSampleIndex: Int64 = 0

    mutating func append(frameCount: Int) -> NormalizedAudioSampleInterval? {
        guard let count = Int64(exactly: frameCount), count > 0,
              nextSampleIndex <= Int64.max - count else {
            return nil
        }

        let interval = nextSampleIndex..<(nextSampleIndex + count)
        nextSampleIndex = interval.upperBound
        return interval
    }

    mutating func reset() {
        nextSampleIndex = 0
    }
}

enum NormalizedAudioFrameIdentity {
    static func preservesNormalizedSamples(
        captureInterval: NormalizedAudioSampleInterval,
        inputSampleRate: Double,
        inputChannelCount: Int,
        inputFrameCount: Int,
        outputSampleRate: Double,
        outputChannelCount: Int,
        outputFrameCount: Int,
        unchangedBufferObject: Bool
    ) -> Bool {
        guard unchangedBufferObject,
              inputSampleRate.isFinite,
              outputSampleRate.isFinite,
              inputSampleRate == 16_000,
              outputSampleRate == 16_000,
              inputChannelCount == 1,
              outputChannelCount == 1,
              captureInterval.lowerBound >= 0,
              captureInterval.upperBound > captureInterval.lowerBound,
              let inputFrames = Int64(exactly: inputFrameCount),
              let outputFrames = Int64(exactly: outputFrameCount),
              inputFrames > 0,
              inputFrames == outputFrames,
              captureInterval.upperBound - captureInterval.lowerBound == inputFrames else {
            return false
        }
        return true
    }
}

/// Maps the request-local timestamps emitted by legacy Speech back to the capture
/// sample clock, but only while every submitted buffer preserves its 16-kHz frames.
struct LegacyRecognitionSampleMapping: Sendable {
    private let sourceToken: UUID
    private let captureGeneration: UInt64
    private var captureAnchorSample: Int64?
    private var appendedRequestFrames: Int64 = 0
    private(set) var isValid = true

    init(sourceToken: UUID, captureGeneration: UInt64) {
        self.sourceToken = sourceToken
        self.captureGeneration = captureGeneration
    }

    @discardableResult
    mutating func append(
        captureInterval: NormalizedAudioSampleInterval,
        preserves16kFrameIdentity: Bool
    ) -> Bool {
        guard isValid,
              preserves16kFrameIdentity,
              captureInterval.lowerBound >= 0,
              captureInterval.upperBound > captureInterval.lowerBound else {
            invalidate()
            return false
        }

        let frameCount = captureInterval.upperBound - captureInterval.lowerBound
        if let captureAnchorSample {
            guard captureAnchorSample <= Int64.max - appendedRequestFrames,
                  captureInterval.lowerBound == captureAnchorSample + appendedRequestFrames else {
                invalidate()
                return false
            }
        } else {
            captureAnchorSample = captureInterval.lowerBound
        }

        guard appendedRequestFrames <= Int64.max - frameCount else {
            invalidate()
            return false
        }
        appendedRequestFrames += frameCount
        return true
    }

    mutating func invalidate() {
        isValid = false
    }

    func provenance(
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) -> RecognizedAudioProvenance? {
        guard isValid,
              let captureAnchorSample,
              startSeconds.isFinite,
              durationSeconds.isFinite,
              startSeconds >= 0,
              durationSeconds > 0 else {
            return nil
        }

        let endSeconds = startSeconds + durationSeconds
        let lowerSample = startSeconds * 16_000
        let upperSample = endSeconds * 16_000
        guard endSeconds.isFinite,
              lowerSample.isFinite,
              upperSample.isFinite,
              lowerSample >= 0,
              lowerSample < Double(Int64.max),
              upperSample < Double(Int64.max) else {
            return nil
        }

        let requestStart = Int64(lowerSample.rounded(.down))
        let requestEnd = Int64(upperSample.rounded(.up))
        guard requestStart >= 0,
              requestEnd > requestStart,
              requestEnd <= appendedRequestFrames,
              captureAnchorSample <= Int64.max - requestEnd else {
            return nil
        }

        return RecognizedAudioProvenance(
            sourceToken: sourceToken,
            captureGeneration: captureGeneration,
            sampleInterval: (captureAnchorSample + requestStart)..<(captureAnchorSample + requestEnd)
        )
    }

    func provenance(for segments: [LegacySpeechSegmentTiming]) -> RecognizedAudioProvenance? {
        guard isValid, let first = segments.first, let last = segments.last else {
            return nil
        }

        var previousEnd = first.timestamp
        for (index, segment) in segments.enumerated() {
            let end = segment.timestamp + segment.duration
            guard segment.timestamp.isFinite,
                  segment.duration.isFinite,
                  segment.timestamp >= 0,
                  segment.duration > 0,
                  end.isFinite,
                  end > segment.timestamp,
                  index == 0 || segment.timestamp >= previousEnd else {
                return nil
            }
            previousEnd = end
        }

        let sentenceEnd = last.timestamp + last.duration
        return provenance(
            startSeconds: first.timestamp,
            durationSeconds: sentenceEnd - first.timestamp
        )
    }
}

enum ModernAnalyzerInputDeliveryOutcome: Sendable {
    case enqueued
    case dropped
    case terminated
}

/// Carries only the facts synthetic analyzer-input tests need to inspect. The
/// production path still yields Apple's `AnalyzerInput` through the same decision
/// closure below.
struct ModernAnalyzerInputSummary: Equatable, Sendable {
    let frameCount: Int
    let sampleRate: Double
    let isInt16PCM: Bool
    let isInterleaved: Bool
    let bufferStartTime: CMTime?
}

enum ModernAnalyzerInputAppender {
    /// Adds one buffer to the capture mapping, yields it with a timestamp only when
    /// sample identity is proven, then invalidates the epoch if the bounded stream
    /// dropped or terminated the input. Production and synthetic streams share this
    /// exact ordering and decision.
    @discardableResult
    static func appendAndDeliver(
        mapping: inout ModernRecognitionSampleMapping?,
        captureSampleInterval: NormalizedAudioSampleInterval?,
        inputSampleRate: Double,
        inputChannelCount: Int,
        inputFrameCount: Int,
        outputSampleRate: Double,
        outputChannelCount: Int,
        outputFrameCount: Int,
        unchangedBufferObject: Bool,
        deliver: (CMTime?) -> ModernAnalyzerInputDeliveryOutcome
    ) -> CMTime? {
        let preservesFrameIdentity = captureSampleInterval.map { interval in
            NormalizedAudioFrameIdentity.preservesNormalizedSamples(
                captureInterval: interval,
                inputSampleRate: inputSampleRate,
                inputChannelCount: inputChannelCount,
                inputFrameCount: inputFrameCount,
                outputSampleRate: outputSampleRate,
                outputChannelCount: outputChannelCount,
                outputFrameCount: outputFrameCount,
                unchangedBufferObject: unchangedBufferObject
            )
        } ?? false

        let hasSampleMapping: Bool
        if let captureSampleInterval {
            hasSampleMapping = mapping?.appendBuffer(
                captureInterval: captureSampleInterval,
                outputSampleRate: outputSampleRate,
                outputFrameCount: outputFrameCount,
                preservesFrameIdentity: preservesFrameIdentity
            ) ?? false
        } else {
            mapping?.invalidate()
            hasSampleMapping = false
        }

        let bufferStartTime = hasSampleMapping
            ? CMTime(value: captureSampleInterval?.lowerBound ?? 0, timescale: 16_000)
            : nil
        let deliveryOutcome = deliver(bufferStartTime)
        mapping?.recordDelivery(deliveryOutcome)
        return bufferStartTime
    }
}

struct ModernRecognitionSampleMapping: Sendable {
    private let sourceToken: UUID
    private let captureGeneration: UInt64
    private(set) var isValid = true
    private var firstCaptureSample: Int64?
    private var lastCaptureSample: Int64?

    init(sourceToken: UUID, captureGeneration: UInt64) {
        self.sourceToken = sourceToken
        self.captureGeneration = captureGeneration
    }

    mutating func appendBuffer(
        captureInterval: NormalizedAudioSampleInterval,
        outputSampleRate: Double,
        outputFrameCount: Int,
        preservesFrameIdentity: Bool
    ) -> Bool {
        guard isValid,
              preservesFrameIdentity,
              outputSampleRate.isFinite,
              outputSampleRate == 16_000,
              captureInterval.lowerBound >= 0,
              captureInterval.upperBound > captureInterval.lowerBound,
              let frameCount = Int64(exactly: outputFrameCount),
              frameCount > 0,
              captureInterval.upperBound - captureInterval.lowerBound == frameCount,
              lastCaptureSample.map({ $0 == captureInterval.lowerBound }) ?? true else {
            invalidate()
            return false
        }

        if firstCaptureSample == nil {
            firstCaptureSample = captureInterval.lowerBound
        }
        lastCaptureSample = captureInterval.upperBound
        return true
    }

    mutating func recordDelivery(_ outcome: ModernAnalyzerInputDeliveryOutcome) {
        guard case .enqueued = outcome else {
            invalidate()
            return
        }
    }

    func provenance(for timeRange: CMTimeRange) -> RecognizedAudioProvenance? {
        guard isValid,
              let firstCaptureSample,
              let lastCaptureSample,
              timeRange.isValid,
              timeRange.start.isNumeric,
              timeRange.duration.isNumeric,
              timeRange.start.epoch == 0,
              timeRange.duration.epoch == 0,
              CMTimeCompare(timeRange.start, .zero) >= 0,
              CMTimeCompare(timeRange.duration, .zero) > 0 else {
            return nil
        }

        let end = CMTimeAdd(timeRange.start, timeRange.duration)
        guard end.isNumeric,
              end.epoch == 0,
              CMTimeCompare(end, timeRange.start) > 0,
              let lowerSample = exactNormalizedSampleIndex(for: timeRange.start),
              let upperSample = exactNormalizedSampleIndex(for: end),
              lowerSample >= firstCaptureSample,
              upperSample <= lastCaptureSample,
              upperSample > lowerSample else {
            return nil
        }

        return RecognizedAudioProvenance(
            sourceToken: sourceToken,
            captureGeneration: captureGeneration,
            sampleInterval: lowerSample..<upperSample
        )
    }

    mutating func invalidate() {
        isValid = false
    }

    private func exactNormalizedSampleIndex(for time: CMTime) -> Int64? {
        guard time.isNumeric else { return nil }
        let scaled = CMTimeConvertScale(time, timescale: 16_000, method: .roundTowardZero)
        guard
              scaled.isNumeric,
              CMTimeCompare(scaled, time) == 0 else {
            return nil
        }
        return scaled.value
    }
}

struct ModernSpeechTimedTextRun: Equatable, Sendable {
    let utf16Range: Range<Int>
    let audioProvenance: RecognizedAudioProvenance?
}

struct ModernSpeechTextSnapshot: Equatable, Sendable {
    private let backingText: String
    private let selectedRange: Range<Int>
    private let runs: [ModernSpeechTimedTextRun]
    private let graphemeBoundaries: Set<Int>
    private let scalarBoundaries: Set<Int>

    init(text: String, runs: [ModernSpeechTimedTextRun]) {
        let normalizedText = text.replacingOccurrences(of: "\n", with: " ")
        backingText = normalizedText
        self.runs = runs
        graphemeBoundaries = Self.boundaries(in: normalizedText, by: \.utf16.count)
        scalarBoundaries = Self.boundaries(in: normalizedText.unicodeScalars, by: \.utf16.count)
        selectedRange = Self.trimmedUTF16Range(in: normalizedText, from: 0..<normalizedText.utf16.count)
    }

    @available(macOS 26.0, *)
    init(attributedText: AttributedString, mapping: ModernRecognitionSampleMapping?) {
        let scalars = attributedText.unicodeScalars
        let sourceText = String(attributedText.characters)
        var timedRuns: [ModernSpeechTimedTextRun] = []
        timedRuns.reserveCapacity(attributedText.runs.count)
        var lowerBound = 0

        for run in attributedText.runs {
            let upperBound = lowerBound + Self.utf16Length(of: scalars[run.range])
            let provenance = run.audioTimeRange.flatMap { mapping?.provenance(for: $0) }
            timedRuns.append(
                ModernSpeechTimedTextRun(
                    utf16Range: lowerBound..<upperBound,
                    audioProvenance: provenance
                )
            )
            lowerBound = upperBound
        }

        self.init(text: sourceText, runs: timedRuns)
    }

    private init(
        backingText: String,
        selectedRange: Range<Int>,
        runs: [ModernSpeechTimedTextRun],
        graphemeBoundaries: Set<Int>,
        scalarBoundaries: Set<Int>
    ) {
        self.backingText = backingText
        self.selectedRange = selectedRange
        self.runs = runs
        self.graphemeBoundaries = graphemeBoundaries
        self.scalarBoundaries = scalarBoundaries
    }

    var text: String {
        substring(in: selectedRange)
    }

    var utf16Count: Int {
        selectedRange.upperBound - selectedRange.lowerBound
    }

    func slice(relativeUTF16Range: Range<Int>) -> ModernSpeechTextSnapshot? {
        guard relativeUTF16Range.lowerBound >= 0,
              relativeUTF16Range.upperBound >= relativeUTF16Range.lowerBound,
              relativeUTF16Range.upperBound <= utf16Count else {
            return nil
        }

        let absoluteLowerBound = selectedRange.lowerBound + relativeUTF16Range.lowerBound
        let absoluteUpperBound = selectedRange.lowerBound + relativeUTF16Range.upperBound
        let absoluteRange = absoluteLowerBound..<absoluteUpperBound
        guard scalarBoundaries.contains(absoluteRange.lowerBound),
              scalarBoundaries.contains(absoluteRange.upperBound) else {
            return nil
        }

        return ModernSpeechTextSnapshot(
            backingText: backingText,
            selectedRange: absoluteRange,
            runs: runs,
            graphemeBoundaries: graphemeBoundaries,
            scalarBoundaries: scalarBoundaries
        )
    }

    func trimmingWhitespace() -> ModernSpeechTextSnapshot? {
        let trimmedRange = Self.trimmedUTF16Range(in: text, from: 0..<utf16Count)
        return slice(relativeUTF16Range: trimmedRange)
    }

    var audioProvenance: RecognizedAudioProvenance? {
        provenance(for: 0..<utf16Count)
    }

    func provenance(for relativeUTF16Range: Range<Int>) -> RecognizedAudioProvenance? {
        guard relativeUTF16Range.lowerBound >= 0,
              relativeUTF16Range.upperBound > relativeUTF16Range.lowerBound,
              relativeUTF16Range.upperBound <= utf16Count else {
            return nil
        }

        let lowerBound = selectedRange.lowerBound + relativeUTF16Range.lowerBound
        let upperBound = selectedRange.lowerBound + relativeUTF16Range.upperBound
        let range = lowerBound..<upperBound
        guard graphemeBoundaries.contains(range.lowerBound),
              graphemeBoundaries.contains(range.upperBound) else {
            return nil
        }

        let indexedRuns = runs.enumerated().filter { _, run in
            run.utf16Range.lowerBound < range.upperBound
                && range.lowerBound < run.utf16Range.upperBound
        }
        guard indexedRuns.isEmpty == false else {
            return nil
        }

        var cursor = range.lowerBound
        var firstProvenance: RecognizedAudioProvenance?
        var previousProvenance: RecognizedAudioProvenance?
        var lastProvenance: RecognizedAudioProvenance?
        var usedRunIndices = Set<Int>()

        for (index, run) in indexedRuns {
            guard run.utf16Range.lowerBound >= range.lowerBound,
                  run.utf16Range.upperBound <= range.upperBound,
                  run.utf16Range.lowerBound == cursor,
                  graphemeBoundaries.contains(run.utf16Range.lowerBound),
                  graphemeBoundaries.contains(run.utf16Range.upperBound),
                  let provenance = run.audioProvenance,
                  provenance.sampleInterval.lowerBound >= 0,
                  provenance.sampleInterval.upperBound > provenance.sampleInterval.lowerBound else {
                return nil
            }

            if let previousProvenance {
                guard provenance.sourceToken == previousProvenance.sourceToken,
                      provenance.captureGeneration == previousProvenance.captureGeneration,
                      provenance.sampleInterval.lowerBound >= previousProvenance.sampleInterval.upperBound else {
                    return nil
                }
            } else {
                firstProvenance = provenance
            }

            usedRunIndices.insert(index)
            previousProvenance = provenance
            lastProvenance = provenance
            cursor = run.utf16Range.upperBound
        }

        guard cursor == range.upperBound,
              let firstProvenance,
              let lastProvenance else {
            return nil
        }

        let combinedInterval = firstProvenance.sampleInterval.lowerBound..<lastProvenance.sampleInterval.upperBound
        for (index, run) in runs.enumerated() where usedRunIndices.contains(index) == false {
            guard let other = run.audioProvenance else { continue }
            guard other.sampleInterval.lowerBound >= 0,
                  other.sampleInterval.upperBound > other.sampleInterval.lowerBound else {
                return nil
            }
            if other.sampleInterval.lowerBound < combinedInterval.upperBound,
               combinedInterval.lowerBound < other.sampleInterval.upperBound {
                return nil
            }
        }

        return RecognizedAudioProvenance(
            sourceToken: firstProvenance.sourceToken,
            captureGeneration: firstProvenance.captureGeneration,
            sampleInterval: combinedInterval
        )
    }

    private func substring(in range: Range<Int>) -> String {
        (backingText as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
        )
    }

    private static func boundaries<C: Collection>(in collection: C, by length: (C.Element) -> Int) -> Set<Int> {
        var offsets: Set<Int> = [0]
        var offset = 0
        for element in collection {
            offset += length(element)
            offsets.insert(offset)
        }
        return offsets
    }

    private static func trimmedUTF16Range(in text: String, from range: Range<Int>) -> Range<Int> {
        let selectedText = (text as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
        )
        var leadingUTF16Count = 0
        for scalar in selectedText.unicodeScalars {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            leadingUTF16Count += scalar.utf16.count
        }

        var trailingUTF16Count = 0
        for scalar in selectedText.unicodeScalars.reversed() {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            trailingUTF16Count += scalar.utf16.count
        }

        let lowerBound = range.lowerBound + leadingUTF16Count
        let upperBound = max(lowerBound, range.upperBound - trailingUTF16Count)
        return lowerBound..<upperBound
    }

    @available(macOS 26.0, *)
    private static func utf16Length<S: Sequence>(of scalars: S) -> Int where S.Element == Unicode.Scalar {
        scalars.reduce(into: 0) { length, scalar in
            length += scalar.value > 0xFFFF ? 2 : 1
        }
    }
}
