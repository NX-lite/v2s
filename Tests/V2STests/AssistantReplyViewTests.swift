import Foundation
import Testing
@testable import v2s

@Suite struct AssistantReplyViewTests {
    @Test func presentationSelectsNewestReplyMinusOffsetAndKeepsProviderText() {
        let older = AssistantReply(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            action: .followUp,
            content: .response("Provider reply: do not translate this.")
        )
        let newer = AssistantReply(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            action: .ask,
            content: .thinking
        )

        let presentation = AssistantReplyPresentation.resolve(
            replies: [older, newer],
            replyScrollOffset: 1,
            screenStatus: .ocrFailed,
            languageID: "zh-Hans"
        )

        #expect(presentation?.reply == older)
        #expect(presentation?.actionTitle == "追问")
        #expect(presentation?.text == "Provider reply: do not translate this.")
        #expect(presentation?.warning == "已发送当前屏幕，但无法识别其中的文字。")
    }

    @Test func presentationOnlyIncludesWarningForWarningStatuses() {
        let reply = AssistantReply(id: UUID(), action: .ask, content: .thinking)

        let presentation = AssistantReplyPresentation.resolve(
            replies: [reply],
            replyScrollOffset: 0,
            screenStatus: .screenshotSent,
            languageID: "en"
        )

        #expect(presentation?.actionTitle == "Ask")
        #expect(presentation?.text == "Thinking…")
        #expect(presentation?.warning == nil)
    }

    @Test func presentationReturnsNilForEmptyReplyHistory() {
        #expect(
            AssistantReplyPresentation.resolve(
                replies: [],
                replyScrollOffset: 0,
                screenStatus: .ready,
                languageID: "en"
            ) == nil
        )
    }
}
