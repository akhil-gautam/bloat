import SwiftUI

// MARK: - Shared glass layers
// Single source of truth for the "frosted glass" recipe used by both the
// static `glassPanel` (large sections) and the hoverable `metallic` cards.

enum Glass {
    /// Backdrop-blurred substrate tinted by the translucent panel token.
    static func substrate(_ shape: some InsettableShape) -> some View {
        shape.fill(.ultraThinMaterial).overlay(shape.fill(Tokens.bgPanel))
    }

    /// Faint top light so the glass reads lit from above.
    static func sheen(_ scheme: ColorScheme) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(scheme == .dark ? 0.06 : 0.20), location: 0),
                .init(color: .clear, location: 0.3),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .blendMode(.plusLighter)
    }

    /// Signature gradient hairline: bright top edge fading down into `bottom`.
    static func hairline(_ shape: some InsettableShape, bottom: Color) -> some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [Tokens.glassHighlight, Tokens.glassHighlight.opacity(0.18), bottom],
                startPoint: .top, endPoint: .bottom
            ),
            lineWidth: 1
        )
    }
}

// MARK: - Glass panel (static)

extension View {
    /// Frosted-glass surface for large section panels: material blur, panel
    /// tint, gradient hairline. The static, non-hover sibling of `.metallic()`.
    func glassPanel(radius: CGFloat = Tokens.Radius.lg) -> some View {
        modifier(GlassPanelStyle(radius: radius))
    }
}

struct GlassPanelStyle: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(Glass.substrate(shape))
            .overlay(Glass.sheen(scheme).allowsHitTesting(false))
            .overlay(Glass.hairline(shape, bottom: Tokens.border).allowsHitTesting(false))
            .clipShape(shape)
    }
}

// MARK: - Glass chip (small controls)

extension View {
    /// Small glass control chip — topbar buttons, filter menus: material
    /// capsule (or any insettable shape) + panel tint + hairline border.
    func glassChip(border: some ShapeStyle = Tokens.border) -> some View {
        glassChip(Capsule(), border: border)
    }

    func glassChip(_ shape: some InsettableShape, border: some ShapeStyle = Tokens.border) -> some View {
        self
            .background(shape.fill(Tokens.bgPanel))       // tint in front of the blur,
            .background(shape.fill(.ultraThinMaterial))   // matching Glass.substrate
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}
