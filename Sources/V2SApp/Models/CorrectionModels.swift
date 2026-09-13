import Foundation

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

    private func effectiveText(_ correction: String?, fallingBackTo localText: String) -> String {
        guard let correction,
              correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return localText
        }
        return correction
    }
}
