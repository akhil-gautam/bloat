import SwiftUI

struct NavItem: Identifiable {
    let id: Screen
    let label: String
    let icon: String           // SF Symbol
    var badge: String? = nil
    var badgeKind: BadgeKind = .neutral
}
enum BadgeKind { case neutral, warn, danger }

struct NavSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [NavItem]
}

var SIDEBAR_NAV: [NavSection] {
    let live = LiveStorage.shared
    let usedPct = live.totalGB > 0 ? Int((live.usedGB / live.totalGB * 100).rounded()) : 0
    return [
    .init(title: "Overview", items: [
        .init(id: .smartcare, label: "Smart Care", icon: "sparkles"),
        .init(id: .dashboard, label: "Dashboard", icon: "square.grid.2x2"),
        .init(id: .analytics, label: "Analytics", icon: "chart.bar"),
    ]),
    .init(title: "Storage", items: [
        .init(id: .storage,    label: "Storage",            icon: "internaldrive",       badge: "\(usedPct)%", badgeKind: usedPct > 85 ? .danger : usedPct > 70 ? .warn : .neutral),
        .init(id: .large,      label: "Large files",        icon: "doc",
              badge: LiveLargeFiles.shared.items.isEmpty ? nil : "\(LiveLargeFiles.shared.items.count)"),
        .init(id: .duplicates, label: "Duplicates",         icon: "doc.on.doc",
              badge: LiveDuplicates.shared.totalGroups == 0 ? nil : "\(LiveDuplicates.shared.totalGroups)",
              badgeKind: .danger),
        .init(id: .unused,     label: "Unused & old",       icon: "clock",
              badge: LiveUnused.shared.totalCount == 0 ? nil : "\(LiveUnused.shared.totalCount)"),
        .init(id: .downloads,  label: "Downloads & cache",  icon: "arrow.down.circle",
              badge: LiveDownloadsCache.shared.totalCount == 0 ? nil : "\(LiveDownloadsCache.shared.totalCount)"),
        .init(id: .uninstaller, label: "Uninstaller",       icon: "trash"),
        .init(id: .updater,     label: "Updater",            icon: "arrow.up.circle",
              badge: LiveUpdater.shared.totalCount == 0 ? nil : "\(LiveUpdater.shared.totalCount)",
              badgeKind: .warn),
        .init(id: .systemjunk,  label: "System junk",        icon: "tray.full"),
        .init(id: .privacy,     label: "Privacy",            icon: "lock.shield"),
        .init(id: .cloud,       label: "Cloud",              icon: "icloud"),
    ]),
    .init(title: "System", items: [
        .init(id: .memory,      label: "Memory",        icon: "memorychip"),
        .init(id: .startup,     label: "Startup items", icon: "powerplug"),
        .init(id: .battery,     label: "Battery",       icon: "battery.100"),
        .init(id: .network,     label: "Network",       icon: "network"),
        .init(id: .maintenance, label: "Maintenance",   icon: "wrench.and.screwdriver"),
        .init(id: .schedules,   label: "Schedules",     icon: "calendar.badge.clock"),
        .init(id: .diskHealth,       label: "Disk health",  icon: "stethoscope"),
        .init(id: .permissionsAudit, label: "Permissions",  icon: "lock.shield"),
        .init(id: .threatHygiene,    label: "Threat hygiene", icon: "checkmark.shield"),
    ]),
    .init(title: "", items: [
        .init(id: .settings, label: "Settings", icon: "gearshape"),
    ]),
    ]
}

struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveStorage.shared
    @ObservedObject private var largeFiles = LiveLargeFiles.shared
    @ObservedObject private var dupes = LiveDuplicates.shared
    @ObservedObject private var unused = LiveUnused.shared
    @ObservedObject private var dlCache = LiveDownloadsCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // titlebar height — traffic lights live here (provided by OS via hiddenTitleBar)
            Color.clear.frame(height: 44)

            HStack(spacing: 8) {
                BrandMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("BloatMac").font(.system(size: 14, weight: .bold)).tracking(-0.3).foregroundStyle(Tokens.text)
                    Text(appVersionLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(Tokens.text3)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SIDEBAR_NAV) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            if !section.title.isEmpty {
                                Text(section.title.uppercased())
                                    .font(.system(size: 10.5, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(Tokens.text4)
                                    .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in
                                NavRow(item: item)
                            }
                        }
                    }
                }
            }

            SidebarFooter()
        }
        .background(Tokens.bgSidebar)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Tokens.border), alignment: .trailing)
    }
}

/// Reads the bundle's CFBundleShortVersionString so the sidebar always
/// reflects the actual build, not a hardcoded prototype string. Falls
/// back to the build number if the short version key is missing.
var appVersionLabel: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    return "v " + (short ?? build ?? "?")
}

/// Native SwiftUI redraw of the brand logo. We rasterise from PNG assets
/// for the AppIcon (Apple requires `.icns` from PNGs there), but for
/// in-app surfaces the bitmap import introduces a faint halo at the
/// rounded-square edges from anti-aliasing. Drawing as live shapes
/// stays crisp at any scale and ditches the halo entirely.
struct BrandMark: View {
    /// Defaults to the sidebar's 26 pt. `Onboarding` scales via
    /// `.scaleEffect()` so the geometry inside remains pixel-aligned.
    var size: CGFloat = 26

    private var corner: CGFloat { size * (232.0 / 1024.0) }

    var body: some View {
        ZStack {
            // Badge gradient — matches Logo.svg's #0A84FF → #5E5CE6 stops.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // Subtle radial highlight near the top-left so the badge has dimension.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.20), .clear],
                                     center: UnitPoint(x: 0.28, y: 0.22),
                                     startRadius: 0, endRadius: size * 0.95))
            // Hairline inner stroke — matches the SVG's white-12% inset rect.
            RoundedRectangle(cornerRadius: corner - 0.5, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
                .padding(0.5)
            // Stylized "B" — vertical stem + two stacked D-loops, baked
            // into one path so it fills as one shape. Coords are
            // normalised against the SVG's 1024-unit canvas, then scaled
            // to the runtime size.
            BLetterShape()
                .fill(LinearGradient(
                    colors: [.white, Color(hex: 0xF0E9FF)],
                    startPoint: UnitPoint(x: 0.3, y: 0.05),
                    endPoint:   UnitPoint(x: 0.6, y: 1.0)
                ))
            // Smart-care sparkle — fades out below the sidebar threshold so
            // it doesn't read as noise at 26 pt.
            if size >= 36 {
                SparkleShape()
                    .fill(.white.opacity(0.94))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: size * 0.275, y: -size * 0.275)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: Color(hex: 0x0A84FF).opacity(0.32), radius: size * 0.18, x: 0, y: size * 0.08)
    }
}

/// Filled "B": vertical stem + two D-loops in a single path. All
/// coordinates expressed against the SVG's 1024-unit canvas, then
/// scaled to the runtime rect.
private struct BLetterShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 1024.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        // Stem: rounded rect 288..394 × 268..756.
        path.addRoundedRect(
            in: CGRect(origin: p(288, 268),
                       size: CGSize(width: 106 * scale, height: 488 * scale)),
            cornerSize: CGSize(width: 22 * scale, height: 22 * scale)
        )
        // Top D-loop: from (390,268) down to (390,504), arc back via right bulge.
        path.move(to: p(390, 268))
        path.addLine(to: p(390, 504))
        path.addArc(
            tangent1End: p(514, 504),
            tangent2End: p(514, 268),
            radius: 124 * scale
        )
        path.addArc(
            tangent1End: p(514, 268),
            tangent2End: p(390, 268),
            radius: 124 * scale
        )
        path.closeSubpath()
        // Bottom D-loop: slightly larger per typographic convention.
        path.move(to: p(390, 520))
        path.addLine(to: p(390, 756))
        path.addArc(
            tangent1End: p(528, 756),
            tangent2End: p(528, 520),
            radius: 138 * scale
        )
        path.addArc(
            tangent1End: p(528, 520),
            tangent2End: p(390, 520),
            radius: 138 * scale
        )
        path.closeSubpath()
        return path
    }
}

/// Four-point sparkle: a vertical bar + horizontal bar (rounded) + a
/// faint 45°-rotated rounded square between them.
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX, cy = rect.midY
        let arm = rect.width * 0.5
        let thick = rect.width * 0.16
        // Vertical bar
        path.addRoundedRect(
            in: CGRect(x: cx - thick / 2, y: cy - arm, width: thick, height: arm * 2),
            cornerSize: CGSize(width: thick / 2, height: thick / 2)
        )
        // Horizontal bar
        path.addRoundedRect(
            in: CGRect(x: cx - arm, y: cy - thick / 2, width: arm * 2, height: thick),
            cornerSize: CGSize(width: thick / 2, height: thick / 2)
        )
        return path
    }
}

struct NavRow: View {
    let item: NavItem
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var isActive: Bool { state.current == item.id }

    var body: some View {
        Button { state.goto(item.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon).font(.system(size: 13)).frame(width: 18)
                Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let badge = item.badge { BadgeView(text: badge, kind: item.badgeKind, active: isActive) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(
                    isActive ? AnyShapeStyle(state.accent.value) :
                    hover ? AnyShapeStyle(Tokens.bgHover) : AnyShapeStyle(Color.clear)
                )
            }
            .foregroundStyle(isActive ? .white : Tokens.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .onHover { hover = $0 }
        .accessibilityLabel(Text("\(item.label)\(item.badge.map { " (\($0))" } ?? "")"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct BadgeView: View {
    let text: String
    let kind: BadgeKind
    let active: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(bg)
            )
            .foregroundStyle(fg)
    }
    var bg: Color {
        if active { return .white.opacity(0.25) }
        switch kind {
        case .warn: return Tokens.warn
        case .danger: return Tokens.danger
        case .neutral: return Tokens.bgPanel
        }
    }
    var fg: Color {
        if active { return .white }
        switch kind {
        case .warn, .danger: return .white
        case .neutral: return Tokens.text3
        }
    }
}

struct SidebarFooter: View {
    @ObservedObject private var live = LiveStorage.shared
    var body: some View {
        let sPct = live.totalGB > 0 ? live.usedGB / live.totalGB : 0
        VStack(alignment: .leading, spacing: 6) {
            statRow(label: "Storage", pct: sPct)
            StatBar(value: sPct, kind: sPct > 0.85 ? .danger : sPct > 0.7 ? .warn : .neutral)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Tokens.divider), alignment: .top)
    }
    @ViewBuilder
    func statRow(label: String, pct: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Tokens.text3)
            Spacer()
            Text("\(Int((pct * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(Tokens.text3)
        }
    }
}

struct StatBar: View {
    let value: Double
    let kind: BadgeKind
    var color: Color {
        switch kind { case .warn: return Tokens.warn; case .danger: return Tokens.danger; case .neutral: return Color(hex: 0x0A84FF) }
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.bgPanel2)
                Capsule().fill(color).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 4)
    }
}
