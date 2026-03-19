import SwiftUI

struct SessionActionButtonLabel: View {
    let title: String
    let showsActivity: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showsActivity {
                SessionWaitIndicator()
            }

            Text(title)
        }
    }
}

private struct SessionWaitIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
            .onDisappear {
                isAnimating = false
            }
            .accessibilityHidden(true)
    }
}
