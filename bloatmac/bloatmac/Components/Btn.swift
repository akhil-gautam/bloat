import SwiftUI

enum BtnStyle { case primary, secondary, danger, ghost }

struct Btn: View {
    let label: String
    var icon: String? = nil
    var style: BtnStyle = .secondary
    let action: () -> Void
    @EnvironmentObject var state: AppState
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(background)
            .foregroundStyle(fg)
            .overlay(innerHighlight)
            .overlay(Capsule().strokeBorder(border, lineWidth: style == .ghost ? 0 : 1))
            .clipShape(Capsule())
            .shadow(color: glowColor, radius: hover ? 12 : 0, y: hover ? 4 : 0)
            .scaleEffect(hover && !reduceMotion ? 1.02 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .primary:
            LinearGradient(
                colors: hover
                    ? [state.accent.hover, state.accent.companion]
                    : [state.accent.value, state.accent.companion],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .secondary:
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(hover ? Tokens.bgHover : Tokens.bgPanel)
            }
        case .danger:
            LinearGradient(
                colors: [Tokens.danger, Tokens.dangerCompanion],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(Color.white.opacity(hover ? 0.12 : 0))
        case .ghost:
            Capsule().fill(hover ? Tokens.bgHover : Color.clear)
        }
    }

    /// "Lit from above" 1pt inner top edge on filled styles.
    @ViewBuilder private var innerHighlight: some View {
        if style == .primary || style == .danger {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
    }

    var fg: Color {
        switch style {
        case .primary, .danger: return .white
        default: return Tokens.text
        }
    }
    var border: Color {
        switch style {
        case .secondary: return Tokens.border
        default: return .clear
        }
    }
    var glowColor: Color {
        guard hover else { return .clear }
        switch style {
        case .primary: return state.accent.glow
        case .danger:  return Tokens.danger.opacity(0.4)
        default:       return .clear
        }
    }
}

/// Squish press feedback shared by all Btn styles.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
