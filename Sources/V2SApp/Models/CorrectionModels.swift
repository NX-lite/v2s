import Foundation

enum CorrectionInputMode: Equatable, Sendable {
    case audio
    case textOnly
}

enum CorrectionStatus: Equatable, Sendable {
    case disabled
    case ready
    case audio
    case textOnly
    case warning(String)
}

enum CorrectionModelFetchState: Equatable, Sendable {
    case idle
    case fetching
    case fetched([String])
    case failed(String?)
}

enum CorrectionAPITestState: Equatable, Sendable {
    case idle
    case testing
    case passed(String)
    case failed(String?)
}

struct CorrectionContextEntry: Equatable, Sendable {
    let captionID: UUID
    let capturedAt: Date
    let sourceID: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let original: String
    let translation: String
}

struct CorrectionJob: Equatable, Sendable {
    let captionID: UUID
    let sessionGeneration: Int
    let capturedAt: Date
    let sourceID: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let localOriginal: String
    let localTranslation: String
    let audioWAVData: Data?
}

struct CorrectionResult: Equatable, Sendable {
    let captionID: UUID
    let sessionGeneration: Int
    let sourceID: String
    let correctedOriginal: String?
    let correctedTranslation: String
    let mode: CorrectionInputMode
}

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let sourceID: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    var localSourceText: String
    var localTranslatedText: String
    var correctedSourceText: String?
    var correctedTranslatedText: String?
    var timestamp: Date

    var sourceText: String {
        effectiveText(correctedSourceText, fallingBackTo: localSourceText)
    }

    var translatedText: String {
        effectiveText(correctedTranslatedText, fallingBackTo: localTranslatedText)
    }

    init(
        id: UUID,
        sourceID: String,
        sourceName: String,
        sourceLanguageID: String,
        targetLanguageID: String,
        localSourceText: String,
        localTranslatedText: String,
        correctedSourceText: String? = nil,
        correctedTranslatedText: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
        self.localSourceText = localSourceText
        self.localTranslatedText = localTranslatedText
        self.correctedSourceText = correctedSourceText
        self.correctedTranslatedText = correctedTranslatedText
        self.timestamp = timestamp
    }

    init(
        id: UUID,
        sourceText: String,
        translatedText: String,
        timestamp: Date = Date()
    ) {
        self.init(
            id: id,
            sourceID: "unknown",
            sourceName: "Unknown Source",
            sourceLanguageID: "unknown",
            targetLanguageID: "unknown",
            localSourceText: sourceText,
            localTranslatedText: translatedText,
            timestamp: timestamp
        )
    }

    private func effectiveText(_ correction: String?, fallingBackTo localText: String) -> String {
        guard let correction,
              correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return localText
        }
        return correction
    }
}
