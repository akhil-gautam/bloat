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
    ]),
    .init(title: "System", items: [
        .init(id: .memory,  label: "Memory",        icon: "memorychip"),
        .init(id: .startup, label: "Startup items", icon: "powerplug"),
        .init(id: .battery, label: "Battery",       icon: "battery.100"),
        .init(id: .network, label: "Network",       icon: "network"),
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
                    Text("v 2.4.1").font(.system(size: 10, weight: .medium)).foregroundStyle(Tokens.text3)
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

struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("B").font(.system(size: 13, weight: .black)).foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        .shadow(color: Color(hex: 0x0A84FF).opacity(0.35), radius: 4, x: 0, y: 2)
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
