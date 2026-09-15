import SwiftUI

// MARK: - Staggered reveal

extension View {
    /// Fade-up entrance for the Nth section of a screen: opacity 0→1 and a
    /// 12pt rise, delayed by index. Instant under Reduce Motion.
    func staggered(_ index: Int) -> some View {
        modifier(StaggeredReveal(index: index))
    }
}

struct StaggeredReveal: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(
                        .spring(response: 0.45, dampingFraction: 0.85)
                        .delay(min(Double(index) * 0.045, 0.35))
                    ) {
                        shown = true
                    }
                }
            }
    }
}

// MARK: - Glow pulse

extension View {
    /// Breathing colored glow for in-progress states (scans, cleans).
    /// Rendered as a fixed pre-blurred halo whose opacity breathes — one
    /// property animation, no per-frame blur recompute.
    func glowPulse(active: Bool, color: Color, radius: CGFloat = Tokens.Radius.lg) -> some View {
        modifier(GlowPulse(active: active, color: color, radius: radius))
    }
}

struct GlowPulse: ViewModifier {
    let active: Bool
    let color: Color
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .blur(radius: 22)
                    .opacity(active ? (breathing && !reduceMotion ? 0.45 : 0.20) : 0)
                    .animation(
                        active && !reduceMotion
                            ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.3),
                        value: breathing
                    )
            )
            .onAppear { if active { breathing = true } }
            .onChange(of: active) { _, now in breathing = now }
    }
}
