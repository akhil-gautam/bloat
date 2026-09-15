import SwiftUI

/// The animated "aurora" window backdrop: a slowly drifting 3×3 mesh
/// gradient tinted by the current accent, static accent glow blooms, and a
/// film-grain Metal shader over the mesh. The timeline pauses (holding the
/// last rendered frame, zero GPU churn) under Reduce Motion or when the
/// window loses focus.
struct AuroraBackground: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    private var paused: Bool { reduceMotion || activeState == .inactive }

    var body: some View {
        ZStack {
            Tokens.bg

            // Only the mesh + grain live inside the timeline; the blooms and
            // base are static and render once. 12fps is plenty for drift
            // periods of 7–13 seconds.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: paused)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                MeshGradient(width: 3, height: 3, points: meshPoints(t: t), colors: meshColors)
                    .colorEffect(ShaderLibrary.filmGrain(
                        // Wrap in Double first — Float(rawEpochSeconds) has a
                        // ~64s ULP and would freeze the grain entirely.
                        .float(Float(t.truncatingRemainder(dividingBy: 977))),
                        .float(scheme == .dark ? 0.045 : 0.025)
                    ))
            }

            // Accent bloom pinned near the top-right corner.
            RadialGradient(
                colors: [state.accent.glow.opacity(scheme == .dark ? 0.30 : 0.20), .clear],
                center: UnitPoint(x: 0.85, y: 0.05), startRadius: 0, endRadius: 700
            )
            .blur(radius: 60)
            // Counterweight bloom bottom-left in the companion hue.
            RadialGradient(
                colors: [state.accent.companion.opacity(scheme == .dark ? 0.16 : 0.12), .clear],
                center: UnitPoint(x: 0.10, y: 0.95), startRadius: 0, endRadius: 600
            )
            .blur(radius: 60)
        }
        .ignoresSafeArea()
    }

    /// 3×3 control grid. Corners stay pinned; interior points and edge
    /// midpoints orbit on slow Lissajous curves with coprime periods so the
    /// drift never visibly loops.
    private func meshPoints(t: Double) -> [SIMD2<Float>] {
        func drift(_ x: Double, _ y: Double, ax: Double, ay: Double, px: Double, py: Double, phase: Double) -> SIMD2<Float> {
            SIMD2(Float(x + ax * sin(t / px + phase)), Float(y + ay * cos(t / py + phase)))
        }
        return [
            SIMD2(0, 0),
            drift(0.5, 0.0, ax: 0.10, ay: 0.00, px: 7, py: 9, phase: 0),
            SIMD2(1, 0),
            drift(0.0, 0.5, ax: 0.00, ay: 0.10, px: 11, py: 8, phase: 1.7),
            drift(0.5, 0.5, ax: 0.14, ay: 0.12, px: 9, py: 13, phase: 3.1),
            drift(1.0, 0.5, ax: 0.00, ay: 0.10, px: 8, py: 12, phase: 4.2),
            SIMD2(0, 1),
            drift(0.5, 1.0, ax: 0.10, ay: 0.00, px: 13, py: 7, phase: 5.6),
            SIMD2(1, 1),
        ]
    }

    /// Translucent tints composited over the solid `Tokens.bg` base, so the
    /// same mesh works for both themes — deep space in dark, pastel in light.
    private var meshColors: [Color] {
        let p = state.accent.meshPalette
        let lo: Double = scheme == .dark ? 0.10 : 0.14
        let mid: Double = scheme == .dark ? 0.20 : 0.24
        let hi: Double = scheme == .dark ? 0.30 : 0.32
        return [
            .clear,               p[2].opacity(lo),   p[0].opacity(mid),
            p[1].opacity(lo),     p[0].opacity(hi),   p[2].opacity(mid),
            p[1].opacity(mid),    p[2].opacity(lo),   .clear,
        ]
    }
}
