import Foundation

enum AssistantAction: String, Equatable, Sendable {
    case followUp
    case ask
}

enum OverlayViewMode: Equatable, Sendable {
    case subtitles
    case assistantReplies
}

enum AssistantRequestState: Equatable, Sendable {
    case idle
    case running(AssistantAction)
    case failed(String)
}

enum AssistantModelFetchState: Equatable, Sendable {
    case idle
    case fetching
    case fetched([String])
    case failed(String)
}

enum AssistantAPITestState: Equatable, Sendable {
    case idle
    case testing
    case passed(String)
    case failed(String)
}

struct AssistantTranscriptEntry: Equatable, Sendable {
    let timestamp: Date
    let sourceText: String
    let translatedText: String
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
    let title: String
    let text: String
}
