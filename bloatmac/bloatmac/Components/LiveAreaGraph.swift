import SwiftUI
import Combine

struct LiveAreaGraph: View {
    var height: CGFloat = 160
    var color: Color = .blue
    var generate: (Double) -> Double = { last in
        max(0.05, min(0.95, last + (Double.random(in: 0...1) - 0.5) * 0.08))
    }

    @State private var data: [Double] = (0..<60).map { _ in 0.3 + Double.random(in: 0...0.4) }
    private let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            graph(in: geo.size)
        }
        .frame(height: height)
        .background(Tokens.bgPanel2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onReceive(timer) { _ in
            var d = data
            d.removeFirst()
            d.append(generate(data.last ?? 0.5))
            data = d
        }
    }

    @ViewBuilder
    private func graph(in size: CGSize) -> some View {
        let pts = points(in: size)
        ZStack {
            GridPattern().stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
            areaPath(pts: pts, size: size)
                .fill(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            linePath(pts: pts)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height
        let count = max(1, data.count - 1)
        return data.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / CGFloat(count) * w, y: h - CGFloat(v) * (h - 4) - 2)
        }
    }

    private func linePath(pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first); for q in pts.dropFirst() { p.addLine(to: q) }
        }
    }

    private func areaPath(pts: [CGPoint], size: CGSize) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first); for q in pts.dropFirst() { p.addLine(to: q) }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.addLine(to: CGPoint(x: 0, y: size.height))
            p.closeSubpath()
        }
    }
}

struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 40
        var x: CGFloat = 0
        while x < rect.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: rect.height)); x += step }
        var y: CGFloat = 0
        while y < rect.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: rect.width, y: y)); y += step }
        return p
    }
}
