import SwiftUI

struct Sparkline: View {
    let data: [Double]
    var stroke: Color = .blue
    var fill: Bool = true
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let mn = data.min() ?? 0
            let mx = data.max() ?? 1
            let span = max(0.0001, mx - mn)
            let pts: [CGPoint] = data.enumerated().map { i, v in
                let x = CGFloat(i) / CGFloat(max(1, data.count - 1)) * w
                let y = h - CGFloat((v - mn) / span) * (h - 2) - 1
                return CGPoint(x: x, y: y)
            }
            let line = Path { p in
                guard let first = pts.first else { return }
                p.move(to: first); for q in pts.dropFirst() { p.addLine(to: q) }
            }
            ZStack {
                if fill {
                    let area = Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: first); for q in pts.dropFirst() { p.addLine(to: q) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    area.fill(LinearGradient(colors: [stroke.opacity(0.28), stroke.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                line.stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
