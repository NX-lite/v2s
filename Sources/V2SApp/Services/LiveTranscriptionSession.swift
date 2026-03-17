import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

struct RecognizedSentence: Equatable, Sendable {
    let text: String
}

final class LiveTranscriptionSession: NSObject {
    enum SessionError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioCapturePermissionDenied
        case unsupportedSpeechLocale(String)
        case unavailableSpeechRecognizer(String)
        case missingMicrophoneDevice
        case missingApplication(String)
        case applicationNotProducingAudio(String)
        case failedToStartCapture(String)

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return "Speech recognition permission was denied."
            case .microphonePermissionDenied:
                return "Microphone permission was denied."
            case .audioCapturePermissionDenied:
                return "App audio capture permission was denied. Allow v2s to capture audio from other apps, then reopen the app."
            case .unsupportedSpeechLocale(let localeIdentifier):
                return "Speech recognition does not support \(localeIdentifier)."
            case .unavailableSpeechRecognizer(let localeIdentifier):
                return "Speech recognition is currently unavailable for \(localeIdentifier)."
            case .missingMicrophoneDevice:
                return "The selected microphone is no longer available."
            case .missingApplication(let appName):
                return "The selected app, \(appName), is no longer available."
            case .applicationNotProducingAudio(let appName):
                return "\(appName) is not producing app audio yet. Start playback in the app, then try again."
            case .failedToStartCapture(let reason):
                return reason
            }
        }
    }

    private let captureQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture", qos: .userInitiated)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: AudioFormatSignature?
    private var committedSegmentCount = 0

    private var microphoneCaptureSession: AVCaptureSession?
    private var applicationAudioCapture: ApplicationAudioCapture?

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?

    func start(
        source: InputSource,
        localeIdentifier: String,
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.transcriptHandler = transcriptHandler
        self.errorHandler = errorHandler

        try await requestRequiredPermissions(for: source)
        try configureSpeechRecognizer(localeIdentifier: localeIdentifier)

        switch source.category {
        case .microphone:
            try startMicrophoneCapture(deviceUniqueID: source.detail)
        case .application:
            try startApplicationAudioCapture(source: source)
        }
    }

    func stop() {
        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        committedSegmentCount = 0
    }

    private func requestRequiredPermissions(for source: InputSource) async throws {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestSpeechAuthorization()
            guard granted else {
                throw SessionError.speechPermissionDenied
            }
        case .denied, .restricted:
            throw SessionError.speechPermissionDenied
        @unknown default:
            throw SessionError.speechPermissionDenied
        }

        switch source.category {
        case .microphone:
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

            switch microphoneStatus {
            case .authorized:
                break
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw SessionError.microphonePermissionDenied
                }
            case .denied, .restricted:
                throw SessionError.microphonePermissionDenied
            @unknown default:
                throw SessionError.microphonePermissionDenied
            }
        case .application:
            break
        }
    }

    private func configureSpeechRecognizer(localeIdentifier: String) throws {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionError.unsupportedSpeechLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SessionError.unavailableSpeechRecognizer(localeIdentifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error {
                Task {
                    await self?.emitError("Speech recognition failed: \(error.localizedDescription)")
                }
                return
            }

            guard let result else {
                return
            }

            self?.captureQueue.async { [weak self] in
                self?.processRecognitionResult(result)
            }
        }

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        audioConverter = nil
        audioConverterInputSignature = nil
        committedSegmentCount = 0
    }

    private func startMicrophoneCapture(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw SessionError.failedToStartCapture("Could not add the selected microphone to the capture session.")
        }

        guard session.canAddOutput(output) else {
            throw SessionError.failedToStartCapture("Could not add an audio output to the microphone capture session.")
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        microphoneCaptureSession = session
        captureQueue.async {
            session.startRunning()
        }
    }

    private func startApplicationAudioCapture(source: InputSource) throws {
        let processObjectIDs = try resolveApplicationProcessObjectIDs(for: source)
        let capture = ApplicationAudioCapture(
            appName: source.name,
            processObjectIDs: processObjectIDs,
            queue: captureQueue,
            audioHandler: { [weak self] buffer in
                self?.append(audioBuffer: buffer)
            },
            errorHandler: { [weak self] message in
                Task {
                    await self?.emitError(message)
                }
            }
        )

        do {
            try capture.start()
            applicationAudioCapture = capture
        } catch let error as ApplicationAudioCapture.CaptureError {
            throw mapApplicationCaptureError(error)
        } catch {
            throw SessionError.failedToStartCapture("Failed to start application audio capture: \(error.localizedDescription)")
        }
    }

    private func resolveApplicationProcessObjectIDs(for source: InputSource) throws -> [AudioObjectID] {
        let runningApp = try resolveRunningApplication(for: source)
        let system = AudioHardwareSystem.shared
        let audioProcesses = try system.processes
        let targetAssociation = ApplicationProcessAssociation(runningApplication: runningApp)
        var relatedProcessIDs: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()

        for process in audioProcesses {
            let processID = try process.pid
            let processObjectID = process.id
            let processBundleIdentifier = (try? process.bundleID) ?? ""
            let processAppBundleURL = applicationBundleURL(forProcessID: processID)
            let executablePath = executablePath(forProcessID: processID)

            let matchesMainProcess = processID == runningApp.processIdentifier
            let matchesBundleIdentifier = targetAssociation.matchesExactBundleIdentifier(processBundleIdentifier)
            let matchesBundleURL = targetAssociation.matchesApplicationBundleURL(processAppBundleURL)
            let matchesHelperBundle = targetAssociation.matchesHelperBundleIdentifier(processBundleIdentifier)
            let matchesHelperPath = targetAssociation.matchesHelperExecutablePath(executablePath)

            guard matchesMainProcess
                || matchesBundleIdentifier
                || matchesBundleURL
                || matchesHelperBundle
                || matchesHelperPath else {
                    continue
                }

            if seen.insert(processObjectID).inserted {
                relatedProcessIDs.append(processObjectID)
            }
        }

        if relatedProcessIDs.isEmpty {
            if let exactProcess = try system.process(for: runningApp.processIdentifier) {
                return [exactProcess.id]
            }

            throw SessionError.applicationNotProducingAudio(source.name)
        }

        return relatedProcessIDs
    }

    private func resolveRunningApplication(for source: InputSource) throws -> NSRunningApplication {
        let runningApps = NSWorkspace.shared.runningApplications
        let application: NSRunningApplication?

        if let processIdentifier = source.processIdentifierHint {
            application = runningApps.first(where: { $0.processIdentifier == processIdentifier })
        } else {
            application = runningApps.first(where: { $0.bundleIdentifier == source.detail })
        }

        guard let application else {
            throw SessionError.missingApplication(source.name)
        }

        return application
    }

    private func append(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func append(audioBuffer: AVAudioPCMBuffer) {
        guard audioBuffer.frameLength > 0,
              let recognitionRequest else {
            return
        }

        let nativeFormat = recognitionRequest.nativeAudioFormat

        if audioBuffer.format.matches(nativeFormat) {
            recognitionRequest.append(audioBuffer)
            return
        }

        let inputSignature = AudioFormatSignature(audioBuffer.format)

        if audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: nativeFormat)
            audioConverterInputSignature = inputSignature
        }

        guard let audioConverter else {
            Task {
                await emitError("Failed to prepare the audio converter for speech recognition.")
            }
            return
        }

        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(audioBuffer.frameLength) * nativeFormat.sampleRate / audioBuffer.format.sampleRate)),
            1
        )

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: outputFrameCapacity) else {
            Task {
                await emitError("Failed to allocate a speech-recognition audio buffer.")
            }
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = audioConverter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        if let conversionError {
            Task {
                await emitError("Failed to convert captured audio: \(conversionError.localizedDescription)")
            }
            return
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if convertedBuffer.frameLength > 0 {
                recognitionRequest.append(convertedBuffer)
            }
        case .error:
            Task {
                await emitError("Audio conversion failed while feeding the speech recognizer.")
            }
        @unknown default:
            break
        }
    }

    @MainActor
    private func emitRecognizedSentence(_ sentence: RecognizedSentence) {
        transcriptHandler?(sentence)
    }

    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let segments = transcription.segments

        if committedSegmentCount > segments.count {
            committedSegmentCount = 0
        }

        guard committedSegmentCount < segments.count else {
            return
        }

        let formattedText = transcription.formattedString as NSString
        var sentenceStartIndex = committedSegmentCount

        for index in committedSegmentCount..<segments.count {
            let segment = segments[index]
            let nextPauseDuration: TimeInterval?

            if index < segments.count - 1 {
                let nextSegment = segments[index + 1]
                nextPauseDuration = nextSegment.timestamp - (segment.timestamp + segment.duration)
            } else {
                nextPauseDuration = nil
            }

            let currentRange = combinedRange(for: segments, from: sentenceStartIndex, to: index)
            let currentTextLength = currentRange.length
            let currentSegmentCount = index - sentenceStartIndex + 1
            let sentenceStartTimestamp = segments[sentenceStartIndex].timestamp
            let sentenceEndTimestamp = segment.timestamp + segment.duration
            let currentSentenceDuration = max(sentenceEndTimestamp - sentenceStartTimestamp, 0)

            let punctuationBoundary = segment.substring.containsSentenceTerminator
            let strongPauseBoundary = (nextPauseDuration ?? 0) >= 0.55
            let softPauseBoundary = (nextPauseDuration ?? 0) >= 0.28
                && (currentSegmentCount >= 5 || currentTextLength >= 24 || currentSentenceDuration >= 2.0)
            let forcedBoundary = currentSegmentCount >= 14
                || currentTextLength >= 72
                || currentSentenceDuration >= 5.5
            let finalBoundary = result.isFinal && index == segments.count - 1

            guard punctuationBoundary
                || strongPauseBoundary
                || softPauseBoundary
                || forcedBoundary
                || finalBoundary else {
                continue
            }

            let sentenceText = formattedText.substring(with: currentRange)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if sentenceText.isEmpty == false {
                let recognizedSentence = RecognizedSentence(text: sentenceText)
                Task {
                    await emitRecognizedSentence(recognizedSentence)
                }
            }

            sentenceStartIndex = index + 1
            committedSegmentCount = sentenceStartIndex
        }
    }

    private func combinedRange(for segments: [SFTranscriptionSegment], from startIndex: Int, to endIndex: Int) -> NSRange {
        let firstRange = segments[startIndex].substringRange
        let lastRange = segments[endIndex].substringRange
        let endLocation = lastRange.location + lastRange.length
        return NSRange(location: firstRange.location, length: endLocation - firstRange.location)
    }

    private func mapApplicationCaptureError(_ error: ApplicationAudioCapture.CaptureError) -> SessionError {
        switch error {
        case .permissionDenied:
            return .audioCapturePermissionDenied
        case .missingOutputDevice:
            return .failedToStartCapture("No output audio device is available for app capture.")
        case .tapFormatUnavailable:
            return .failedToStartCapture("The selected app's audio format could not be prepared for capture.")
        case .failed(let stage, let status):
            return .failedToStartCapture("Failed to \(stage): \(status.readableDescription)")
        }
    }
}

extension LiveTranscriptionSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        append(sampleBuffer: sampleBuffer)
    }
}

private final class ApplicationAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case missingOutputDevice
        case tapFormatUnavailable
        case failed(stage: String, status: OSStatus)
    }

    private let appName: String
    private let processObjectIDs: [AudioObjectID]
    private let queue: DispatchQueue
    private let audioHandler: (AVAudioPCMBuffer) -> Void
    private let errorHandler: (String) -> Void

    private let system = AudioHardwareSystem.shared
    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    init(
        appName: String,
        processObjectIDs: [AudioObjectID],
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.queue = queue
        self.audioHandler = audioHandler
        self.errorHandler = errorHandler
    }

    func start() throws {
        do {
            let tapDescription = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            tapDescription.name = "v2s \(appName)"

            guard let processTap = try system.makeProcessTap(description: tapDescription) else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTap = processTap

            guard let outputDevice = try system.defaultOutputDevice else {
                throw CaptureError.missingOutputDevice
            }

            let outputUID = try outputDevice.uid
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "v2s-\(appName)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: try processTap.uid
                    ]
                ]
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDevice = aggregateDevice

            var streamDescription = try processTap.format
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat

            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDevice.id,
                queue
            ) { [weak self] _, inputData, _, _, _ in
                guard let self else {
                    return
                }

                self.handleCapturedAudio(inputData)
            }

            guard createIOProcStatus == noErr, let deviceIOProcID else {
                throw CaptureError.failed(stage: "create the capture callback", status: createIOProcStatus)
            }

            self.deviceIOProcID = deviceIOProcID

            let startStatus = AudioDeviceStart(aggregateDevice.id, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }
        } catch let error as AudioHardwareError {
            stop()

            if error.error == permErr {
                throw CaptureError.permissionDenied
            }

            throw CaptureError.failed(stage: "configure app audio capture", status: error.error)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let aggregateDevice, let deviceIOProcID {
            AudioDeviceStop(aggregateDevice.id, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, deviceIOProcID)
        }

        deviceIOProcID = nil

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        aggregateDevice = nil

        if let processTap {
            try? system.destroyProcessTap(processTap)
        }

        processTap = nil
        tapFormat = nil
    }

    private func handleCapturedAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              inputData.pointee.mNumberBuffers > 0,
              inputData.pointee.mBuffers.mDataByteSize > 0 else {
            return
        }

        let mutableAudioBufferList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: mutableAudioBufferList,
            deallocator: nil
        ) else {
            errorHandler("Failed to read the captured audio stream for \(appName).")
            return
        }

        audioHandler(buffer)
    }
}

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }
}

private extension AVAudioFormat {
    func matches(_ other: AVAudioFormat) -> Bool {
        AudioFormatSignature(self) == AudioFormatSignature(other)
    }
}

private extension InputSource {
    var processIdentifierHint: pid_t? {
        guard detail.hasPrefix("pid-") else {
            return nil
        }

        return pid_t(detail.dropFirst(4))
    }
}

private struct ApplicationProcessAssociation {
    let bundleIdentifier: String?
    let applicationBundleURL: URL?
    let helperBundlePrefixes: [String]
    let helperPathFragments: [String]

    init(runningApplication: NSRunningApplication) {
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.applicationBundleURL = runningApplication.bundleURL?.standardizedFileURL

        var helperBundlePrefixes: [String] = []
        var helperPathFragments: [String] = []

        if let bundleIdentifier = runningApplication.bundleIdentifier {
            helperBundlePrefixes.append(bundleIdentifier)

            switch bundleIdentifier {
            case "com.apple.Safari":
                helperBundlePrefixes.append(contentsOf: [
                    "com.apple.WebKit.",
                    "com.apple.Safari"
                ])
                helperPathFragments.append(contentsOf: [
                    "/WebKit.framework/",
                    "/SafariPlatformSupport.framework/",
                    "/Safari.app/"
                ])
            case "com.google.Chrome":
                helperPathFragments.append(contentsOf: [
                    "/Google Chrome.app/",
                    "Google Chrome Helper"
                ])
            case "org.chromium.Chromium":
                helperPathFragments.append(contentsOf: [
                    "/Chromium.app/",
                    "Chromium Helper"
                ])
            case "com.microsoft.edgemac":
                helperPathFragments.append(contentsOf: [
                    "/Microsoft Edge.app/",
                    "Microsoft Edge Helper"
                ])
            case "com.brave.Browser":
                helperPathFragments.append(contentsOf: [
                    "/Brave Browser.app/",
                    "Brave Browser Helper"
                ])
            case "org.mozilla.firefox":
                helperPathFragments.append(contentsOf: [
                    "/Firefox.app/",
                    "plugin-container"
                ])
            default:
                break
            }
        }

        self.helperBundlePrefixes = Array(Set(helperBundlePrefixes))
        self.helperPathFragments = Array(Set(helperPathFragments))
    }

    func matchesExactBundleIdentifier(_ candidate: String) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return candidate == bundleIdentifier
    }

    func matchesApplicationBundleURL(_ candidate: URL?) -> Bool {
        guard let applicationBundleURL else {
            return false
        }

        return candidate == applicationBundleURL
    }

    func matchesHelperBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.isEmpty == false else {
            return false
        }

        return helperBundlePrefixes.contains(where: { candidate.hasPrefix($0) })
    }

    func matchesHelperExecutablePath(_ candidate: String?) -> Bool {
        guard let candidate, candidate.isEmpty == false else {
            return false
        }

        return helperPathFragments.contains(where: { candidate.contains($0) })
    }
}

private extension String {
    var containsSentenceTerminator: Bool {
        contains(where: { ".!?。！？;；".contains($0) })
    }
}

private extension OSStatus {
    var readableDescription: String {
        let nsError = NSError(domain: NSOSStatusErrorDomain, code: Int(self))

        if nsError.localizedDescription != "The operation couldn’t be completed. (OSStatus error \(self).)" {
            return nsError.localizedDescription
        }

        if let fourCharacterCode = fourCharacterCode {
            return "\(self) (\(fourCharacterCode))"
        }

        return "\(self)"
    }

    private var fourCharacterCode: String? {
        let bigEndianValue = UInt32(bitPattern: self).bigEndian
        let scalarValues = [
            UInt8((bigEndianValue >> 24) & 0xFF),
            UInt8((bigEndianValue >> 16) & 0xFF),
            UInt8((bigEndianValue >> 8) & 0xFF),
            UInt8(bigEndianValue & 0xFF)
        ]

        guard scalarValues.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return nil
        }

        return String(bytes: scalarValues, encoding: .ascii)
    }
}

private func executablePath(forProcessID processID: pid_t) -> String? {
    let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer {
        pathBuffer.deallocate()
    }

    let pathLength = proc_pidpath(processID, pathBuffer, UInt32(MAXPATHLEN))
    guard pathLength > 0 else {
        return nil
    }

    return String(cString: pathBuffer)
}

private func applicationBundleURL(forProcessID processID: pid_t) -> URL? {
    guard let executablePath = executablePath(forProcessID: processID) else {
        return nil
    }

    return URL(fileURLWithPath: executablePath).owningApplicationBundleURL()
}

private extension URL {
    func owningApplicationBundleURL(maxDepth: Int = 16) -> URL? {
        var depth = 0
        var currentURL = standardizedFileURL

        while depth < maxDepth {
            if currentURL.pathExtension == "app" {
                return currentURL.standardizedFileURL
            }

            currentURL = currentURL.deletingLastPathComponent()
            depth += 1
        }

        return nil
    }
}
