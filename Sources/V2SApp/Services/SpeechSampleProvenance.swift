import Foundation

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
