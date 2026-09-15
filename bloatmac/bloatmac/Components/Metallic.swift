import SwiftUI

// MARK: - Public API

extension View {
    /// Frosted-glass finish for small atomic cards: shared Glass layers plus
    /// hover lift, accent glow, and a cursor spotlight.
    /// Intentionally NOT applied to large screen-section panels — see `glassPanel`.
    func metallic(radius: CGFloat = Tokens.Radius.lg) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

// MARK: - The modifier

struct GlassCard: ViewModifier {
    let radius: CGFloat

    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hover = false
    @State private var pointer: CGPoint = .init(x: 0.5, y: 0.5)   // spring-smoothed cursor (0..1)
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(Glass.substrate(shape))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { size = geo.size }
                        .onChange(of: geo.size) { _, n in size = n }
                }
            )
            .overlay(Glass.sheen(scheme).allowsHitTesting(false))
            .overlay(spotlight.allowsHitTesting(false))
            .overlay(hairline.allowsHitTesting(false))
            .clipShape(shape)
            .compositingGroup()
            .offset(y: hover && !reduceMotion ? -2 : 0)
            .scaleEffect(hover && !reduceMotion ? 1.004 : 1)
            .shadow(color: hover ? state.accent.glow.opacity(0.25) : Tokens.glassShadow.opacity(scheme == .dark ? 0.6 : 1),
                    radius: hover ? 22 : 10,
                    y: hover ? 12 : 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover)
            // Hit-test the unmoved layout frame: the lift offset above is
            // render-only inside this shape, so a cursor resting on the
            // bottom edge can't trigger a hover/unhover oscillation.
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt):
                    if !hover { hover = true }
                    // Cursor tracking only feeds the spotlight; skip the
                    // per-mousemove state churn entirely under Reduce Motion.
                    guard !reduceMotion else { return }
                    let normalized = CGPoint(
                        x: min(1, max(0, pt.x / max(size.width, 1))),
                        y: min(1, max(0, pt.y / max(size.height, 1)))
                    )
                    withAnimation(.interpolatingSpring(stiffness: 200, damping: 24)) {
                        pointer = normalized
                    }
                case .ended:
                    hover = false
                    guard !reduceMotion else { return }
                    withAnimation(.easeOut(duration: 0.32)) {
                        pointer = .init(x: 0.5, y: 0.5)
                    }
                }
            }
    }

    // MARK: - Layers

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// Cursor-following radial glow — the "alive" micro-interaction.
    @ViewBuilder private var spotlight: some View {
        if hover && !reduceMotion {
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: UnitPoint(x: pointer.x, y: pointer.y),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.7
            )
            .blendMode(.plusLighter)
        }
    }

    private var hairline: some View {
        // Shared hairline recipe, with a whisper of accent along the bottom
        // that brightens on hover.
        Glass.hairline(shape, bottom: state.accent.value.opacity(hover ? 0.35 : 0.10))
    }
}
