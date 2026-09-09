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

struct ScreenDescriptor: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: CGFloat
}

struct ScreenPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum ScreenCaptureGeometry {
    static func screen(containing point: CGPoint, in screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens.first { $0.frame.contains(point) }
    }

    static func pixelSize(
        logicalWidth: CGFloat,
        logicalHeight: CGFloat,
        backingScaleFactor: CGFloat
    ) -> ScreenPixelSize {
        let scale = backingScaleFactor.isFinite ? max(1, backingScaleFactor) : 1
        return ScreenPixelSize(
            width: pixelDimension(logicalWidth, scale: scale),
            height: pixelDimension(logicalHeight, scale: scale)
        )
    }

    private static func pixelDimension(_ logicalDimension: CGFloat, scale: CGFloat) -> Int {
        guard logicalDimension.isFinite, logicalDimension > 0 else { return 1 }
        return max(1, Int((logicalDimension * scale).rounded(.toNearestOrAwayFromZero)))
    }
}

struct OCRTextCandidate: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let originalIndex: Int
}

enum OCRCandidateOrdering {
    private static let rowTolerance: CGFloat = 0.01

    static func ordered(_ candidates: [OCRTextCandidate]) -> [OCRTextCandidate] {
        let verticallySorted = candidates.sorted(by: isAbove)
        var rowAnchors = [CGFloat]()
        var rows = [[OCRTextCandidate]]()

        for candidate in verticallySorted {
            if let rowIndex = rowAnchors.firstIndex(where: { abs($0 - candidate.boundingBox.midY) <= rowTolerance }) {
                rows[rowIndex].append(candidate)
            } else {
                rowAnchors.append(candidate.boundingBox.midY)
                rows.append([candidate])
            }
        }

        return rows.flatMap { $0.sorted(by: isBeforeWithinRow) }
    }

    private static func isAbove(_ lhs: OCRTextCandidate, _ rhs: OCRTextCandidate) -> Bool {
        if lhs.boundingBox.midY != rhs.boundingBox.midY {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        if lhs.boundingBox.minX != rhs.boundingBox.minX {
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return lhs.originalIndex < rhs.originalIndex
    }

    private static func isBeforeWithinRow(_ lhs: OCRTextCandidate, _ rhs: OCRTextCandidate) -> Bool {
        if lhs.boundingBox.minX != rhs.boundingBox.minX {
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return lhs.originalIndex < rhs.originalIndex
    }
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

        let selection = await MainActor.run { currentScreenSelection() }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let display = content.displays.first(where: { $0.displayID == selection.preferred?.displayID })
                ?? content.displays.first(where: { $0.displayID == selection.mainDisplayID })
                ?? content.displays.first
            guard let display,
                  let screen = selection.screens.first(where: { $0.displayID == display.displayID })
            else { return .failed }

            let configuration = SCStreamConfiguration()
            let pixelSize = ScreenCaptureGeometry.pixelSize(
                logicalWidth: screen.frame.width,
                logicalHeight: screen.frame.height,
                backingScaleFactor: screen.backingScaleFactor
            )
            configuration.width = pixelSize.width
            configuration.height = pixelSize.height
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

    @MainActor private func currentScreenSelection() -> ScreenSelection {
        let screens: [ScreenDescriptor] = NSScreen.screens.compactMap { screen -> ScreenDescriptor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenDescriptor(
                displayID: number.uint32Value,
                frame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
        let mainDisplayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        let fallback = screens.first(where: { $0.displayID == mainDisplayID }) ?? screens.first
        let preferred = ScreenCaptureGeometry.screen(containing: NSEvent.mouseLocation, in: screens) ?? fallback
        return ScreenSelection(screens: screens, preferred: preferred, mainDisplayID: mainDisplayID)
    }
}

private struct ScreenSelection: Sendable {
    let screens: [ScreenDescriptor]
    let preferred: ScreenDescriptor?
    let mainDisplayID: CGDirectDisplayID
}

struct VisionTextRecognizer: TextRecognizing {
    func recognizeText(from pngData: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let image = CIImage(data: pngData) else { return nil }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
                guard let observations = request.results else {
                    return nil
                }
                let candidates = observations.enumerated().compactMap { index, observation -> OCRTextCandidate? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return OCRTextCandidate(text: text, boundingBox: observation.boundingBox, originalIndex: index)
                }
                let text = OCRCandidateOrdering.ordered(candidates)
                    .map(\.text)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }.value
    }
}
