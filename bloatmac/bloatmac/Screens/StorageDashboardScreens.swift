import SwiftUI

// MARK: - Helpers

struct ScreenScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.bgWindow)
    }
}

// MARK: - Storage (hero)

struct StorageScreen: View {
    enum Mode: String, CaseIterable { case categories, applications }
    @State private var mode: Mode = .categories
    @State private var drillCategory: LiveCategory? = nil
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveStorage.shared

    var body: some View {
        ScreenScroll {
            header.staggered(0)
            ActionError(message: live.lastError)
            usedSummary.staggered(1)
            HStack(alignment: .top, spacing: 16) {
                storageMap.frame(maxWidth: .infinity)
                rightColumn.frame(width: 360)
            }
            .staggered(2)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Storage").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.calculating { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text("\(live.volumeName) · \(live.format) · \(formatTotal(live.totalGB))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.calculating, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                segmented
                Btn(label: live.calculating ? "Scanning…" : "Rescan", icon: "arrow.clockwise", style: .secondary) {
                    live.refresh()
                }
                Btn(label: "Review cleanup", icon: "tray.full", style: .primary) { state.goto(.downloads) }
            }
        }
        .padding(.bottom, 4)
    }

    private func formatTotal(_ gb: Double) -> String {
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        return "\(Int(gb.rounded())) GB"
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { mode = m }
                } label: {
                    Text(m == .categories ? "Categories" : "Applications")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(mode == m ? Tokens.bgSelected : .clear)
                                .shadow(color: .black.opacity(mode == m ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .foregroundStyle(mode == m ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
    }

    @ViewBuilder
    private var usedSummary: some View {
        let usedPct = live.totalGB > 0 ? Int((live.usedGB / live.totalGB * 100).rounded()) : 0
        let pillKind: PillKind = usedPct > 85 ? .danger : usedPct > 70 ? .warn : .good
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("USED").font(.system(size: 11.5, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.1f", live.usedGB))
                            .font(.system(size: 44, weight: .heavy)).tracking(-1.5)
                            .foregroundStyle(Tokens.text)
                        Text("/ \(Int(live.totalGB.rounded())) GB")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                        if live.totalGB > 0 {
                            Pill(text: "\(usedPct)% full", kind: pillKind)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    StackedUsageBar(categories: live.displayCategories, totalGB: live.totalGB, usedGB: live.usedGB)
                    LegendGrid(categories: live.displayCategories, freeGB: live.freeGB, calculating: live.calculating)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .glassPanel()
    }

    @ViewBuilder
    private var storageMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if drillCategory != nil {
                    Btn(label: "Back", icon: "chevron.left", style: .secondary) {
                        withAnimation(.easeOut(duration: 0.2)) { drillCategory = nil }
                    }
                }
                Text("Storage map").font(.system(size: 14, weight: .bold))
                Text(drillCategory == nil ? "Known folders and unclassified usage" : "Showing \(drillCategory!.name)")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                Spacer()
                LivePill(active: live.calculating)
            }

            Group {
                if let drill = drillCategory {
                    Treemap(items: live.apps.map { TreemapItem(id: $0.id, name: $0.name, size: $0.size, color: $0.color) },
                            onSelect: { revealApplication(named: $0.name) })
                        .id("apps-\(drill.id)")
                } else {
                    let items = tilesForMode()
                    if items.isEmpty {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Tokens.bgPanel2)
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.large)
                                Text("Calculating sizes…").font(.system(size: 12)).foregroundStyle(Tokens.text3)
                            }
                        }
                    } else {
                        Treemap(items: items,
                                onSelect: { item in
                                    if mode == .categories, item.id == "apps" {
                                        if let cat = live.categories.first(where: { $0.id == "apps" }) {
                                            withAnimation(.easeOut(duration: 0.25)) { drillCategory = cat }
                                        }
                                    } else if mode == .categories {
                                        let path = LiveStorage.categorySpec.first(where: { $0.id == item.id })?.paths.first ?? "/"
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    } else {
                                        revealApplication(named: item.name)
                                    }
                                })
                            .id("\(mode.rawValue)-root")
                    }
                }
            }
            .frame(height: 480)
        }
        .padding(16)
        .glassPanel()
    }

    private func revealApplication(named name: String) {
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        let url = roots.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/Applications")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tilesForMode() -> [TreemapItem] {
        switch mode {
        case .categories:
            return live.displayCategories.filter { $0.status == .calculated && $0.size > 0.01 }
                .map { TreemapItem(id: $0.id, name: $0.name, size: $0.size, color: $0.color) }
        case .applications:
            return live.apps.filter { $0.size > 0.01 }
                .map { TreemapItem(id: $0.id, name: $0.name, size: $0.size, color: $0.color) }
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(spacing: 16) {
            recoverableCard
            byCategoryCard
        }
    }

    @ViewBuilder
    private var recoverableCard: some View {
        let cleanables = live.categories.filter { ["caches", "downloads", "trash"].contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review cleanup candidates").font(.system(size: 14, weight: .bold))
                Text("Includes personal downloads. Review before removing.").font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", live.cleanableGB))
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(Tokens.good)
                Text("GB").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text3)
            }

            VStack(spacing: 12) {
                ForEach(cleanables) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text2)
                            Spacer()
                            if c.status == .calculating {
                                Text("Calculating…").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                            } else {
                                Text(String(format: "%.1f GB", c.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                        }
                        ThinBar(value: live.cleanableGB > 0 ? c.size / live.cleanableGB : 0)
                            .tint(c.color)
                    }
                }
            }

            Btn(label: "Review downloads & caches",
                icon: "tray.full", style: .primary) { state.goto(.downloads) }
            Text("Moving files to Trash does not release disk space until Trash is emptied. Other & unscanned includes macOS, snapshots, and folders not measured here; categories are estimates.")
                .font(.system(size: 11)).foregroundStyle(Tokens.text3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .glassPanel()
    }

    @ViewBuilder
    private var byCategoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By category").font(.system(size: 14, weight: .bold))
            VStack(spacing: 10) {
                ForEach(live.displayCategories) { c in
                    HStack(spacing: 10) {
                        Circle().fill(c.color).frame(width: 8, height: 8)
                        Text(c.name + (c.incomplete ? " (partial)" : "")).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        if c.status == .calculating {
                            Text("Calculating…").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        } else {
                            Text(String(format: "%.1f GB", c.size)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(18)
        .glassPanel()
    }
}

// MARK: - Storage helpers

struct StackedUsageBar: View {
    let categories: [LiveCategory]
    let totalGB: Double
    let usedGB: Double

    var body: some View {
        GeometryReader { geo in
            let calc = categories.filter { $0.status == .calculated && $0.size > 0 }
            let knownSum = calc.reduce(0) { $0 + $1.size }
            let other = max(0, usedGB - knownSum)
            let denom = max(0.0001, totalGB)
            HStack(spacing: 1.5) {
                ForEach(calc) { c in
                    Rectangle().fill(c.color)
                        .frame(width: max(2, CGFloat(c.size / denom) * geo.size.width))
                }
                if other > 0.5 {
                    Rectangle().fill(Tokens.indigo.opacity(0.55))
                        .frame(width: CGFloat(other / denom) * geo.size.width)
                }
                Rectangle().fill(Tokens.catFree)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct LegendGrid: View {
    let categories: [LiveCategory]
    let freeGB: Double
    let calculating: Bool
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 18), count: 6)

    var body: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(categories) { c in
                legendItem(color: c.color, name: c.name + (c.incomplete ? " (partial)" : ""), size: c.size, calculating: c.status == .calculating)
            }
            legendItem(color: Tokens.catFree, name: "Free", size: freeGB, hollow: true, calculating: false)
        }
    }

    @ViewBuilder
    private func legendItem(color: Color, name: String, size: Double, hollow: Bool = false, calculating: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                if hollow {
                    RoundedRectangle(cornerRadius: 2).stroke(Tokens.text3, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(color)
                }
            }.frame(width: 9, height: 9)
            Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Tokens.text2).lineLimit(1)
            Text("·").foregroundStyle(Tokens.text4)
            if calculating {
                Text("…").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tokens.text3)
            } else {
                Text(String(format: "%.1f", size)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text)
            }
        }
    }
}

struct LivePill: View {
    let active: Bool
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? Tokens.warn : Tokens.catApps)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.25 : 1)
                .opacity(pulse ? 0.6 : 1)
            Text(active ? "Scanning" : "Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Tokens.warn : Tokens.catApps)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill((active ? Tokens.warn : Tokens.catApps).opacity(0.12)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - All other screens (empty states until real data is wired)

struct DashboardScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveDashboard.shared

    var body: some View {
        ScreenScroll {
            header.staggered(0)
            HStack(alignment: .top, spacing: 16) {
                healthHero.frame(width: 320)
                briefingCard.frame(maxWidth: .infinity)
            }
            .staggered(1)
            tickersStrip.staggered(2)
            recommendationsPanel.staggered(3)
            forecastsPanel.staggered(4)
            trendsPanel.staggered(5)
            timelinePanel.staggered(6)
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Dashboard").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    PulsingDot(color: live.score.grade.color, size: 9)
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: live.refreshing ? "Refreshing…" : "Refresh", icon: "arrow.clockwise", style: .secondary) {
                    live.refresh()
                }
                Btn(label: "Quick scan", icon: "sparkles", style: .primary) {
                    live.runQuickScan()
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var headerSubtitle: String {
        let host = Host.current().localizedName ?? "This Mac"
        if live.lastRefresh == .distantPast { return host }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return "\(host) · refreshed \(f.localizedString(for: live.lastRefresh, relativeTo: Date()))"
    }

    private var healthHero: some View {
        let s = live.score
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Health").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(s.grade.label.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(s.grade.color.opacity(0.18)))
                    .foregroundStyle(s.grade.color)
            }
            HStack(spacing: 14) {
                ZStack {
                    HealthRing(score: s.overall, color: s.grade.color)
                        .frame(width: 118, height: 118)
                    VStack(spacing: 0) {
                        Text("\(s.asInt)")
                            .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                            .contentTransition(.numericText(value: s.overall))
                            .foregroundStyle(Tokens.text)
                        Text("of 100")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Tokens.text3)
                    }
                }
                VStack(spacing: 6) {
                    subScoreRow(label: "Storage", value: s.storage)
                    subScoreRow(label: "Memory",  value: s.memory)
                    if s.hasBattery { subScoreRow(label: "Battery", value: s.battery) }
                    subScoreRow(label: "Network", value: s.network)
                    subScoreRow(label: "Hygiene", value: s.hygiene)
                }
            }
        }
        .padding(16)
        .glassPanel()
    }

    private func subScoreRow(label: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.bgPanel2)
                    Capsule().fill(scoreColor(value)).frame(width: geo.size.width * value)
                }
            }
            .frame(height: 5)
            Text("\(Int((value * 100).rounded()))").font(.system(size: 11, weight: .heavy))
                .monospacedDigit().frame(width: 28, alignment: .trailing)
                .foregroundStyle(Tokens.text2)
        }
    }

    private func scoreColor(_ v: Double) -> Color {
        if v >= 0.85 { return Tokens.good }
        if v >= 0.60 { return Tokens.catApps }
        if v >= 0.40 { return Tokens.warn }
        return Tokens.danger
    }

    private var briefingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.purple)
                Text("Briefing").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(live.intelligenceStatus.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Tokens.purple.opacity(0.18)))
                    .foregroundStyle(Tokens.purple)
                    .help(live.intelligenceStatus.detail)
            }
            Text(live.briefing.isEmpty ? "Computing…" : live.briefing)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.text)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(live.briefing)
                .transition(.opacity)
            if !live.recommendations.isEmpty {
                HStack(spacing: 8) {
                    ForEach(live.recommendations.prefix(3)) { r in
                        Button { state.goto(r.target) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: r.icon).font(.system(size: 10, weight: .heavy))
                                Text(r.actionLabel).font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(r.tone.color.opacity(0.18)))
                            .foregroundStyle(r.tone.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .glassPanel()
    }

    private var tickersStrip: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(live.tickers) { t in
                Button { state.goto(t.target) } label: { tickerCard(t) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tickerCard(_ t: DashTicker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(t.color.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(t.label).font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Tokens.text4)
                Text(t.value).font(.system(size: 16, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(Tokens.text)
                Text(t.detail).font(.system(size: 10)).foregroundStyle(Tokens.text4).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metallic(radius: Tokens.Radius.md)
    }

    private var recommendationsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recommendations").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("\(live.recommendations.count)")
                    .font(.system(size: 10, weight: .heavy)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Tokens.bgPanel2))
                    .foregroundStyle(Tokens.text3)
            }
            VStack(spacing: 8) {
                ForEach(live.recommendations) { r in
                    recRow(r)
                }
            }
        }
        .padding(16)
        .glassPanel()
    }

    private func recRow(_ r: DashRecommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(r.tone.color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: r.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(r.tone.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                Text(r.body).font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
            }
            Spacer(minLength: 0)
            Button { state.goto(r.target) } label: {
                HStack(spacing: 4) {
                    Text(r.actionLabel).font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .heavy))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
                .foregroundStyle(Tokens.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var forecastsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Forecasts").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("LINEAR REGRESSION · ON DEVICE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
            }
            if live.forecasts.isEmpty {
                Text("Gathering enough samples to calculate a forecast.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    .padding(.vertical, 12)
            } else {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    ForEach(live.forecasts) { f in
                        Button { state.goto(f.target) } label: { forecastCard(f) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .glassPanel()
    }

    private func forecastCard(_ f: DashForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: f.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(f.color)
                Text(f.label.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if let confidence = f.confidence {
                    Text("R² \(Int((confidence * 100).rounded()))%")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(Tokens.text4)
                        .help("How closely the measured samples fit this trend")
                }
            }
            Text(f.when)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Tokens.text)
            Text(f.detail).font(.system(size: 11)).foregroundStyle(Tokens.text3).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(f.color.opacity(0.30), lineWidth: 1))
    }

    private var trendsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent trends").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("AVAILABLE HISTORY · ON DEVICE")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
            }
            if live.trends.isEmpty {
                Text("Gathering data — trends fill in as samples accumulate.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    .padding(.vertical, 12)
            } else {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    ForEach(live.trends) { t in
                        Button { state.goto(t.target) } label: { trendCard(t) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .glassPanel()
    }

    private func trendCard(_ t: TrendSeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(t.valueText).font(.system(size: 11, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text2)
            }
            TrendSparkline(values: t.values, color: t.color).frame(height: 38)
            Text(t.detail).font(.system(size: 10)).foregroundStyle(Tokens.text4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 24 hours").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("\(live.timeline.count) events").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            ActivityTimeline(events: live.timeline)
                .frame(height: 70)
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                legendChip(.charge); legendChip(.drain); legendChip(.memorySpike); legendChip(.networkSpike); legendChip(.scan)
                Spacer()
            }
        }
        .padding(16)
        .glassPanel()
    }

    private func legendChip(_ kind: ActivityKind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.icon).font(.system(size: 9, weight: .bold)).foregroundStyle(kind.color)
            Text(kind.rawValue.capitalized).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
        }
    }
}

private struct TrendSparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let mx = max(values.max() ?? 1, 0.0001)
            ZStack {
                if values.count >= 2 {
                    Path { p in
                        let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
                        for (i, v) in values.enumerated() {
                            let x = CGFloat(i) * stepX
                            let y = geo.size.height * (1 - CGFloat(v / mx))
                            if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Path { p in
                        let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
                        p.move(to: .init(x: 0, y: geo.size.height))
                        for (i, v) in values.enumerated() {
                            let x = CGFloat(i) * stepX
                            let y = geo.size.height * (1 - CGFloat(v / mx))
                            p.addLine(to: .init(x: x, y: y))
                        }
                        p.addLine(to: .init(x: geo.size.width, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
            .drawingGroup()
        }
    }
}

private struct HealthRing: View {
    var score: Double
    var color: Color
    @State private var animated: Double = 0
    var body: some View {
        ZStack {
            Circle().stroke(Tokens.bgPanel2, lineWidth: 14)
            Circle()
                .trim(from: 0, to: animated)
                .stroke(LinearGradient(colors: [color.opacity(0.55), color],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().stroke(color.opacity(0.10), lineWidth: 1).padding(7)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { animated = score } }
        .onChange(of: score) { _, n in withAnimation(.easeInOut(duration: 0.45)) { animated = n } }
    }
}

private struct ActivityTimeline: View {
    let events: [ActivityEvent]
    var body: some View {
        GeometryReader { geo in
            let now = Date()
            let start = now.addingTimeInterval(-86400)
            ZStack(alignment: .topLeading) {
                ForEach(0..<7) { i in
                    let x = geo.size.width * CGFloat(i) / 6
                    Path { p in p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: geo.size.height)) }
                        .stroke(Tokens.divider, lineWidth: 0.5)
                }
                ForEach(events) { ev in
                    let x1 = xFor(ev.start, in: geo.size, start: start)
                    let x2 = max(xFor(ev.end, in: geo.size, start: start), x1 + 2)
                    let y = laneY(for: ev.kind, in: geo.size.height)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ev.kind.color.opacity(0.85))
                        .frame(width: x2 - x1, height: 8)
                        .position(x: (x1 + x2) / 2, y: y)
                        .help("\(ev.detail) · \(ev.start.formatted(.dateTime.hour().minute())) → \(ev.end.formatted(.dateTime.hour().minute()))")
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { i in
                        let date = start.addingTimeInterval(Double(i) * 14_400)
                        Text(date.formatted(.dateTime.hour()))
                            .font(.system(size: 9, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Tokens.text4)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, -16)
            }
        }
    }
    private func xFor(_ d: Date, in size: CGSize, start: Date) -> CGFloat {
        let frac = max(0, min(1, d.timeIntervalSince(start) / 86400))
        return size.width * CGFloat(frac)
    }
    private func laneY(for kind: ActivityKind, in height: CGFloat) -> CGFloat {
        switch kind {
        case .scan:         return height * 0.10
        case .charge:       return height * 0.30
        case .drain:        return height * 0.50
        case .memorySpike:  return height * 0.70
        case .networkSpike: return height * 0.90
        }
    }
}
