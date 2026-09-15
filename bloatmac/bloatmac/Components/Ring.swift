import SwiftUI

struct Ring: View {
    let value: Double  // 0..1
    var size: CGFloat = 64
    var stroke: CGFloat = 6
    var color: Color = .blue
    var label: String? = nil

    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Tokens.bgPanel2, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: animated)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.7), color], center: .center),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.4), radius: stroke * 0.8)
            if let label {
                Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.text)
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { animated = value } }
        .onChange(of: value) { _, v in withAnimation(.easeOut(duration: 0.7)) { animated = v } }
    }
}
