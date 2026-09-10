import SwiftUI

struct AssistantReplyPresentation: Equatable {
    let reply: AssistantReply
    let actionTitle: String
    let text: String
    let warning: String?

    static func resolve(
        replies: [AssistantReply],
        replyScrollOffset: Int,
        screenStatus: ScreenContextStatus,
        languageID: String
    ) -> AssistantReplyPresentation? {
        let clampedOffset = min(max(replyScrollOffset, 0), max(0, replies.count - 1))
        guard replies.indices.contains(replies.count - 1 - clampedOffset) else {
            return nil
        }

        let reply = replies[replies.count - 1 - clampedOffset]
        return AssistantReplyPresentation(
            reply: reply,
            actionTitle: AppLocalization.assistantActionTitle(reply.action, languageID: languageID),
            text: AppLocalization.assistantReplyText(reply.content, languageID: languageID),
            warning: screenStatus.isWarning
                ? AppLocalization.screenContextWarning(screenStatus, languageID: languageID)
                : nil
        )
    }
}

struct AssistantReplyView: View {
    @ObservedObject var assistant: AssistantCoordinator
    let languageID: String

    var body: some View {
        Group {
            if let presentation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(presentation.actionTitle)
                                .font(.headline)
                            Spacer(minLength: 0)
                            if let warning = presentation.warning {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.yellow)
                                    .help(warning)
                                    .accessibilityLabel(warning)
                            }
                        }

                        Text(presentation.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            updateVisibleReplyCount()
        }
        .onChange(of: assistant.replies.count) { _, _ in
            updateVisibleReplyCount()
        }
        .onDisappear {
            assistant.updateReplyVisibleCount(0)
        }
    }

    private var presentation: AssistantReplyPresentation? {
        AssistantReplyPresentation.resolve(
            replies: assistant.replies,
            replyScrollOffset: assistant.replyScrollOffset,
            screenStatus: assistant.screenStatus,
            languageID: languageID
        )
    }

    private func updateVisibleReplyCount() {
        assistant.updateReplyVisibleCount(assistant.replies.isEmpty ? 0 : 1)
    }
}
