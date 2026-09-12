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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tokens.text3)
                .frame(width: 88, height: 88)
                .background(Circle().fill(Tokens.bgPanel2))
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
        .background(Tokens.bgWindow)
    }
}
