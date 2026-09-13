import AVFoundation
import Foundation

struct SentenceAudioBuffer {
    let sampleRate: Int
    let maximumDuration: TimeInterval
    private(set) var samples: [Float] = []
    private var emittedFrameCount = 0

    var frameCount: Int { samples.count }

    mutating func append(samples newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        samples.append(contentsOf: newSamples)
        discardExcessFrames()
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

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
            prefixFrameCount = min(samples.count, max(0, absoluteFrameIndex - emittedFrameCount))
        } else {
            prefixFrameCount = samples.count
        }

        guard prefixFrameCount > 0 else { return nil }

        let prefix = samples.prefix(prefixFrameCount)
        samples.removeFirst(prefixFrameCount)
        advanceCursor(by: prefixFrameCount)
        return wavData(for: prefix)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        emittedFrameCount = 0
    }

    private var maximumFrameCount: Int {
        guard sampleRate > 0, maximumDuration.isFinite, maximumDuration > 0 else {
            return 0
        }

        let frameCount = Double(sampleRate) * maximumDuration
        guard frameCount < Double(Int.max) else { return Int.max }
        return Int(frameCount.rounded(.down))
    }

    private mutating func discardExcessFrames() {
        let excessFrameCount = samples.count - maximumFrameCount
        guard excessFrameCount > 0 else { return }

        samples.removeFirst(excessFrameCount)
        advanceCursor(by: excessFrameCount)
    }

    private mutating func advanceCursor(by frameCount: Int) {
        emittedFrameCount = emittedFrameCount > Int.max - frameCount
            ? Int.max
            : emittedFrameCount + frameCount
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
        let payloadByteCount = frames.count * MemoryLayout<Int16>.size
        var wav = Data(capacity: 44 + payloadByteCount)

        wav.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + payloadByteCount), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(sampleRate), to: &wav)
        appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &wav)
        appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(payloadByteCount), to: &wav)

        for frame in frames {
            appendLittleEndian(UInt16(bitPattern: pcm16(frame)), to: &wav)
        }

        return wav
    }

    private func pcm16(_ sample: Float) -> Int16 {
        if sample <= -1 { return .min }
        if sample >= 1 { return .max }
        guard sample.isFinite else { return 0 }
        return Int16((sample * Float(Int16.max)).rounded())
    }

    private func normalized(_ sample: Int64, maximumMagnitude: Int64) -> Float {
        Float(sample) / Float(maximumMagnitude)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
