import SwiftUI

struct PressureGauge: View {
    let value: Double  // 0..1
    var label: String = "Memory Pressure"
    var showLabel: Bool = true

    var status: (text: String, color: Color) {
        if value > 0.8 { return ("High", Tokens.danger) }
        if value > 0.5 { return ("Medium", Tokens.warn) }
        return ("Low", Tokens.good)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLabel {
                HStack {
                    Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                    Spacer()
                    Text(status.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(status.color)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.bgPanel2)
                    LinearGradient(
                        stops: [
                            .init(color: Tokens.good.opacity(0.2),   location: 0),
                            .init(color: Tokens.good.opacity(0.2),   location: 0.5),
                            .init(color: Tokens.warn.opacity(0.2),   location: 0.5),
                            .init(color: Tokens.warn.opacity(0.2),   location: 0.8),
                            .init(color: Tokens.danger.opacity(0.2), location: 0.8),
                            .init(color: Tokens.danger.opacity(0.2), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(Capsule())
                    Capsule().fill(status.color)
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                        .animation(.easeOut(duration: 0.7), value: value)
                }
            }
            .frame(height: 12)
        }
    }
}
