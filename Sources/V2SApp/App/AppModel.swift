import Combine
import Foundation
import Translation

@MainActor
final class AppModel: ObservableObject {
    private let settingsStore: SettingsStore
    private let sourceCatalogService: SourceCatalogService
    private let translationService = LiveTranslationService()
    private var liveTranscriptionSession: LiveTranscriptionSession?
    private var captionDisplayTask: Task<Void, Never>?
    private var captionTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCaptions: [QueuedCaption] = []
    private var readyCaptionTranslations: [UUID: String] = [:]
    private var displayedCaption: QueuedCaption?
    private var activeInputLanguageID: String?
    private var isBootstrapping = true

    @Published private(set) var applicationSources: [InputSource] = []
    @Published private(set) var microphoneSources: [InputSource] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var overlayState: OverlayPreviewState?
    @Published var isOverlayVisible = false

    @Published var selectedSourceID: String? {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var inputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var outputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            refreshCaptionTranslations()
        }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet {
            persistSettings()
        }
    }

    init(
        settingsStore: SettingsStore,
        sourceCatalogService: SourceCatalogService
    ) {
        self.settingsStore = settingsStore
        self.sourceCatalogService = sourceCatalogService

        let settings = settingsStore.load()
        self.selectedSourceID = settings.selectedSourceID
        self.inputLanguageID = settings.inputLanguageID
        self.outputLanguageID = settings.outputLanguageID
        self.overlayStyle = settings.overlayStyle

        isBootstrapping = false
        refreshSources()
    }

    convenience init() {
        self.init(
            settingsStore: SettingsStore(),
            sourceCatalogService: SourceCatalogService()
        )
    }

    var allSources: [InputSource] {
        applicationSources + microphoneSources
    }

    var selectedSource: InputSource? {
        allSources.first(where: { $0.id == selectedSourceID })
    }

    var sessionButtonTitle: String {
        sessionState == .running ? "Stop" : "Start"
    }

    var sessionBadgeText: String {
        sessionState.displayName
    }

    func refreshSources() {
        let snapshot = sourceCatalogService.loadSnapshot()
        applicationSources = snapshot.applications
        microphoneSources = snapshot.microphones

        if let selectedSourceID, allSources.contains(where: { $0.id == selectedSourceID }) == false {
            self.selectedSourceID = allSources.first?.id
        } else if selectedSourceID == nil {
            selectedSourceID = allSources.first?.id
        }

        if sessionState == .running {
            statusMessage = "Running on \(selectedSource?.name ?? "Selected Source")"
        } else {
            statusMessage = allSources.isEmpty ? "No input sources detected." : "Ready"
        }
    }

    func toggleSession() {
        if sessionState == .running {
            stopSession()
        } else {
            Task {
                await startSession()
            }
        }
    }

    func startSession() async {
        guard let selectedSource else {
            sessionState = .error
            statusMessage = "Choose an input source before starting."
            return
        }

        resetLiveTextPipeline()
        activeInputLanguageID = inputLanguageID
        isOverlayVisible = true
        overlayState = OverlayPreviewState(
            translatedText: "Listening…",
            sourceText: "Waiting for audio from \(selectedSource.name)…",
            sourceName: selectedSource.name
        )
        statusMessage = "Preparing \(selectedSource.name)…"

        let session = LiveTranscriptionSession()
        liveTranscriptionSession = session

        do {
            try await session.start(
                source: selectedSource,
                localeIdentifier: inputLanguageID,
                transcriptHandler: { [weak self] sentence in
                    self?.enqueueRecognizedSentence(sentence, sourceName: selectedSource.name)
                },
                errorHandler: { [weak self] message in
                    self?.sessionState = .error
                    self?.statusMessage = message
                    self?.overlayState = OverlayPreviewState(
                        translatedText: "Capture stopped",
                        sourceText: message,
                        sourceName: selectedSource.name
                    )
                }
            )

            sessionState = .running
            statusMessage = "Running on \(selectedSource.name)"
        } catch {
            resetLiveTextPipeline()
            liveTranscriptionSession = nil
            sessionState = .error
            statusMessage = error.localizedDescription
            overlayState = OverlayPreviewState(
                translatedText: "Unable to start",
                sourceText: error.localizedDescription,
                sourceName: selectedSource.name
            )
        }
    }

    func stopSession() {
        resetLiveTextPipeline()
        liveTranscriptionSession?.stop()
        liveTranscriptionSession = nil
        sessionState = .idle
        statusMessage = allSources.isEmpty ? "No input sources detected." : "Ready"
        isOverlayVisible = false
        overlayState = nil
    }

    func showOverlayPreview() {
        let source = selectedSource ?? InputSource.preview
        overlayState = makePreviewState(for: source)
        isOverlayVisible = true

        if sessionState != .running {
            statusMessage = "Showing overlay preview."
        }
    }

    func toggleOverlayVisibility() {
        if isOverlayVisible {
            isOverlayVisible = false
            if sessionState != .running {
                overlayState = nil
            }
        } else {
            showOverlayPreview()
        }
    }

    func updateOverlayStyle(_ update: (inout OverlayStyle) -> Void) {
        var style = overlayStyle
        update(&style)
        overlayStyle = style
    }

    func persistSettings() {
        guard isBootstrapping == false else {
            return
        }

        let settings = AppSettings(
            selectedSourceID: selectedSourceID,
            inputLanguageID: inputLanguageID,
            outputLanguageID: outputLanguageID,
            overlayStyle: overlayStyle
        )

        settingsStore.save(settings)
    }

    func languageName(for identifier: String) -> String {
        LanguageCatalog.displayName(for: identifier)
    }

    private func syncOverlayPreviewIfNeeded() {
        guard liveTranscriptionSession == nil else {
            return
        }

        guard isOverlayVisible || sessionState == .running else {
            return
        }

        let source = selectedSource ?? InputSource.preview
        overlayState = makePreviewState(for: source)
    }

    private func makePreviewState(for source: InputSource) -> OverlayPreviewState {
        let sourceText = sampleText(for: inputLanguageID)
        let translatedText: String

        if inputLanguageID == outputLanguageID {
            translatedText = sourceText
        } else {
            translatedText = sampleText(for: outputLanguageID)
        }

        return OverlayPreviewState(
            translatedText: translatedText,
            sourceText: sourceText,
            sourceName: source.name
        )
    }

    private func enqueueRecognizedSentence(_ sentence: RecognizedSentence, sourceName: String) {
        let sourceText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.isEmpty == false else {
            return
        }

        let caption = QueuedCaption(
            id: UUID(),
            sourceText: sourceText,
            sourceName: sourceName
        )

        pendingCaptions.append(caption)
        translateCaption(caption)
        processCaptionQueueIfNeeded()

        if sessionState != .running {
            sessionState = .running
        }

        statusMessage = "Running on \(sourceName)"
    }

    private func refreshCaptionTranslations() {
        guard liveTranscriptionSession != nil else {
            return
        }

        cancelCaptionTranslations()
        readyCaptionTranslations.removeAll()

        for caption in pendingCaptions {
            translateCaption(caption)
        }

        if let displayedCaption {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let translatedText = await translatedText(for: displayedCaption)
                guard liveTranscriptionSession != nil,
                      self.displayedCaption?.id == displayedCaption.id else {
                    return
                }

                overlayState = OverlayPreviewState(
                    translatedText: translatedText,
                    sourceText: displayedCaption.sourceText,
                    sourceName: displayedCaption.sourceName
                )
            }
        }
    }

    private var currentSourceLanguageID: String {
        activeInputLanguageID ?? inputLanguageID
    }

    private func resetLiveTextPipeline() {
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        cancelCaptionTranslations()
        pendingCaptions.removeAll()
        readyCaptionTranslations.removeAll()
        displayedCaption = nil
        activeInputLanguageID = nil

        Task {
            await translationService.reset()
        }
    }

    private func processCaptionQueueIfNeeded() {
        guard captionDisplayTask == nil else {
            return
        }

        captionDisplayTask = Task { @MainActor [weak self] in
            await self?.processCaptionQueue()
        }
    }

    private func processCaptionQueue() async {
        while Task.isCancelled == false {
            guard liveTranscriptionSession != nil else {
                break
            }

            guard let caption = pendingCaptions.first else {
                break
            }

            guard let translatedText = await waitForTranslatedCaption(id: caption.id) else {
                break
            }

            guard liveTranscriptionSession != nil else {
                break
            }

            displayedCaption = caption
            overlayState = OverlayPreviewState(
                translatedText: translatedText,
                sourceText: caption.sourceText,
                sourceName: caption.sourceName
            )

            let holdDuration = displayDuration(for: caption, translatedText: translatedText)

            do {
                try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            } catch {
                break
            }

            if let firstCaption = pendingCaptions.first, firstCaption.id == caption.id {
                pendingCaptions.removeFirst()
            } else {
                pendingCaptions.removeAll(where: { $0.id == caption.id })
            }

            readyCaptionTranslations.removeValue(forKey: caption.id)
        }

        captionDisplayTask = nil
    }

    private func waitForTranslatedCaption(id: UUID) async -> String? {
        while Task.isCancelled == false {
            if let translatedText = readyCaptionTranslations[id] {
                return translatedText
            }

            if liveTranscriptionSession == nil {
                return nil
            }

            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return nil
            }
        }

        return nil
    }

    private func translateCaption(_ caption: QueuedCaption) {
        captionTranslationTasks[caption.id]?.cancel()

        captionTranslationTasks[caption.id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let translatedText = await translatedText(for: caption)
            guard Task.isCancelled == false,
                  liveTranscriptionSession != nil else {
                return
            }

            readyCaptionTranslations[caption.id] = translatedText
            captionTranslationTasks[caption.id] = nil
        }
    }

    private func translatedText(for caption: QueuedCaption) async -> String {
        let sourceLanguageID = currentSourceLanguageID
        let targetLanguageID = outputLanguageID

        guard sourceLanguageID != targetLanguageID else {
            return caption.sourceText
        }

        return await withTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask { [translationService] in
                do {
                    return try await translationService.translate(
                        caption.sourceText,
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                } catch {
                    return caption.sourceText
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return caption.sourceText
            }

            let resolvedText = await group.next() ?? caption.sourceText
            group.cancelAll()
            return resolvedText
        }
    }

    private func cancelCaptionTranslations() {
        for task in captionTranslationTasks.values {
            task.cancel()
        }

        captionTranslationTasks.removeAll()
    }

    private func displayDuration(for caption: QueuedCaption, translatedText: String) -> Double {
        let characterCount = max(caption.sourceText.count, translatedText.count)
        return min(max(Double(characterCount) * 0.14 + 1.8, 3.0), 9.0)
    }

    private func sampleText(for languageID: String) -> String {
        switch languageID {
        case "zh-Hans":
            return "欢迎使用 v2s，顶部字幕条已经准备好了。"
        case "ja":
            return "v2s へようこそ。字幕バーの準備ができました。"
        case "ko":
            return "v2s에 오신 것을 환영합니다. 자막 바가 준비되었습니다."
        case "fr":
            return "Bienvenue dans v2s. La barre de sous-titres est prete."
        case "de":
            return "Willkommen bei v2s. Die Untertitel-Leiste ist bereit."
        default:
            return "Welcome to v2s. The subtitle bar is ready."
        }
    }

}

private struct QueuedCaption: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let sourceName: String
}

private actor LiveTranslationService {
    private struct LanguagePair: Equatable {
        let source: String
        let target: String
    }

    enum ServiceError: LocalizedError {
        case unavailableOnSystem
        case unsupportedPair(String, String)

        var errorDescription: String? {
            switch self {
            case .unavailableOnSystem:
                return "Translation requires macOS 26 or newer."
            case .unsupportedPair(let source, let target):
                return "Translation is not supported from \(source) to \(target)."
            }
        }
    }

    private var preparedPair: LanguagePair?
    private var sessionStorage: AnyObject?

    func translate(_ text: String, from sourceIdentifier: String, to targetIdentifier: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        guard sourceIdentifier != targetIdentifier else {
            return trimmedText
        }

        guard #available(macOS 26.0, *) else {
            throw ServiceError.unavailableOnSystem
        }

        let sourceLanguage = Locale.Language(identifier: sourceIdentifier)
        let targetLanguage = Locale.Language(identifier: targetIdentifier)
        let availability = LanguageAvailability()
        let availabilityStatus = await availability.status(from: sourceLanguage, to: targetLanguage)

        guard availabilityStatus != .unsupported else {
            throw ServiceError.unsupportedPair(sourceIdentifier, targetIdentifier)
        }

        let requestedPair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let session: TranslationSession

        if let cachedSession = sessionStorage as? TranslationSession,
           preparedPair == requestedPair {
            session = cachedSession
        } else {
            let newSession = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            try await newSession.prepareTranslation()
            sessionStorage = newSession
            preparedPair = requestedPair
            session = newSession
        }

        let response = try await session.translate(trimmedText)
        let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        return translatedText.isEmpty ? trimmedText : translatedText
    }

    func reset() {
        if #available(macOS 26.0, *) {
            (sessionStorage as? TranslationSession)?.cancel()
        }

        sessionStorage = nil
        preparedPair = nil
    }
}
