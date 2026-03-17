import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let overlayState = model.overlayState {
                VStack(alignment: .center, spacing: 8) {
                    if model.overlayStyle.translatedFirst {
                        translatedText(for: overlayState)
                        sourceText(for: overlayState)
                    } else {
                        sourceText(for: overlayState)
                        translatedText(for: overlayState)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundView)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func translatedText(for state: OverlayPreviewState) -> some View {
        Text(state.translatedText)
            .font(.system(size: model.overlayStyle.translatedFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private func sourceText(for state: OverlayPreviewState) -> some View {
        Text(state.sourceText)
            .font(.system(size: model.overlayStyle.sourceFontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(model.overlayStyle.backgroundOpacity))
    }
}
