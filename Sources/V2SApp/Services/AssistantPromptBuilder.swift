import Foundation

struct AssistantPromptBuilder {
    func build(
        action: AssistantAction,
        snapshot: AssistantTranscriptSnapshot,
        settings: AssistantSettings,
        currentTime: Date,
        hasScreenshot: Bool,
        ocrText: String?
    ) -> AssistantPrompt {
        let transcriptLines = snapshot.entries.map(transcriptLine)
        let transcript = snapshot.entries.contains(where: hasConversationContent)
            ? transcriptLines.joined(separator: "\n")
            : "(No transcript yet.)"

        var instructions = """
        You are an on-screen conversation assistant for v2s. Use the transcript, timing, source name, and screenshot context together. Be concise, practical, and preserve names and technical terms.
        """

        if settings.autoDetectConversationLanguages {
            instructions += "\nAutomatically detect the conversation languages from the transcript, considering configured input \(snapshot.inputLanguageName) (\(snapshot.inputLanguageID)) and output \(snapshot.outputLanguageName) (\(snapshot.outputLanguageID))."
        } else {
            instructions += "\nUse the configured input and output languages: \(snapshot.inputLanguageName) (\(snapshot.inputLanguageID)) and \(snapshot.outputLanguageName) (\(snapshot.outputLanguageID))."
        }

        let skills = trimmed(settings.skills)
        if !skills.isEmpty {
            instructions += "\nUser skills/instructions:\n\(skills)"
        }
        instructions += actionInstruction(for: action)

        var userContent = """
        Action: \(actionTitle(action))
        Source name: \(snapshot.sourceName)
        Current time: \(timestamp(currentTime))
        Input language: \(snapshot.inputLanguageName) (\(snapshot.inputLanguageID))
        Output language: \(snapshot.outputLanguageName) (\(snapshot.outputLanguageID))

        Previous conversation content:
        \(transcript)

        \(hasScreenshot ? "An image is attached to this request." : "No image is attached to this request.")
        """

        let ocr = trimmed(ocrText ?? "")
        if !ocr.isEmpty {
            userContent += "\n\nScreen text (OCR):\n\(ocr)"
        }
        userContent += "\n\n\(actionPromptSuffix(for: action))"

        return AssistantPrompt(instructions: instructions, userContent: userContent)
    }

    private func hasConversationContent(_ entry: AssistantTranscriptEntry) -> Bool {
        !trimmed(entry.sourceText).isEmpty || !trimmed(entry.translatedText).isEmpty
    }

    private func transcriptLine(_ entry: AssistantTranscriptEntry) -> String {
        """
        - time: \(timestamp(entry.timestamp))
          original: \(displayText(entry.sourceText))
          translation: \(displayText(entry.translatedText))
        """
    }

    private func actionInstruction(for action: AssistantAction) -> String {
        switch action {
        case .ask:
            "\nFor Ask, answer the user's likely explicit question from the visible screen and transcript. If intent is ambiguous, state the best interpretation first."
        case .followUp:
            "\nFor Follow Up, infer a natural next response, continuation, or question from the conversation context rather than answering an explicit question."
        }
    }

    private func actionPromptSuffix(for action: AssistantAction) -> String {
        switch action {
        case .ask:
            "Ask: answer the explicit or likely question using this context."
        case .followUp:
            "Follow Up: provide a natural next response, continuation, or question based on the conversation rather than answering an explicit question."
        }
    }

    private func actionTitle(_ action: AssistantAction) -> String {
        switch action {
        case .ask: "Ask"
        case .followUp: "Follow Up"
        }
    }

    private func displayText(_ text: String) -> String {
        let value = trimmed(text)
        return value.isEmpty ? "-" : value
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
