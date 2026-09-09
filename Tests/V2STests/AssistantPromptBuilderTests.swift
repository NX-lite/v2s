import Foundation
import Testing
@testable import v2s

@Suite struct AssistantPromptBuilderTests {
    @Test func askPromptIsDeterministicAndIncludesAllContext() throws {
        let builder = AssistantPromptBuilder()
        let settings = settings(skills: "  Prefer concise answers.  ", autoDetect: true)
        let snapshot = AssistantTranscriptSnapshot(
            sourceName: "Team Standup",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [
                AssistantTranscriptEntry(timestamp: Date(timeIntervalSince1970: 60), sourceText: " Hello ", translatedText: " 你好 "),
                AssistantTranscriptEntry(timestamp: Date(timeIntervalSince1970: 0), sourceText: "Next step?", translatedText: "下一步？"),
            ]
        )
        let currentTime = Date(timeIntervalSince1970: 120)

        let first = builder.build(
            action: .ask,
            snapshot: snapshot,
            settings: settings,
            currentTime: currentTime,
            hasScreenshot: true,
            ocrText: "  Screen title  "
        )
        let second = builder.build(
            action: .ask,
            snapshot: snapshot,
            settings: settings,
            currentTime: currentTime,
            hasScreenshot: true,
            ocrText: "  Screen title  "
        )

        #expect(first == second)
        #expect(first.userContent.contains("Current time: 1970-01-01T00:02:00Z"))
        #expect(first.userContent.contains("1970-01-01T00:01:00Z"))
        #expect(first.userContent.contains("Source name: Team Standup"))
        #expect(first.userContent.contains("Input language: English (en)"))
        #expect(first.userContent.contains("Output language: Simplified Chinese (zh-Hans)"))
        let transcriptAndSuffix = try #require(
            first.userContent
                .components(separatedBy: "Previous conversation content:\n")
                .last
        )
        let transcript = try #require(
            transcriptAndSuffix
                .components(separatedBy: "\n\nAn image is attached to this request.")
                .first
        )
        #expect(transcript == """
        - time: 1970-01-01T00:01:00Z
          original: Hello
          translation: 你好
        - time: 1970-01-01T00:00:00Z
          original: Next step?
          translation: 下一步？
        """)
        #expect(first.userContent.contains("An image is attached to this request."))
        #expect(first.userContent.contains("Screen text (OCR):\nScreen title"))
        #expect(first.instructions.contains("User skills/instructions:\nPrefer concise answers."))
        #expect(first.instructions.contains("For Ask"))
    }

    @Test func followUpUsesDistinctActionInstruction() {
        let builder = AssistantPromptBuilder()
        let snapshot = sampleSnapshot()
        let settings = settings(skills: "", autoDetect: false)

        let ask = builder.build(action: .ask, snapshot: snapshot, settings: settings, currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)
        let followUp = builder.build(action: .followUp, snapshot: snapshot, settings: settings, currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)

        #expect(ask.instructions != followUp.instructions)
        #expect(ask.userContent != followUp.userContent)
        #expect(followUp.instructions.contains("For Follow Up"))
        #expect(followUp.instructions.contains("natural next response, continuation, or question"))
        #expect(followUp.instructions.contains("rather than answering an explicit question"))
        #expect(ask.instructions.contains("For Ask"))
    }

    @Test func noOCRDoesNotEmitOCRSection() {
        let builder = AssistantPromptBuilder()
        let prompt = builder.build(
            action: .ask,
            snapshot: sampleSnapshot(),
            settings: settings(skills: "", autoDetect: false),
            currentTime: Date(timeIntervalSince1970: 120),
            hasScreenshot: true,
            ocrText: " \n \t "
        )

        #expect(!prompt.userContent.contains("Screen text (OCR):"))
        #expect(prompt.userContent.contains("An image is attached to this request."))
    }

    @Test func emptyTranscriptUsesExplicitPlaceholder() {
        let whitespaceOnlySnapshot = AssistantTranscriptSnapshot(
            sourceName: "Silent Source",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [
                AssistantTranscriptEntry(timestamp: .distantPast, sourceText: " ", translatedText: "\n"),
                AssistantTranscriptEntry(timestamp: .distantFuture, sourceText: "\t", translatedText: " "),
            ]
        )
        let emptyEntriesSnapshot = AssistantTranscriptSnapshot(
            sourceName: "Silent Source",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: []
        )
        let builder = AssistantPromptBuilder()

        let imagePrompt = builder.build(
            action: .followUp,
            snapshot: emptyEntriesSnapshot,
            settings: settings(skills: "", autoDetect: false),
            currentTime: Date(timeIntervalSince1970: 120),
            hasScreenshot: true,
            ocrText: "  Visible window title  "
        )
        let textOnlyPrompt = builder.build(
            action: .ask,
            snapshot: whitespaceOnlySnapshot,
            settings: settings(skills: "", autoDetect: false),
            currentTime: Date(timeIntervalSince1970: 120),
            hasScreenshot: false,
            ocrText: nil
        )

        #expect(imagePrompt.userContent.contains("Previous conversation content:\n(No transcript yet.)"))
        #expect(imagePrompt.userContent.contains("An image is attached to this request."))
        #expect(imagePrompt.userContent.contains("Screen text (OCR):\nVisible window title"))
        #expect(imagePrompt.userContent.contains("Follow Up: provide a natural next response"))
        #expect(textOnlyPrompt.userContent.contains("Previous conversation content:\n(No transcript yet.)"))
        #expect(textOnlyPrompt.userContent.contains("No image is attached to this request."))
        #expect(textOnlyPrompt.userContent.contains("Ask: answer the explicit or likely question"))
    }

    @Test func singleSidedEntryUsesDashAndAutoDetectSettingChangesInstructions() {
        let snapshot = AssistantTranscriptSnapshot(
            sourceName: "Team Standup",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [AssistantTranscriptEntry(timestamp: Date(timeIntervalSince1970: 0), sourceText: "Only source", translatedText: " ")]
        )
        let builder = AssistantPromptBuilder()
        let detected = builder.build(action: .ask, snapshot: snapshot, settings: settings(skills: "", autoDetect: true), currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)
        let configured = builder.build(action: .ask, snapshot: snapshot, settings: settings(skills: "", autoDetect: false), currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)

        #expect(detected.userContent.contains("translation: -"))
        #expect(detected.instructions.contains("Automatically detect the conversation languages"))
        #expect(configured.instructions.contains("Use the configured input and output languages"))
    }

    private func sampleSnapshot() -> AssistantTranscriptSnapshot {
        AssistantTranscriptSnapshot(
            sourceName: "Team Standup",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [AssistantTranscriptEntry(timestamp: Date(timeIntervalSince1970: 0), sourceText: "Hello", translatedText: "你好")]
        )
    }

    private func settings(skills: String, autoDetect: Bool) -> AssistantSettings {
        var result = AssistantSettings.default
        result.skills = skills
        result.autoDetectConversationLanguages = autoDetect
        return result
    }
}
