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
    static let bg          = Color(lightHex: 0xECEDEF, darkHex: 0x1B1C1E)
    static let bgWindow    = Color(lightHex: 0xF6F6F8, darkHex: 0x1F2022)
    static let bgSidebar   = Color(lightHex: 0xEAEBEE, darkHex: 0x232427)
    static let bgPanel     = Color(lightHex: 0xFFFFFF, darkHex: 0x2A2B2E)
    static let bgPanel2    = Color(lightHex: 0xF4F5F7, darkHex: 0x232427)
    static let bgHover     = Color(lightHex: 0x000000, lightAlpha: 0.04, darkHex: 0xFFFFFF, darkAlpha: 0.05)
    static let bgSelected  = Color(lightHex: 0x0A84FF, lightAlpha: 0.12, darkHex: 0x0A84FF, darkAlpha: 0.22)

    static let border        = Color(lightHex: 0x000000, lightAlpha: 0.08, darkHex: 0xFFFFFF, darkAlpha: 0.08)
    static let borderStrong  = Color(lightHex: 0x000000, lightAlpha: 0.14, darkHex: 0xFFFFFF, darkAlpha: 0.14)
    static let divider       = Color(lightHex: 0x000000, lightAlpha: 0.06, darkHex: 0xFFFFFF, darkAlpha: 0.06)

    static let text          = Color(lightHex: 0x1C1C1E, darkHex: 0xF2F2F7)
    static let text2         = Color(lightHex: 0x3A3A3C, darkHex: 0xD1D1D6)
    static let text3         = Color(lightHex: 0x6E6E73, darkHex: 0x98989D)
    static let text4         = Color(lightHex: 0x98989D, darkHex: 0x6E6E73)
    static let textOnAccent  = Color.white

    static let good   = Color(hex: 0x30D158)
    static let warn   = Color(hex: 0xFF9F0A)
    static let danger = Color(hex: 0xFF453A)
    static let purple = Color(hex: 0xBF5AF2)
    static let pink   = Color(hex: 0xFF375F)
    static let teal   = Color(hex: 0x64D2FF)
    static let indigo = Color(hex: 0x5E5CE6)
    static let brown  = Color(hex: 0xAC8E68)

    // Category palette
    static let catApps   = Color(hex: 0x0A84FF)
    static let catSystem = Color(hex: 0x8E8E93)
    static let catDocs   = Color(hex: 0x30D158)
    static let catPhotos = Color(hex: 0xFF9F0A)
    static let catMusic  = Color(hex: 0xFF375F)
    static let catVideos = Color(hex: 0xBF5AF2)
    static let catMail   = Color(hex: 0x64D2FF)
    static let catTrash  = Color(hex: 0xAC8E68)
    static let catOther  = Color(hex: 0x5E5CE6)
    static let catFree   = Color(lightHex: 0x000000, lightAlpha: 0.06, darkHex: 0xFFFFFF, darkAlpha: 0.06)

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }
}

extension Color {
    init(hex: Int, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
