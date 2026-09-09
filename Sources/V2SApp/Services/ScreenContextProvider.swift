import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit
import Vision

enum ScreenCaptureOutcome: Equatable, Sendable {
    case captured(Data)
    case permissionNeeded
    case failed
}

protocol ScreenCapturing: Sendable {
    func captureCurrentDisplayPNG() async -> ScreenCaptureOutcome
}

protocol TextRecognizing: Sendable {
    func recognizeText(from pngData: Data) async -> String?
}

struct ScreenContext: Equatable, Sendable {
    let pngData: Data?
    let ocrText: String?
    let status: ScreenContextStatus
}

enum ScreenContextStatus: Equatable, Sendable {
    case unknown
    case ready
    case permissionNeeded
    case captureFailed
    case ocrFailed
    case screenshotSent
    case providerRejectedImage

    var isWarning: Bool {
        switch self {
        case .permissionNeeded, .captureFailed, .ocrFailed, .providerRejectedImage:
            true
        case .unknown, .ready, .screenshotSent:
            false
        }
    }
}

struct ScreenContextProvider: Sendable {
    let capture: any ScreenCapturing
    let recognizer: any TextRecognizing

    func current() async -> ScreenContext {
        switch await capture.captureCurrentDisplayPNG() {
        case .captured(let pngData):
            guard let ocrText = await recognizer.recognizeText(from: pngData) else {
                return ScreenContext(pngData: pngData, ocrText: nil, status: .ocrFailed)
            }
            return ScreenContext(pngData: pngData, ocrText: ocrText, status: .ready)
        case .permissionNeeded:
            return ScreenContext(pngData: nil, ocrText: nil, status: .permissionNeeded)
        case .failed:
            return ScreenContext(pngData: nil, ocrText: nil, status: .captureFailed)
        }
    }
}

struct SystemScreenCapturer: ScreenCapturing {
    func captureCurrentDisplayPNG() async -> ScreenCaptureOutcome {
        guard CGPreflightScreenCaptureAccess() else {
            guard CGRequestScreenCaptureAccess() else {
                return .permissionNeeded
            }
            return .failed
        }

        let preferredDisplayID = await MainActor.run { displayIDForMouseLocation() }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let display = content.displays.first(where: { $0.displayID == preferredDisplayID })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
            guard let display else { return .failed }

            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
            guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return .failed
            }
            return .captured(pngData)
        } catch {
            return .failed
        }
    }

    @MainActor private func displayIDForMouseLocation() -> CGDirectDisplayID? {
        let point = CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, UInt32(displays.count), &displays, &count)
        guard result == .success, count > 0 else { return nil }
        return displays[0]
    }
}

struct VisionTextRecognizer: TextRecognizing {
    func recognizeText(from pngData: Data) async -> String? {
        guard let image = CIImage(data: pngData) else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let lines = observations
                    .sorted(by: Self.isBeforeVisually)
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func isBeforeVisually(_ lhs: VNRecognizedTextObservation, _ rhs: VNRecognizedTextObservation) -> Bool {
        let verticalDifference = lhs.boundingBox.midY - rhs.boundingBox.midY
        if abs(verticalDifference) > 0.01 {
            return verticalDifference > 0
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
}
