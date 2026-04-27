import SwiftUI

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
