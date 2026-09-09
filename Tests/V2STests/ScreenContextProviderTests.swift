import Foundation
import Testing
@testable import v2s

@Suite struct ScreenContextProviderTests {
    @Test func capturedImageAndRecognizedTextArePreserved() async {
        let image = Data([0x01, 0x02, 0x03])
        let capture = CaptureFake(outcome: .captured(image))
        let recognizer = RecognizerFake(result: "Screen title")
        let context = await ScreenContextProvider(capture: capture, recognizer: recognizer).current()

        #expect(context.pngData == image)
        #expect(context.ocrText == "Screen title")
        #expect(context.status == .ready)
        #expect(await recognizer.receivedData == image)
    }

    @Test func capturedImageIsPreservedWhenOCRFails() async {
        let image = Data([0x04, 0x05, 0x06])
        let capture = CaptureFake(outcome: .captured(image))
        let recognizer = RecognizerFake(result: nil)
        let context = await ScreenContextProvider(capture: capture, recognizer: recognizer).current()

        #expect(context.pngData == image)
        #expect(context.ocrText == nil)
        #expect(context.status == .ocrFailed)
        #expect(await recognizer.receivedData == image)
    }

    @Test func missingPermissionSkipsRecognition() async {
        let capture = CaptureFake(outcome: .permissionNeeded)
        let recognizer = RecognizerFake(result: "unused")
        let context = await ScreenContextProvider(capture: capture, recognizer: recognizer).current()

        #expect(context.pngData == nil)
        #expect(context.ocrText == nil)
        #expect(context.status == .permissionNeeded)
        #expect(await recognizer.callCount == 0)
    }

    @Test func captureFailureSkipsRecognition() async {
        let capture = CaptureFake(outcome: .failed)
        let recognizer = RecognizerFake(result: "unused")
        let context = await ScreenContextProvider(capture: capture, recognizer: recognizer).current()

        #expect(context.pngData == nil)
        #expect(context.ocrText == nil)
        #expect(context.status == .captureFailed)
        #expect(await recognizer.callCount == 0)
    }

    private actor CaptureFake: ScreenCapturing {
        let outcome: ScreenCaptureOutcome

        init(outcome: ScreenCaptureOutcome) {
            self.outcome = outcome
        }

        func captureCurrentDisplayPNG() async -> ScreenCaptureOutcome {
            outcome
        }
    }

    private actor RecognizerFake: TextRecognizing {
        let result: String?
        private(set) var callCount = 0
        private(set) var receivedData: Data?

        init(result: String?) {
            self.result = result
        }

        func recognizeText(from pngData: Data) async -> String? {
            callCount += 1
            receivedData = pngData
            return result
        }
    }
}
