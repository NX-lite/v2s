import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @State private var committedOpacity: Double = 1.0
    @State private var isResizeDragging = false
    @State private var resizeDragStartScale: Double = 1.0

    var body: some View {
        Group {
            if let state = model.overlayState {
                ZStack(alignment: .leading) {
                    VStack(alignment: .center, spacing: 6) {
                        previousCaptionLayer(state)
                        committedLayer(state)
                        draftLayer(state)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controlStrip
                        .padding(.leading, 10)
                }
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

    // MARK: - Control strip

    private var controlStrip: some View {
        VStack(spacing: 6) {
            // Drag / move handle
            OverlayMoveHandle()
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .overlay(
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .allowsHitTesting(false)
                )

            // Close / stop session
            Button { model.stopSession() } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)

            // Resize — drag up/down to scale the overlay
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
            .frame(width: 22, height: 22)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isResizeDragging {
                            isResizeDragging = true
                            resizeDragStartScale = model.overlayStyle.overlayScaleFactor
                        }
                        let delta = Double(-value.translation.height) / 120.0
                        let newScale = max(0.5, min(2.5, resizeDragStartScale + delta))
                        model.updateOverlayStyle { $0.overlayScaleFactor = newScale }
                    }
                    .onEnded { _ in isResizeDragging = false }
            )
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Previous caption layer (80% opacity, scrolls up then fades)

    @ViewBuilder
    private func previousCaptionLayer(_ state: OverlayPreviewState) -> some View {
        if let prevTranslated = state.previousTranslatedText {
            VStack(spacing: 3) {
                Text(prevTranslated)
                    .font(.system(size: model.overlayStyle.scaledTranslatedFontSize * 0.82, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.80))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                if let prevSource = state.previousSourceText, !prevSource.isEmpty {
                    Text(prevSource)
                        .font(.system(size: model.overlayStyle.scaledSourceFontSize * 0.82, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .opacity(1.0 - state.previousFadeProgress)
            .offset(y: -28 * state.previousFadeProgress)
            .animation(.easeInOut(duration: 0.5), value: state.previousFadeProgress)

            Divider()
                .overlay(Color.white.opacity(0.08 * (1.0 - state.previousFadeProgress)))
                .animation(.easeInOut(duration: 0.5), value: state.previousFadeProgress)
        }
    }

    // MARK: - Committed caption layer (main display, fades in on each new sentence)

    @ViewBuilder
    private func committedLayer(_ state: OverlayPreviewState) -> some View {
        VStack(spacing: 4) {
            if model.overlayStyle.translatedFirst {
                translatedText(for: state)
                sourceText(for: state)
            } else {
                sourceText(for: state)
                translatedText(for: state)
            }
        }
        .opacity(committedOpacity)
        .onChange(of: state.captionEpoch) { _, _ in
            committedOpacity = 0.0
            withAnimation(.easeOut(duration: 0.3)) {
                committedOpacity = 1.0
            }
        }
    }

    private func translatedText(for state: OverlayPreviewState) -> some View {
        Text(state.translatedText)
            .font(.system(size: model.overlayStyle.scaledTranslatedFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private func sourceText(for state: OverlayPreviewState) -> some View {
        Text(state.sourceText)
            .font(.system(size: model.overlayStyle.scaledSourceFontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Draft layer (50–65% opacity, stable prefix slightly brighter)

    @ViewBuilder
    private func draftLayer(_ state: OverlayPreviewState) -> some View {
        if let draftText = state.draftSourceText, !draftText.isEmpty {
            VStack(spacing: 2) {
                if let draftTranslated = state.draftTranslatedText, !draftTranslated.isEmpty {
                    Text(draftTranslated)
                        .font(.system(size: model.overlayStyle.scaledTranslatedFontSize * 0.88, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }

                let prefixLen = min(state.draftStablePrefixLength, draftText.count)
                let stable = String(draftText.prefix(prefixLen))
                let mutable = String(draftText.dropFirst(prefixLen))

                (
                    Text(stable).foregroundStyle(Color.white.opacity(0.62))
                        + Text(mutable).foregroundStyle(Color.white.opacity(0.48))
                )
                .font(.system(size: model.overlayStyle.scaledSourceFontSize, weight: .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(model.overlayStyle.backgroundOpacity))
    }
}

// MARK: - Drag handle (NSViewRepresentable — calls window.performDrag)

private struct OverlayMoveHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayMoveHandleView { OverlayMoveHandleView() }
    func updateNSView(_ nsView: OverlayMoveHandleView, context: Context) {}
}

final class OverlayMoveHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
