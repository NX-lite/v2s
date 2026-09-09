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
        #expect(await recognizer.callCount == 1)
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
        #expect(await recognizer.callCount == 1)
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

    @Test func screenSelectionUsesAppKitCoordinatesForNegativeOriginDisplays() {
        let screens = [
            ScreenDescriptor(displayID: 10, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), backingScaleFactor: 2),
            ScreenDescriptor(displayID: 20, frame: CGRect(x: -1_280, y: -1_024, width: 1_280, height: 1_024), backingScaleFactor: 1),
        ]

        #expect(ScreenCaptureGeometry.screen(containing: CGPoint(x: 100, y: 100), in: screens)?.displayID == 10)
        #expect(ScreenCaptureGeometry.screen(containing: CGPoint(x: -640, y: -512), in: screens)?.displayID == 20)
    }

    @Test func pixelSizeUsesBackingScaleAndClampsInvalidInputs() {
        #expect(ScreenCaptureGeometry.pixelSize(logicalWidth: 800, logicalHeight: 600, backingScaleFactor: 2) == ScreenPixelSize(width: 1_600, height: 1_200))
        #expect(ScreenCaptureGeometry.pixelSize(logicalWidth: 0, logicalHeight: -5, backingScaleFactor: 0) == ScreenPixelSize(width: 1, height: 1))
    }

    @Test func OCRCandidatesHaveStableVisualReadingOrder() {
        let candidates = [
            OCRTextCandidate(text: "middle", boundingBox: CGRect(x: 0.4, y: 0.50, width: 0.1, height: 0.1), originalIndex: 0),
            OCRTextCandidate(text: "top-left", boundingBox: CGRect(x: 0.1, y: 0.903, width: 0.1, height: 0.1), originalIndex: 1),
            OCRTextCandidate(text: "top-right", boundingBox: CGRect(x: 0.7, y: 0.900, width: 0.1, height: 0.1), originalIndex: 2),
            OCRTextCandidate(text: "lower", boundingBox: CGRect(x: 0.2, y: 0.15, width: 0.1, height: 0.1), originalIndex: 3),
            OCRTextCandidate(text: "same-position-later", boundingBox: CGRect(x: 0.1, y: 0.903, width: 0.1, height: 0.1), originalIndex: 5),
            OCRTextCandidate(text: "same-position-first", boundingBox: CGRect(x: 0.1, y: 0.903, width: 0.1, height: 0.1), originalIndex: 4),
        ]

        let expected = ["top-left", "same-position-first", "same-position-later", "top-right", "middle", "lower"]
        #expect(OCRCandidateOrdering.ordered(candidates).map(\.text) == expected)
        #expect(OCRCandidateOrdering.ordered(candidates).map(\.text) == expected)
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
