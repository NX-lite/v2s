import Foundation

struct CorrectionPromptBuilder {
    static let contextLimit = 6

    func build(
        job: CorrectionJob,
        context: [CorrectionContextEntry],
        mode: CorrectionInputMode
    ) -> CorrectionPrompt {
        let recentContext = Array(
            context
                .enumerated()
                .sorted(by: chronologicalOrder)
                .suffix(Self.contextLimit)
                .map(\.element)
        )

        return CorrectionPrompt(
            instructions: instructions(for: mode),
            userContent: userContent(job: job, context: recentContext, mode: mode),
            mode: mode
        )
    }

    private func chronologicalOrder(
        _ lhs: EnumeratedSequence<[CorrectionContextEntry]>.Element,
        _ rhs: EnumeratedSequence<[CorrectionContextEntry]>.Element
    ) -> Bool {
        if lhs.element.capturedAt != rhs.element.capturedAt {
            return lhs.element.capturedAt < rhs.element.capturedAt
        }
        return lhs.offset < rhs.offset
    }

    private func instructions(for mode: CorrectionInputMode) -> String {
        switch mode {
        case .audio:
            """
            Correct the current locally transcribed and translated sentence using the recent corrected context. Return exactly one JSON object with exactly two named string fields: {\"correctedOriginal\": \"\", \"correctedTranslation\": \"\"}.
            """
        case .textOnly:
            """
            Correct only the current local translation using the recent corrected context. Do not rewrite the local original. Return only correctedTranslation in exactly one JSON object with the one named string field \"correctedTranslation\".
            """
        }
    }

    private func userContent(
        job: CorrectionJob,
        context: [CorrectionContextEntry],
        mode: CorrectionInputMode
    ) -> String {
        let contextLines = context.map(contextLine).joined(separator: "\n")
        let contextSection = contextLines.isEmpty ? "(none)" : contextLines
        let responseSchema: String

        switch mode {
        case .audio:
            responseSchema = "{\"correctedOriginal\": \"\", \"correctedTranslation\": \"\"}"
        case .textOnly:
            responseSchema = "{\"correctedTranslation\": \"\"}"
        }

        return """
        Current source: \(normalized(job.sourceName)) [\(normalized(job.sourceID))]
        Source language ID: \(normalized(job.sourceLanguageID))
        Target language ID: \(normalized(job.targetLanguageID))
        Local original: \(normalized(job.localOriginal))
        Local translation: \(normalized(job.localTranslation))

        Recent corrected context:
        \(contextSection)

        Response JSON schema:
        \(responseSchema)
        """
    }

    private func contextLine(_ entry: CorrectionContextEntry) -> String {
        """
        - timestamp: \(timestamp(entry.capturedAt))
          source: \(normalized(entry.sourceName)) [\(normalized(entry.sourceID))]
          language pair: \(normalized(entry.sourceLanguageID)) -> \(normalized(entry.targetLanguageID))
          original: \(normalized(entry.original))
          translation: \(normalized(entry.translation))
        """
    }

    private func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
