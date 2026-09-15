import SwiftUI
import AppKit

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }

    init(lightHex: Int, lightAlpha: Double = 1, darkHex: Int, darkAlpha: Double = 1) {
        self.init(
            light: NSColor(rgb: lightHex, alpha: lightAlpha),
            dark: NSColor(rgb: darkHex, alpha: darkAlpha)
        )
    }
}

extension NSColor {
    convenience init(rgb: Int, alpha: Double = 1) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >>  8) & 0xFF) / 255
        let b = CGFloat( rgb        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}

enum Tokens {
    // Surfaces are translucent glass so the aurora backdrop reads through.
    // Dark = deep-space; light = soft pearl over pastel aurora.
    static let bg          = Color(lightHex: 0xEEF0F6, darkHex: 0x0B0D14)
    static let bgWindow    = Color(lightHex: 0xF7F8FC, lightAlpha: 0.42, darkHex: 0x0D0F17, darkAlpha: 0.38)
    static let bgSidebar   = Color(lightHex: 0xFFFFFF, lightAlpha: 0.32, darkHex: 0x0A0C12, darkAlpha: 0.45)
    static let bgPanel     = Color(lightHex: 0xFFFFFF, lightAlpha: 0.64, darkHex: 0x161A26, darkAlpha: 0.62)
    static let bgPanel2    = Color(lightHex: 0xFFFFFF, lightAlpha: 0.45, darkHex: 0xFFFFFF, darkAlpha: 0.045)
    static let bgHover     = Color(lightHex: 0x5E5CE6, lightAlpha: 0.06, darkHex: 0xFFFFFF, darkAlpha: 0.06)
    static let bgSelected  = Color(lightHex: 0x4D8DFF, lightAlpha: 0.14, darkHex: 0x4D8DFF, darkAlpha: 0.24)

    static let border        = Color(lightHex: 0x1B1E3A, lightAlpha: 0.10, darkHex: 0xFFFFFF, darkAlpha: 0.10)
    static let borderStrong  = Color(lightHex: 0x1B1E3A, lightAlpha: 0.16, darkHex: 0xFFFFFF, darkAlpha: 0.18)
    static let divider       = Color(lightHex: 0x1B1E3A, lightAlpha: 0.07, darkHex: 0xFFFFFF, darkAlpha: 0.07)

    static let text          = Color(lightHex: 0x171A26, darkHex: 0xF4F5FB)
    static let text2         = Color(lightHex: 0x363A4C, darkHex: 0xCFD3E4)
    static let text3         = Color(lightHex: 0x6C7089, darkHex: 0x9297B0)
    static let text4         = Color(lightHex: 0x989CB4, darkHex: 0x676C86)
    static let textOnAccent  = Color.white

    // Glass detailing shared by GlassPanel / Metallic / Btn.
    static let glassHighlight = Color(lightHex: 0xFFFFFF, lightAlpha: 0.85, darkHex: 0xFFFFFF, darkAlpha: 0.22)
    static let glassShadow    = Color(lightHex: 0x1B1E3A, lightAlpha: 0.10, darkHex: 0x000000, darkAlpha: 0.35)

    static let good   = Color(hex: 0x4ADE80)
    static let warn   = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    // Gradient second stops for the semantic colors, mirroring AccentKey.companion.
    static let warnCompanion   = Color(hex: 0xFB923C)
    static let dangerCompanion = Color(hex: 0xF43F5E)
    static var warnGradient: LinearGradient {
        LinearGradient(colors: [warn, warnCompanion], startPoint: .top, endPoint: .bottom)
    }
    static var dangerGradient: LinearGradient {
        LinearGradient(colors: [danger, dangerCompanion], startPoint: .top, endPoint: .bottom)
    }
    static let purple = Color(hex: 0xC084FC)
    static let pink   = Color(hex: 0xF472B6)
    static let teal   = Color(hex: 0x67E8F9)
    static let indigo = Color(hex: 0x818CF8)
    static let brown  = Color(hex: 0xC4A47C)

    // Category palette
    static let catApps   = Color(hex: 0x4D8DFF)
    static let catSystem = Color(hex: 0x94A0B8)
    static let catDocs   = Color(hex: 0x34D399)
    static let catPhotos = Color(hex: 0xFBBF24)
    static let catMusic  = Color(hex: 0xF472B6)
    static let catVideos = Color(hex: 0xC084FC)
    static let catMail   = Color(hex: 0x67E8F9)
    static let catTrash  = Color(hex: 0xC4A47C)
    static let catOther  = Color(hex: 0x818CF8)
    static let catFree   = Color(lightHex: 0x1B1E3A, lightAlpha: 0.06, darkHex: 0xFFFFFF, darkAlpha: 0.06)

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }
}

extension Color {
    nonisolated init(hex: Int, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
