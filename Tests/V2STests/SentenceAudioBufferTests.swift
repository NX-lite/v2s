import AVFoundation
import Foundation
import Testing
@testable import v2s

@Suite struct SentenceAudioBufferTests {
    @Test func finishEncodesMono16KPCM16WAVAndClearsFrames() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 16_000, maximumDuration: 15)
        buffer.append(samples: [-1, 0, 0.5, 1])

        let finished = buffer.finish()
        let wav = try #require(finished)

        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(wav.littleEndianUInt32(at: 4) == UInt32(wav.count - 8))
        #expect(wav.littleEndianUInt32(at: 16) == 16)
        #expect(wav.littleEndianUInt16(at: 20) == 1)
        #expect(wav.littleEndianUInt16(at: 22) == 1)
        #expect(wav.littleEndianUInt32(at: 24) == 16_000)
        #expect(wav.littleEndianUInt32(at: 28) == 32_000)
        #expect(wav.littleEndianUInt16(at: 32) == 2)
        #expect(wav.littleEndianUInt16(at: 34) == 16)
        #expect(wav.littleEndianUInt32(at: 40) == UInt32(wav.count - 44))
        #expect(buffer.frameCount == 0)
    }

    @Test func capacityKeepsNewestFifteenSeconds() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 2)
        buffer.append(samples: [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25])

        #expect(buffer.frameCount == 8)

        let finished = buffer.finish(through: 2)
        let prefix = try #require(finished)

        #expect(prefix.littleEndianInt16(at: 44) == 0)
        #expect(prefix.littleEndianInt16(at: 46) == 8_192)
        #expect(prefix.littleEndianInt16(at: 48) == 16_384)
        #expect(prefix.littleEndianInt16(at: 50) == 24_575)
        #expect(buffer.frameCount == 4)

        let completedTail = buffer.finish()
        let tail = try #require(completedTail)

        #expect(tail.littleEndianInt16(at: 44) == .max)
        #expect(tail.littleEndianInt16(at: 46) == 24_575)
        #expect(tail.littleEndianInt16(at: 48) == 16_384)
        #expect(tail.littleEndianInt16(at: 50) == 8_192)
    }

    @Test func consumeThroughTimeReturnsPrefixAndKeepsTail() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(samples: [0, 0.1, 0.2, 0.3, 0.4, 0.5])

        let finished = buffer.finish(through: 1.0)
        let first = try #require(finished)

        #expect(first.count == 52)
        #expect(buffer.frameCount == 2)
    }

    @Test func emptyFinishReturnsNil() {
        var buffer = SentenceAudioBuffer(sampleRate: 16_000, maximumDuration: 15)

        #expect(buffer.finish() == nil)
    }

    @Test func finishClampsSamplesToSignedPCM16() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(samples: [-2, -1, 0, 0.5, 1, 2])

        let finished = buffer.finish()
        let wav = try #require(finished)

        #expect(wav.littleEndianUInt16(at: 44) == UInt16(bitPattern: Int16.min))
        #expect(wav.littleEndianUInt16(at: 46) == UInt16(bitPattern: Int16.min))
        #expect(wav.littleEndianUInt16(at: 48) == 0)
        #expect(wav.littleEndianUInt16(at: 50) == UInt16(bitPattern: 16_384))
        #expect(wav.littleEndianUInt16(at: 52) == UInt16(bitPattern: Int16.max))
        #expect(wav.littleEndianUInt16(at: 54) == UInt16(bitPattern: Int16.max))
    }

    @Test func resetClearsFramesAndRestartsAbsoluteCursor() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(samples: Array(repeating: 0.1, count: 6))
        _ = buffer.finish(through: 1)
        buffer.reset()
        buffer.append(samples: Array(repeating: 0.2, count: 4))

        let finished = buffer.finish(through: 0.5)
        let first = try #require(finished)

        #expect(first.count == 48)
        #expect(buffer.frameCount == 2)
    }

    @Test func appendPCMBufferReadsAvailableFloatFrames() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 4,
            channels: 1,
            interleaved: false
        ))
        let pcmBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        pcmBuffer.frameLength = 3
        let channel = try #require(pcmBuffer.floatChannelData?[0])
        channel[0] = -1
        channel[1] = 0
        channel[2] = 1

        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(pcmBuffer)

        let finished = buffer.finish()
        let wav = try #require(finished)

        #expect(buffer.frameCount == 0)
        #expect(wav.littleEndianUInt16(at: 44) == UInt16(bitPattern: Int16.min))
        #expect(wav.littleEndianUInt16(at: 46) == 0)
        #expect(wav.littleEndianUInt16(at: 48) == UInt16(bitPattern: Int16.max))
    }
}

private extension Data {
    func littleEndianInt16(at offset: Int) -> Int16 {
        Int16(bitPattern: littleEndianUInt16(at: offset))
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
