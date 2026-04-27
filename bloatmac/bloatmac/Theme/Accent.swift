import SwiftUI

enum AccentKey: String, CaseIterable, Identifiable {
    case blue, purple, green, orange, pink
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var value: Color {
        switch self {
        case .blue:   return Color(hex: 0x0A84FF)
        case .purple: return Color(hex: 0xBF5AF2)
        case .green:  return Color(hex: 0x30D158)
        case .orange: return Color(hex: 0xFF9F0A)
        case .pink:   return Color(hex: 0xFF375F)
        }
    }
    var hover: Color {
        switch self {
        case .blue:   return Color(hex: 0x0070E0)
        case .purple: return Color(hex: 0xA745D8)
        case .green:  return Color(hex: 0x28B84B)
        case .orange: return Color(hex: 0xE68A00)
        case .pink:   return Color(hex: 0xE62A50)
        }
    }
    var soft: Color { value.opacity(0.16) }
}
