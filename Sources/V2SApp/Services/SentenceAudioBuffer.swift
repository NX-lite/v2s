import AVFoundation
import Foundation

struct SentenceAudioBuffer {
    let sampleRate: Int
    let maximumDuration: TimeInterval
    private(set) var samples: [Float] = []
    private var sampleStartIndex = 0
    private var emittedFrameCount = 0

    var frameCount: Int { samples.count - sampleStartIndex }

    mutating func append(samples newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        samples.append(contentsOf: newSamples)
        discardExcessFrames()
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0,
              channelCount == 1,
              buffer.format.sampleRate == Double(sampleRate) else {
            return
        }

        let stride = buffer.format.isInterleaved ? channelCount : 1

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return }
            append(samples: (0..<frameCount).map { channelData[0][$0 * stride] })
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return }
            append(samples: (0..<frameCount).map {
                normalized(Int64(channelData[0][$0 * stride]), maximumMagnitude: 32_768)
            })
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return }
            append(samples: (0..<frameCount).map {
                normalized(Int64(channelData[0][$0 * stride]), maximumMagnitude: 2_147_483_648)
            })
        default:
            return
        }
    }

    mutating func finish(through absoluteTime: TimeInterval? = nil) -> Data? {
        let prefixFrameCount: Int
        if let absoluteTime {
            let absoluteFrameIndex = frameIndex(at: absoluteTime)
            prefixFrameCount = min(frameCount, max(0, absoluteFrameIndex - emittedFrameCount))
        } else {
            prefixFrameCount = frameCount
        }

        guard prefixFrameCount > 0 else { return nil }

        let endIndex = sampleStartIndex + prefixFrameCount
        let prefix = samples[sampleStartIndex..<endIndex]
        let wav = wavData(for: prefix)
        sampleStartIndex = endIndex
        advanceCursor(by: prefixFrameCount)
        compactStorageIfNeeded()
        return wav
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleStartIndex = 0
        emittedFrameCount = 0
    }

    private var maximumFrameCount: Int {
        guard sampleRate > 0,
              sampleRate <= Self.maximumSampleRate,
              maximumDuration.isFinite,
              maximumDuration > 0 else {
            return 0
        }

        let frameCount = Double(sampleRate) * maximumDuration
        guard frameCount.isFinite else { return Self.maximumWAVFrameCount }
        guard frameCount < Double(Self.maximumWAVFrameCount) else {
            return Self.maximumWAVFrameCount
        }
        return Int(frameCount.rounded(.down))
    }

    private mutating func discardExcessFrames() {
        let excessFrameCount = frameCount - maximumFrameCount
        guard excessFrameCount > 0 else { return }

        sampleStartIndex += excessFrameCount
        advanceCursor(by: excessFrameCount)
        compactStorageIfNeeded()
    }

    private mutating func advanceCursor(by frameCount: Int) {
        emittedFrameCount = emittedFrameCount > Int.max - frameCount
            ? Int.max
            : emittedFrameCount + frameCount
    }

    private mutating func compactStorageIfNeeded() {
        guard sampleStartIndex > 0,
              sampleStartIndex >= samples.count - sampleStartIndex else {
            return
        }

        samples.removeFirst(sampleStartIndex)
        sampleStartIndex = 0
    }

    private func frameIndex(at absoluteTime: TimeInterval) -> Int {
        guard absoluteTime.isFinite, absoluteTime > 0, sampleRate > 0 else {
            return 0
        }

        let frameIndex = absoluteTime * Double(sampleRate)
        guard frameIndex < Double(Int.max) else { return Int.max }
        return Int(frameIndex.rounded(.down))
    }

    private func wavData(for frames: ArraySlice<Float>) -> Data {
        let frameCount = min(frames.count, Self.maximumWAVFrameCount)
        let payloadByteCount = frameCount * Self.wavBytesPerFrame
        var wav = Data(capacity: 44 + payloadByteCount)

        wav.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(clamping: 36 + payloadByteCount), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        let wavSampleRate = UInt32(clamping: sampleRate)
        appendLittleEndian(wavSampleRate, to: &wav)
        appendLittleEndian(wavSampleRate * UInt32(Self.wavBytesPerFrame), to: &wav)
        appendLittleEndian(UInt16(Self.wavBytesPerFrame), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(clamping: payloadByteCount), to: &wav)

        for frame in frames.prefix(frameCount) {
            appendLittleEndian(UInt16(bitPattern: pcm16(frame)), to: &wav)
        }

        return wav
    }

    private func pcm16(_ sample: Float) -> Int16 {
        if sample <= -1 { return .min }
        if sample >= 1 { return .max }
        guard sample.isFinite else { return 0 }
        let scale = sample < 0 ? Float(Int16.max) + 1 : Float(Int16.max)
        return Int16((sample * scale).rounded())
    }

    private func normalized(_ sample: Int64, maximumMagnitude: Int64) -> Float {
        let denominator = sample < 0 ? maximumMagnitude : maximumMagnitude - 1
        return Float(sample) / Float(denominator)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static let wavBytesPerFrame = MemoryLayout<Int16>.size
    private static let maximumSampleRate = Int(UInt32.max / UInt32(wavBytesPerFrame))
    private static let maximumWAVFrameCount = (Int(UInt32.max) - 36) / wavBytesPerFrame
}
