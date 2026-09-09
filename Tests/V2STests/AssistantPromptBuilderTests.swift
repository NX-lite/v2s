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

        let first = try builder.build(
            action: .ask,
            snapshot: snapshot,
            settings: settings,
            currentTime: currentTime,
            hasScreenshot: true,
            ocrText: "  Screen title  "
        )
        let second = try builder.build(
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

    @Test func followUpUsesDistinctActionInstruction() throws {
        let builder = AssistantPromptBuilder()
        let snapshot = sampleSnapshot()
        let settings = settings(skills: "", autoDetect: false)

        let ask = try builder.build(action: .ask, snapshot: snapshot, settings: settings, currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)
        let followUp = try builder.build(action: .followUp, snapshot: snapshot, settings: settings, currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)

        #expect(ask.instructions != followUp.instructions)
        #expect(ask.userContent != followUp.userContent)
        #expect(followUp.instructions.contains("For Follow Up"))
        #expect(followUp.instructions.contains("natural next response, continuation, or question"))
        #expect(followUp.instructions.contains("rather than answering an explicit question"))
        #expect(ask.instructions.contains("For Ask"))
    }

    @Test func noOCRDoesNotEmitOCRSection() throws {
        let builder = AssistantPromptBuilder()
        let prompt = try builder.build(
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

    @Test func emptyTranscriptThrowsBeforeAnyProviderWork() {
        let emptySnapshot = AssistantTranscriptSnapshot(
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

        #expect(throws: AssistantPromptBuilder.BuildError.emptyTranscript) {
            try AssistantPromptBuilder().build(
                action: .ask,
                snapshot: emptySnapshot,
                settings: settings(skills: "", autoDetect: false),
                currentTime: Date(timeIntervalSince1970: 120),
                hasScreenshot: false,
                ocrText: nil
            )
        }
    }

    @Test func singleSidedEntryUsesDashAndAutoDetectSettingChangesInstructions() throws {
        let snapshot = AssistantTranscriptSnapshot(
            sourceName: "Team Standup",
            inputLanguageID: "en",
            inputLanguageName: "English",
            outputLanguageID: "zh-Hans",
            outputLanguageName: "Simplified Chinese",
            entries: [AssistantTranscriptEntry(timestamp: Date(timeIntervalSince1970: 0), sourceText: "Only source", translatedText: " ")]
        )
        let builder = AssistantPromptBuilder()
        let detected = try builder.build(action: .ask, snapshot: snapshot, settings: settings(skills: "", autoDetect: true), currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)
        let configured = try builder.build(action: .ask, snapshot: snapshot, settings: settings(skills: "", autoDetect: false), currentTime: Date(timeIntervalSince1970: 120), hasScreenshot: false, ocrText: nil)

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
