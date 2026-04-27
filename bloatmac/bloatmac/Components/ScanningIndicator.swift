import SwiftUI

/// A pulsing dot with an outward glow ring — drop next to a label that updates while a long task runs.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.9), radius: pulse ? size * 0.9 : size * 0.3)
            Circle()
                .stroke(color, lineWidth: 1.2)
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 2.6 : 1)
                .opacity(pulse ? 0 : 0.7)
        }
        .frame(width: size * 3, height: size * 3)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Sweeps a soft highlight across whatever it modifies — applied to the subtitle text during scans.
struct Shimmer: ViewModifier {
    var active: Bool
    var color: Color = .white
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: color.opacity(0.55), location: 0.45),
                                .init(color: color.opacity(0.55), location: 0.55),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.55)
                        .offset(x: phase * (w + w * 0.55) - w * 0.55)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: active) { _, now in
                if now { startLoop() } else { phase = -1 }
            }
            .onAppear { if active { startLoop() } }
    }

    private func startLoop() {
        phase = -0.2
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            phase = 1.2
        }
    }
}

extension View {
    func shimmer(active: Bool, color: Color = .white) -> some View {
        modifier(Shimmer(active: active, color: color))
    }
}
