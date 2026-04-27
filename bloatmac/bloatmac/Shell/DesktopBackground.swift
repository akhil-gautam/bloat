import SwiftUI

struct DesktopBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(colors: [Color(hex: 0x0c1322), Color(hex: 0x0a0a13)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(hex: 0x2c3a5a).opacity(0.7), .clear], center: UnitPoint(x: 0.18, y: 0.10), startRadius: 0, endRadius: 900)
                RadialGradient(colors: [Color(hex: 0x5b2d57).opacity(0.6), .clear], center: UnitPoint(x: 0.85, y: 0.90), startRadius: 0, endRadius: 800)
                RadialGradient(colors: [Color(hex: 0x1f2a44).opacity(0.7), .clear], center: UnitPoint(x: 0.6, y: 0.4), startRadius: 0, endRadius: 700)
            } else {
                LinearGradient(colors: [Color(hex: 0xc9d8f0), Color(hex: 0xe6e9f2)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(hex: 0xb9d6ff).opacity(0.9), .clear], center: UnitPoint(x: 0.18, y: 0.10), startRadius: 0, endRadius: 900)
                RadialGradient(colors: [Color(hex: 0xffd6e8).opacity(0.8), .clear], center: UnitPoint(x: 0.85, y: 0.90), startRadius: 0, endRadius: 800)
                RadialGradient(colors: [Color(hex: 0xe3edff).opacity(0.9), .clear], center: UnitPoint(x: 0.6, y: 0.4), startRadius: 0, endRadius: 700)
            }
        }
        .ignoresSafeArea()
    }
}
