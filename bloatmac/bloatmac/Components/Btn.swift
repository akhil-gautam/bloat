import SwiftUI

enum BtnStyle { case primary, secondary, danger, ghost }

struct Btn: View {
    let label: String
    var icon: String? = nil
    var style: BtnStyle = .secondary
    let action: () -> Void
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(bg)
            .foregroundStyle(fg)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: style == .ghost ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    var bg: Color {
        switch style {
        case .primary:   return hover ? state.accent.hover : state.accent.value
        case .secondary: return hover ? Tokens.bgHover : Tokens.bgPanel
        case .danger:    return Tokens.danger
        case .ghost:     return hover ? Tokens.bgHover : .clear
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
}
