import SwiftUI

struct ActionError: View {
    let message: String?
    var body: some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Tokens.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Tokens.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Action needs attention: \(message)")
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(state.accent.gradient)
                // Pause with the aurora: no perpetual symbol animation while
                // the window is in the background.
                .symbolEffect(.breathe, options: .repeating,
                              isActive: !reduceMotion && activeState != .inactive)
                .frame(width: 88, height: 88)
                .background(
                    ZStack {
                        Circle().fill(state.accent.soft.opacity(0.5))
                        Circle().fill(.ultraThinMaterial)
                        Circle().strokeBorder(
                            LinearGradient(colors: [Tokens.glassHighlight, Tokens.border],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    }
                )
                .shadow(color: state.accent.glow.opacity(0.25), radius: 24)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Tokens.text)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if let actionLabel, let action {
                Btn(label: actionLabel, icon: "arrow.clockwise", style: .primary, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
