import AVFoundation
import Foundation
import Testing
@testable import v2s

@Suite struct SileroVADEngineTests {
    private static let chunkSize = 512
    private static let sampleRate = 16_000.0
    // Captured from the pinned Silero v5 reference with each 512-sample chunk
    // preceded by its 64-sample context and one combined [2, 1, 128] recurrent
    // state. These fixed goldens are not produced by a live ONNX comparison.
    // The 1e-4 tolerance accommodates Core ML backend rounding while remaining
    // tight enough to catch context or recurrent-state contract regressions.
    private static let goldenProbabilities: [Float] = [
        0.334451973,
        0.43982628,
        0.219400823,
        0.0712271631,
        0.0301993787,
        0.0113633275,
        0.00926747918,
        0.00593075156,
        0.00619235635,
        0.00379472971,
        0.00467684865,
        0.0031940639,
    ]

    @Test func packagedModelMatchesGoldenSequenceAfterReset() throws {
        let engine = try SileroVADEngine()
        // This first run starts immediately after init, so it also verifies that
        // prewarming did not carry context or recurrent state into production.
        let firstRun = try processGoldenSequence(with: engine)
        assertGoldenSequence(firstRun, sourceLocation: #_sourceLocation)

        engine.reset()

        let secondRun = try processGoldenSequence(with: engine)
        assertGoldenSequence(secondRun, sourceLocation: #_sourceLocation)

        for index in Self.goldenProbabilities.indices {
            #expect(
                abs(secondRun[index].speechProbability - firstRun[index].speechProbability) <= 1e-6,
                "Reset run differs at chunk \(index)"
            )
        }
    }

    private func processGoldenSequence(with engine: SileroVADEngine) throws -> [VADResult] {
        try Self.goldenProbabilities.indices.map { chunkIndex in
            engine.process(buffer: try makeBuffer(chunkIndex: chunkIndex))
        }
    }

    private func assertGoldenSequence(
        _ results: [VADResult],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(results.count == Self.goldenProbabilities.count, sourceLocation: sourceLocation)

        for (index, result) in results.enumerated() {
            #expect(
                abs(result.speechProbability - Self.goldenProbabilities[index]) <= 1e-4,
                "Unexpected probability at chunk \(index)",
                sourceLocation: sourceLocation
            )
            #expect(!result.containsSpeechOnset, "Unexpected speech onset at chunk \(index)", sourceLocation: sourceLocation)
            #expect(!result.containsSpeechOffset, "Unexpected speech offset at chunk \(index)", sourceLocation: sourceLocation)
            #expect(!result.isSpeech, "Hysteresis entered speech at chunk \(index)", sourceLocation: sourceLocation)
        }
    }

    private func makeBuffer(chunkIndex: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Self.chunkSize)
        ))
        buffer.frameLength = AVAudioFrameCount(Self.chunkSize)

        let channelData = try #require(buffer.floatChannelData)
        let channel = channelData[0]
        let firstSample = chunkIndex * Self.chunkSize

        for index in 0..<Self.chunkSize {
            let time = Double(firstSample + index) / Self.sampleRate
            let fundamental = sin(2.0 * Double.pi * 140.0 * time)
            let harmonic = 0.4 * sin(2.0 * Double.pi * 280.0 * time)
            channel[index] = Float(0.08 * (fundamental + harmonic))
        }

        return buffer
    }
}
