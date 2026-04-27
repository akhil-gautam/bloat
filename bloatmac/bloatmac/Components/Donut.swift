import SwiftUI

struct DonutSegment: Hashable {
    let value: Double
    let color: Color
}

struct Donut: View {
    var size: CGFloat = 180
    var stroke: CGFloat = 22
    let segments: [DonutSegment]
    var centerLabel: String? = nil
    var centerValue: String? = nil
    var centerSub: String? = nil

    @State private var t: Double = 0

    var total: Double { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        ZStack {
            // Track
            Circle().stroke(Tokens.catFree, lineWidth: stroke)

            // Segments
            ZStack {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    let prior = segments.prefix(idx).reduce(0) { $0 + $1.value }
                    let from = (prior / total)
                    let len = (seg.value / total) * t
                    Circle()
                        .trim(from: from, to: from + len)
                        .stroke(seg.color, lineWidth: stroke)
                }
            }
            .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                if let centerLabel {
                    Text(centerLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text3)
                }
                if let centerValue {
                    Text(centerValue).font(.system(size: size > 160 ? 28 : 22, weight: .heavy)).tracking(-0.5).foregroundStyle(Tokens.text)
                }
                if let centerSub {
                    Text(centerSub).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { t = 1 } }
    }
}
