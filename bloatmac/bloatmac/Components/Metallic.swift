import SwiftUI

// MARK: - Public API

extension View {
    /// Apply a brushed-metal finish to a small atomic card.
    /// Intentionally NOT applied to large screen-section panels.
    func metallic(radius: CGFloat = 14) -> some View {
        modifier(MetallicCard(radius: radius))
    }
}

// MARK: - The modifier

struct MetallicCard: ViewModifier {
    let radius: CGFloat

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hover = false
    @State private var pointer: CGPoint = .init(x: 0.5, y: 0.5)        // raw, latest cursor position (0..1)
    @State private var animated: CGPoint = .init(x: 0.5, y: 0.5)       // spring-smoothed
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
            // Ambient pan on idle: a slow Lissajous around the center.
            let t = ctx.date.timeIntervalSinceReferenceDate
            let idle = CGPoint(
                x: 0.5 + (reduceMotion ? 0 : 0.06 * sin(t / 4.0)),
                y: 0.5 + (reduceMotion ? 0 : 0.06 * cos(t / 5.5))
            )
            let p = hover ? animated : idle

            let dx = p.x - 0.5
            let dy = p.y - 0.5
            let edgeness = min(1, max(abs(dx), abs(dy)) * 2)        // 0 at center, 1 at edge — Fresnel proxy
            let specOpacity = (hover ? 0.10 : 0.04) + 0.14 * edgeness
            let tilt = reduceMotion ? 0.0 : 6.0
            let tiltX = -dy * tilt
            let tiltY = dx * tilt

            content
                .background(substrate)
                .overlay(grain.allowsHitTesting(false))
                .overlay(reflection.allowsHitTesting(false))
                .overlay(bevel.allowsHitTesting(false))
                .clipShape(shape)
                .compositingGroup()
                .rotation3DEffect(.degrees(tiltX), axis: (1, 0, 0), anchor: .center, anchorZ: 0, perspective: 0.6)
                .rotation3DEffect(.degrees(tiltY), axis: (0, 1, 0), anchor: .center, anchorZ: 0, perspective: 0.6)
                .shadow(color: .black.opacity(hover ? 0.22 : 0.08),
                        radius: hover ? 14 : 4,
                        x: hover ? CGFloat(dx) * 8 : 0,
                        y: hover ? 10 : 2)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { _, n in size = n }
            }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                let w = max(size.width, 1)
                let h = max(size.height, 1)
                let normalized = CGPoint(
                    x: min(1, max(0, pt.x / w)),
                    y: min(1, max(0, pt.y / h))
                )
                pointer = normalized
                if !hover { hover = true }
                withAnimation(.interpolatingSpring(stiffness: 200, damping: 24)) {
                    animated = normalized
                }
            case .ended:
                hover = false
                withAnimation(.easeOut(duration: 0.32)) {
                    animated = .init(x: 0.5, y: 0.5)
                }
            }
        }
    }

    // MARK: - Layers

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var substrate: some View {
        // Keep current panel color; nudge it slightly cooler/darker on hover so the metal "lights up".
        shape
            .fill(Tokens.bgPanel)
            .overlay(
                shape.fill(Color.white.opacity(scheme == .dark ? (hover ? 0.025 : 0) : (hover ? 0.04 : 0)))
            )
    }

    private var grain: some View {
        MetallicGrain(scheme: scheme)
            .opacity(scheme == .dark ? 0.55 : 0.40)
            .blendMode(.overlay)
    }

    private var reflection: some View {
        // Sky/ground bias: lighter top, darker bottom — sells "raised metal slab".
        LinearGradient(
            colors: scheme == .dark
                ? [Color.white.opacity(0.05), .clear, Color.black.opacity(0.10)]
                : [Color.white.opacity(0.18), .clear, Color.black.opacity(0.05)],
            startPoint: .top, endPoint: .bottom
        )
        .blendMode(.plusLighter)
    }

    private func specular(at p: CGPoint, opacity: Double) -> some View {
        // Anisotropic hotspot: wide along grain direction (12° from vertical), narrow across.
        // The radial is squashed and rotated so it reads as brushed, not polished.
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height) * 0.6
            let center = UnitPoint(x: p.x, y: p.y)
            RadialGradient(
                colors: [Color.white.opacity(opacity), .clear],
                center: center,
                startRadius: 0,
                endRadius: r
            )
            .scaleEffect(x: 1.6, y: 0.45, anchor: center)
            .rotationEffect(.degrees(12), anchor: center)
            .blendMode(.plusLighter)
        }
    }

    private var bevel: some View {
        // 1px lit edge top, 1px shadow edge bottom — gives a raised slab cue.
        shape
            .strokeBorder(
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color.white.opacity(0.18), Color.white.opacity(0.04), Color.black.opacity(0.25)]
                        : [Color.white.opacity(0.85), Color.white.opacity(0.2), Color.black.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

// MARK: - Grain (anisotropic, deterministic)

struct MetallicGrain: View {
    let scheme: ColorScheme

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            // Deterministic so the grain doesn't shimmer between renders.
            var rng = SeededGenerator(state: 0xC0FFEE_BABE)
            // ~1 stroke per 350 pixels² — keeps density constant on resize.
            let count = max(200, Int(size.width * size.height / 350))
            let angle = 12.0 * .pi / 180.0
            let dxBase = cos(angle), dyBase = sin(angle)

            for _ in 0..<count {
                let x = Double.uniform(0..<size.width, using: &rng)
                let y = Double.uniform(0..<size.height, using: &rng)
                let len = Double.uniform(3..<14, using: &rng)
                let alpha = Double.uniform(0.05..<0.13, using: &rng)
                let lineColor = scheme == .dark
                    ? Color.white.opacity(alpha)
                    : Color.black.opacity(alpha * 0.85)

                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + len * dxBase, y: y + len * dyBase))
                ctx.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            }
        }
        .drawingGroup()   // rasterize to a GPU texture once
    }
}

// MARK: - RNG helpers

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        // splitmix64
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension Double {
    static func uniform(_ range: Range<Double>, using rng: inout SeededGenerator) -> Double {
        let u = Double(rng.next() >> 11) / Double(1 << 53)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }
}
