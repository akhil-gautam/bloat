import SwiftUI

enum AccentKey: String, CaseIterable, Identifiable {
    case blue, purple, green, orange, pink
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var value: Color {
        switch self {
        case .blue:   return Color(hex: 0x4D8DFF)
        case .purple: return Color(hex: 0xA78BFA)
        case .green:  return Color(hex: 0x34D399)
        case .orange: return Color(hex: 0xFB923C)
        case .pink:   return Color(hex: 0xF472B6)
        }
    }
    var hover: Color {
        switch self {
        case .blue:   return Color(hex: 0x6BA1FF)
        case .purple: return Color(hex: 0xBBA5FC)
        case .green:  return Color(hex: 0x51DBA6)
        case .orange: return Color(hex: 0xFCA65C)
        case .pink:   return Color(hex: 0xF68BC4)
        }
    }
    var soft: Color { value.opacity(0.14) }

    /// Second gradient stop — every accent pairs with a companion hue so
    /// primary surfaces read as gradients, not flat fills.
    var companion: Color {
        switch self {
        case .blue:   return Color(hex: 0x7C5CFF)
        case .purple: return Color(hex: 0xF472B6)
        case .green:  return Color(hex: 0x22D3EE)
        case .orange: return Color(hex: 0xF43F5E)
        case .pink:   return Color(hex: 0xA78BFA)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [value, companion], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Shadow color for accent glows around focused / hovered elements.
    var glow: Color { value.opacity(0.45) }

    /// Hues feeding the aurora mesh background. Ordered from dominant to faint.
    var meshPalette: [Color] {
        switch self {
        case .blue:   return [Color(hex: 0x4D8DFF), Color(hex: 0x7C5CFF), Color(hex: 0x22D3EE)]
        case .purple: return [Color(hex: 0xA78BFA), Color(hex: 0xF472B6), Color(hex: 0x7C5CFF)]
        case .green:  return [Color(hex: 0x34D399), Color(hex: 0x22D3EE), Color(hex: 0x4ADE80)]
        case .orange: return [Color(hex: 0xFB923C), Color(hex: 0xF43F5E), Color(hex: 0xFBBF24)]
        case .pink:   return [Color(hex: 0xF472B6), Color(hex: 0xA78BFA), Color(hex: 0xF43F5E)]
        }
    }
}
