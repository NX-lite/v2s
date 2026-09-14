import Foundation

enum AssistantAction: String, Equatable, Sendable {
    case followUp
    case ask
}

enum OverlayViewMode: Equatable, Sendable {
    case subtitles
    case assistantReplies
}

enum AssistantFailure: Equatable, Sendable {
    case invalidConfiguration
    case requestFailed(detail: String?)
}

enum AssistantReplyContent: Equatable, Sendable {
    case thinking
    case response(String)
    case failure(AssistantFailure)
}

enum AssistantRequestState: Equatable, Sendable {
    case idle
    case running(AssistantAction)
    case failed(AssistantFailure)
}

enum AssistantModelFetchState: Equatable, Sendable {
    case idle
    case fetching
    case fetched([String])
    case failed(AssistantFailure)
}

enum AssistantAPITestState: Equatable, Sendable {
    case idle
    case testing
    case passed(String)
    case failed(AssistantFailure)
}

struct AssistantTranscriptEntry: Equatable, Sendable {
    let timestamp: Date
    let sourceName: String
    let sourceLanguageID: String
    let sourceLanguageName: String
    let targetLanguageID: String
    let targetLanguageName: String
    let sourceText: String
    let translatedText: String

    init(
        timestamp: Date,
        sourceName: String,
        sourceLanguageID: String,
        sourceLanguageName: String,
        targetLanguageID: String,
        targetLanguageName: String,
        sourceText: String,
        translatedText: String
    ) {
        self.timestamp = timestamp
        self.sourceName = sourceName
        self.sourceLanguageID = sourceLanguageID
        self.sourceLanguageName = sourceLanguageName
        self.targetLanguageID = targetLanguageID
        self.targetLanguageName = targetLanguageName
        self.sourceText = sourceText
        self.translatedText = translatedText
    }

    init(timestamp: Date, sourceText: String, translatedText: String) {
        self.init(
            timestamp: timestamp,
            sourceName: "Unknown Source",
            sourceLanguageID: "unknown",
            sourceLanguageName: "Unknown Language",
            targetLanguageID: "unknown",
            targetLanguageName: "Unknown Language",
            sourceText: sourceText,
            translatedText: translatedText
        )
    }
}

struct AssistantTranscriptSnapshot: Equatable, Sendable {
    let sourceName: String
    let inputLanguageID: String
    let inputLanguageName: String
    let outputLanguageID: String
    let outputLanguageName: String
    let entries: [AssistantTranscriptEntry]
}

struct AssistantPrompt: Equatable, Sendable {
    let instructions: String
    let userContent: String
}

struct AssistantReply: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: AssistantAction
    let content: AssistantReplyContent
}
