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

    @Test func capacityKeepsNewestTwoSeconds() throws {
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

    @Test func appendPCMBufferRejectsMismatchedRateAndStereoInput() throws {
        let mismatchedRateFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 8,
            channels: 1,
            interleaved: false
        ))
        let mismatchedRateBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: mismatchedRateFormat,
            frameCapacity: 1
        ))
        mismatchedRateBuffer.frameLength = 1
        let mismatchedRateData = try #require(mismatchedRateBuffer.floatChannelData?[0])
        mismatchedRateData[0] = 1

        let stereoFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 4,
            channels: 2,
            interleaved: false
        ))
        let stereoBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: stereoFormat,
            frameCapacity: 1
        ))
        stereoBuffer.frameLength = 1
        let stereoData = try #require(stereoBuffer.floatChannelData?[0])
        stereoData[0] = 1

        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(mismatchedRateBuffer)
        buffer.append(stereoBuffer)

        #expect(buffer.frameCount == 0)
    }

    @Test func appendPCMBufferAcceptsMatchingMonoInterleavedFrames() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 4,
            channels: 1,
            interleaved: true
        ))
        let pcmBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 3
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

        #expect(wav.littleEndianInt16(at: 44) == .min)
        #expect(wav.littleEndianInt16(at: 46) == 0)
        #expect(wav.littleEndianInt16(at: 48) == .max)
    }

    @Test func appendPCMBufferPreservesInt16EndpointsAndRepresentativeSamples() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 4,
            channels: 1,
            interleaved: false
        ))
        let pcmBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 5
        ))
        pcmBuffer.frameLength = 5
        let channel = try #require(pcmBuffer.int16ChannelData?[0])
        channel[0] = .min
        channel[1] = -8_192
        channel[2] = 0
        channel[3] = 8_192
        channel[4] = .max

        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(pcmBuffer)

        let finished = buffer.finish()
        let wav = try #require(finished)

        #expect(wav.littleEndianInt16(at: 44) == .min)
        #expect(wav.littleEndianInt16(at: 46) == -8_192)
        #expect(wav.littleEndianInt16(at: 48) == 0)
        #expect(wav.littleEndianInt16(at: 50) == 8_192)
        #expect(wav.littleEndianInt16(at: 52) == .max)
    }

    @Test func repeatedSmallFinishesAndEvictionsKeepActiveStorageBounded() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 1)
        let frames: [Float] = [0, 0.25, 0.5, 0.75, 1, -1]

        for cycle in 0..<64 {
            buffer.append(samples: frames)

            let absoluteTime = Double((cycle + 1) * frames.count - 2) / 4
            let finished = buffer.finish(through: absoluteTime)
            let wav = try #require(finished)

            #expect(wav.littleEndianInt16(at: 44) == 16_384)
            #expect(wav.littleEndianInt16(at: 46) == 24_575)
            #expect(buffer.frameCount == 2)
        }

        #expect(buffer.samples.count <= 8)

        let completedTail = buffer.finish()
        let tail = try #require(completedTail)

        #expect(tail.littleEndianInt16(at: 44) == .max)
        #expect(tail.littleEndianInt16(at: 46) == .min)
    }

    @Test func invalidConfigurationDropsFramesWithoutEncoding() throws {
        let configurations: [(Int, TimeInterval)] = [
            (0, 1),
            (-1, 1),
            (4, -1),
            (4, .infinity),
            (4, .nan),
            (Int(UInt32.max / 2) + 1, 1),
        ]

        for (sampleRate, maximumDuration) in configurations {
            var buffer = SentenceAudioBuffer(
                sampleRate: sampleRate,
                maximumDuration: maximumDuration
            )
            buffer.append(samples: [0])

            try #require(buffer.frameCount == 0)
            let finished = buffer.finish()
            #expect(finished == nil)
        }
    }

    @Test func backwardAndNonfiniteFinishTimesKeepRemainingFrames() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(samples: [0, 0.25, 0.5, 0.75])

        let initial = buffer.finish(through: 0.5)
        _ = try #require(initial)

        let backward = buffer.finish(through: 0.25)
        let notANumber = buffer.finish(through: .nan)
        let infinity = buffer.finish(through: .infinity)

        #expect(backward == nil)
        #expect(notANumber == nil)
        #expect(infinity == nil)
        #expect(buffer.frameCount == 2)
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
