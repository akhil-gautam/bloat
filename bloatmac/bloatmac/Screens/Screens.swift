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
            header
            usedSummary
            HStack(alignment: .top, spacing: 16) {
                storageMap.frame(maxWidth: .infinity)
                rightColumn.frame(width: 360)
            }
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
                Btn(label: "Clean up", icon: "trash", style: .primary) {}
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
                                .fill(mode == m ? Tokens.bgPanel : .clear)
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
                    StackedUsageBar(categories: live.categories, totalGB: live.totalGB, usedGB: live.usedGB)
                    LegendGrid(categories: live.categories, freeGB: live.freeGB, calculating: live.calculating)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
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
                Text(drillCategory == nil ? "Click a category to drill in" : "Showing \(drillCategory!.name)")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                Spacer()
                LivePill(active: live.calculating)
            }

            Group {
                if let drill = drillCategory {
                    Treemap(items: live.apps.map { TreemapItem(id: $0.id, name: $0.name, size: $0.size, color: $0.color) },
                            onSelect: { _ in drillCategory = nil })
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
                                    }
                                })
                            .id("\(mode.rawValue)-root")
                    }
                }
            }
            .frame(height: 480)
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private func tilesForMode() -> [TreemapItem] {
        switch mode {
        case .categories:
            return live.categories.filter { $0.status == .calculated && $0.size > 0.01 }
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
                Text("Recoverable now").font(.system(size: 14, weight: .bold))
                Text("Cleanable without losing anything").font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
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

            Btn(label: live.cleanableGB > 0 ? "Free \(String(format: "%.1f GB", live.cleanableGB))" : "Free up",
                icon: "sparkles", style: .primary) {}
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    @ViewBuilder
    private var byCategoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By category").font(.system(size: 14, weight: .bold))
            VStack(spacing: 10) {
                ForEach(live.categories) { c in
                    HStack(spacing: 10) {
                        Circle().fill(c.color).frame(width: 8, height: 8)
                        Text(c.name).font(.system(size: 12.5, weight: .medium))
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
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
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
                    Rectangle().fill(Color(hex: 0x5E5CE6).opacity(0.55))
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
                legendItem(color: c.color, name: c.name, size: c.size, calculating: c.status == .calculating)
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
            Circle().fill(active ? Tokens.warn : Color(hex: 0x0A84FF))
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.25 : 1)
                .opacity(pulse ? 0.6 : 1)
            Text(active ? "Scanning" : "Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Tokens.warn : Color(hex: 0x0A84FF))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill((active ? Tokens.warn : Color(hex: 0x0A84FF)).opacity(0.12)))
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
            header
            HStack(alignment: .top, spacing: 16) {
                healthHero.frame(width: 320)
                briefingCard.frame(maxWidth: .infinity)
            }
            tickersStrip
            recommendationsPanel
            forecastsPanel
            trendsPanel
            timelinePanel
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
            ZStack {
                HealthRing(score: s.overall, color: s.grade.color)
                    .frame(width: 200, height: 200)
                VStack(spacing: 0) {
                    Text("\(s.asInt)")
                        .font(.system(size: 52, weight: .heavy)).monospacedDigit()
                        .contentTransition(.numericText(value: s.overall))
                        .foregroundStyle(Tokens.text)
                    Text("of 100")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 6) {
                subScoreRow(label: "Storage", value: s.storage)
                subScoreRow(label: "Memory",  value: s.memory)
                if s.hasBattery { subScoreRow(label: "Battery", value: s.battery) }
                subScoreRow(label: "Network", value: s.network)
                subScoreRow(label: "Hygiene", value: s.hygiene)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
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
                Text(live.briefingAuthor.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Tokens.purple.opacity(0.18)))
                    .foregroundStyle(Tokens.purple)
            }
            Text(live.briefing.isEmpty ? "Computing…" : live.briefing)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.text)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(live.briefing)
                .transition(.opacity)
            Spacer(minLength: 0)
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
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
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
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(live.forecasts) { f in
                    Button { state.goto(f.target) } label: { forecastCard(f) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func forecastCard(_ f: DashForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: f.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(f.color)
                Text(f.label.uppercased())
                    .font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("\(Int((f.confidence*100).rounded()))%")
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(Tokens.text4)
                    .help("Forecast confidence (R²)")
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
                Text("7-day trends").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("HOURLY BUCKETS · ON DEVICE")
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
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

struct LargeFilesScreen: View {
    @ObservedObject private var live = LiveLargeFiles.shared
    @State private var selected: Set<URL> = []
    @State private var sort: Sort = .sizeDesc
    @State private var confirmTrash: Bool = false

    enum Sort: String, CaseIterable {
        case sizeDesc = "Size", ageDesc = "Oldest", nameAsc = "Name"
    }

    var sorted: [LargeFileItem] {
        switch sort {
        case .sizeDesc: return live.items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .ageDesc:  return live.items.sorted { $0.ageDays > $1.ageDays }
        case .nameAsc:  return live.items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScreenScroll {
            header
            if live.items.isEmpty && !live.scanning {
                EmptyState(
                    icon: "doc.badge.ellipsis",
                    title: "No large files yet",
                    message: "Scan your home directory and Applications for files at or above the size threshold (default: 100 MB).",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                tableCard
            }
        }
        .task { live.startIfNeeded() }
    }

    private var thresholdGB: Double { Double(live.thresholdMB) / 1000 }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Large Files").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                thresholdMenu
                sortMenu
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) {
                    live.scan()
                }
                .disabled(live.scanning)
                if !selected.isEmpty {
                    Btn(label: "Move \(selected.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selected.count) item(s) to Trash?",
               isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.moveToTrash(selected)
                selected.removeAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can be restored from Trash until you empty it.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning {
            let pct = live.totalDirs > 0 ? Int(Double(live.scannedDirs) / Double(live.totalDirs) * 100) : 0
            return "Scanning… \(live.scannedDirs)/\(live.totalDirs) locations (\(pct)%) · \(live.items.count) found"
        }
        return "\(live.items.count) files ≥ \(live.thresholdMB) MB · \(live.totalSizeText) total"
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach([50, 100, 250, 500, 1000, 2000], id: \.self) { mb in
                Button("≥ \(mb) MB") {
                    live.thresholdMB = mb
                    live.scan()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                Text("≥ \(live.thresholdMB) MB").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Sort.allCases, id: \.self) { s in
                Button(s.rawValue) { sort = s }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                Text(sort.rawValue).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var tableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAll() } label: {
                    AppCheckbox(on: !selected.isEmpty && selected.count == live.items.count)
                }.buttonStyle(.plain).frame(width: 22)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("KIND").frame(width: 110, alignment: .leading)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("LAST USED").frame(width: 110, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(sorted) { item in
                    LargeFileRow(item: item,
                                 selected: selected.contains(item.id),
                                 toggle: { toggle(item.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private func toggle(_ id: URL) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleSelectAll() {
        if selected.count == live.items.count { selected.removeAll() }
        else { selected = Set(live.items.map(\.id)) }
    }
}

struct LargeFileRow: View {
    let item: LargeFileItem
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected) }
                .buttonStyle(.plain).frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.parent).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.kind).font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                .frame(width: 110, alignment: .leading)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Text(item.ageText)
                .font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Button { LiveLargeFiles.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }
            .buttonStyle(.plain)
            .frame(width: 28)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveLargeFiles.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct DuplicatesScreen: View {
    @ObservedObject private var live = LiveDuplicates.shared
    enum Tab: String, CaseIterable { case exact = "Exact", similar = "Similar images" }
    @State private var tab: Tab = .exact
    @State private var confirmResolve: Bool = false

    var body: some View {
        ScreenScroll {
            header
            if live.totalGroups == 0 && !live.scanning {
                EmptyState(
                    icon: "doc.on.doc",
                    title: "No duplicates yet",
                    message: "Bloatmac hashes files and uses Apple's Vision framework to find visually similar images across your home directory.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                groupsList
            }
        }
        .task { live.startIfNeeded() }
    }

    // MARK: header

    private var header: some View {
        let unkept = (live.exact + live.similar).reduce(0) { $0 + $1.items.filter { !$0.keep }.count }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Duplicates").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: "Smart pick", icon: "sparkles", style: .secondary) { live.smartPick() }
                    .disabled(live.totalGroups == 0)
                Btn(label: live.scanning ? "Scanning…" : "Rescan", icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                Btn(label: unkept > 0 ? "Resolve \(unkept) (\(live.totalRecoverableText))" : "Resolve",
                    icon: "trash", style: .danger) { confirmResolve = true }
                    .disabled(unkept == 0)
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(unkeptCount) item(s) to Trash?", isPresented: $confirmResolve) {
            Button("Move to Trash", role: .destructive) {
                let n = live.resolveAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(live.totalRecoverableText) will be reclaimed. Items can be restored from Trash until you empty it.")
        }
    }

    private var unkeptCount: Int {
        (live.exact + live.similar).reduce(0) { $0 + $1.items.filter { !$0.keep }.count }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalGroups == 0 { return "" }
        return "\(live.exact.count) exact · \(live.similar.count) visually similar · up to \(live.totalRecoverableText) recoverable"
    }

    // MARK: progress

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
            Text("Vision feature prints run on the GPU; large image libraries may take a minute.")
                .font(.system(size: 11)).foregroundStyle(Tokens.text3)
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    // MARK: tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .exact ? live.exact.count : live.similar.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    HStack(spacing: 6) {
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgPanel : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: groups

    private var currentGroups: [DupGroup] { tab == .exact ? live.exact : live.similar }

    @ViewBuilder
    private var groupsList: some View {
        if currentGroups.isEmpty && !live.scanning {
            VStack(spacing: 8) {
                Image(systemName: tab == .exact ? "checkmark.seal" : "photo.stack")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Tokens.text3)
                Text(tab == .exact ? "No exact duplicates found" : "No visually similar images found")
                    .font(.system(size: 13, weight: .semibold))
                Text(tab == .exact
                     ? "Bloatmac compared file contents byte-for-byte and found nothing identical."
                     : "Vision compared image content; nothing crossed the similarity threshold.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.text3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(currentGroups) { group in
                    DupGroupCard(group: group)
                }
            }
        }
    }
}

// MARK: - Group card

struct DupGroupCard: View {
    let group: DupGroup
    @ObservedObject private var live = LiveDuplicates.shared
    @State private var expanded: Bool = true

    private var recoverable: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: group.recoverableBytes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                        .frame(width: 14)
                    if group.kind == .similarImage, let first = group.items.first {
                        QLThumb(url: first.url, size: 40)
                    } else {
                        Image(systemName: kindIcon)
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
                            .foregroundStyle(Tokens.text2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.items.first?.name ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Pill(text: group.kind == .exact ? "Exact match" : "Visually similar",
                                 kind: group.kind == .exact ? .danger : .warn, dot: true)
                            Text("\(group.items.count) copies").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(recoverable).font(.system(size: 13, weight: .heavy)).monospacedDigit()
                        Text("recoverable").font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ForEach(group.items) { item in
                    DupItemRow(group: group, item: item)
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private var kindIcon: String {
        switch group.kind { case .exact: return "doc.on.doc"; case .similarImage: return "photo.stack" }
    }
}

struct DupItemRow: View {
    let group: DupGroup
    let item: DupItem
    @State private var hover = false

    private var sizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB, .useKB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: item.sizeBytes)
    }
    private var modText: String {
        guard let d = item.modified else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: d)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { LiveDuplicates.shared.toggleKeep(groupID: group.id, itemID: item.id) } label: {
                ZStack {
                    Circle().stroke(item.keep ? Tokens.good : Tokens.borderStrong, lineWidth: 1.5)
                    if item.keep { Circle().fill(Tokens.good).padding(3) }
                }
                .frame(width: 16, height: 16)
            }.buttonStyle(.plain)
                .help(item.keep ? "Will be kept" : "Will be moved to Trash")

            if group.kind == .similarImage {
                QLThumb(url: item.url, size: 48)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(!item.keep, color: Tokens.text3)
                    .foregroundStyle(item.keep ? Tokens.text : Tokens.text3)
                Text(item.parent).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let dist = item.visualDistance {
                Pill(text: String(format: "Δ %.2f", dist), kind: .neutral, dot: true)
                    .help("Vision distance from cluster representative — lower is more similar (0 = identical).")
            }

            Text(modText).font(.system(size: 11.5)).foregroundStyle(Tokens.text3).frame(width: 110, alignment: .trailing)
            Text(sizeText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().frame(width: 90, alignment: .trailing)

            Button { LiveDuplicates.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hover ? Tokens.bgHover : Color.clear)
        .onTapGesture(count: 2) { LiveDuplicates.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct UnusedScreen: View {
    @ObservedObject private var live = LiveUnused.shared
    @State private var selected: Set<URL> = []
    @State private var tab: Tab = .apps
    @State private var confirmTrash: Bool = false

    enum Tab: String, CaseIterable { case apps = "Apps", files = "Files & folders" }

    private var current: [UnusedEntry] {
        tab == .apps ? live.apps : live.files
    }

    var body: some View {
        ScreenScroll {
            header
            if live.totalCount == 0 && !live.scanning {
                EmptyState(
                    icon: "clock.badge.questionmark",
                    title: "Nothing flagged as unused",
                    message: "Bloatmac uses Spotlight's last-used metadata for apps and access timestamps for files. Adjust the threshold or run a scan.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                listCard
            }
        }
        .task { live.startIfNeeded() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Unused & Old").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                thresholdMenu
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                if !selected.isEmpty {
                    Btn(label: "Move \(selected.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selected.count) item(s) to Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.moveToTrash(selected)
                selected.removeAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items can be restored from Trash until you empty it.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalCount == 0 { return "" }
        return "\(live.apps.count) apps · \(live.files.count) files & folders · \(live.totalText) reclaimable · older than \(live.thresholdDays) days"
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach([60, 120, 180, 365, 730], id: \.self) { days in
                Button(thresholdLabel(days)) {
                    live.thresholdDays = days
                    live.scan()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text("> \(thresholdLabel(live.thresholdDays))").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func thresholdLabel(_ days: Int) -> String {
        if days >= 365 { return "\(days/365) year\(days/365 > 1 ? "s" : "")" }
        if days >= 30 { return "\(days/30) months" }
        return "\(days) days"
    }

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .apps ? live.apps.count : live.files.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t; selected.removeAll() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t == .apps ? "app.dashed" : "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgPanel : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var listCard: some View {
        if current.isEmpty && !live.scanning {
            VStack(spacing: 8) {
                Image(systemName: tab == .apps ? "checkmark.seal" : "folder.badge.minus")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Tokens.text3)
                Text(tab == .apps ? "All your apps are in active use" : "No old files in tracked folders")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { toggleSelectAll() } label: {
                        AppCheckbox(on: !selected.isEmpty && selected.count == current.count)
                    }.buttonStyle(.plain).frame(width: 22)
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LOCATION").frame(width: 200, alignment: .leading)
                    Text("LAST USED").frame(width: 110, alignment: .trailing)
                    Text("SIZE").frame(width: 90, alignment: .trailing)
                    Text("").frame(width: 28)
                }
                .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Tokens.bgPanel2)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(current) { item in
                        UnusedEntryRow(item: item,
                                      selected: selected.contains(item.id),
                                      toggle: { toggle(item.id) })
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        }
    }

    private func toggle(_ id: URL) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleSelectAll() {
        if selected.count == current.count { selected.removeAll() }
        else { selected = Set(current.map(\.id)) }
    }
}

struct UnusedEntryRow: View {
    let item: UnusedEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    private var icon: String {
        switch item.kind {
        case .app: return "app.dashed"
        case .folder: return "folder"
        case .file: return "doc"
        }
    }
    private var iconColor: Color {
        switch item.kind {
        case .app: return Tokens.catApps
        case .folder: return Tokens.catDocs
        case .file: return Tokens.text2
        }
    }
    private var ageColor: Color {
        if item.ageDays >= 365 { return Tokens.danger }
        if item.ageDays >= 180 { return Tokens.warn }
        return Tokens.text3
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected) }
                .buttonStyle(.plain).frame(width: 22)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(iconColor.opacity(0.12)))
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.parent)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ageColor)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Button { LiveUnused.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }
            .buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveUnused.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct DownloadsCacheScreen: View {
    @ObservedObject private var live = LiveDownloadsCache.shared
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .downloads
    @State private var selectedDownloads: Set<URL> = []
    @State private var selectedCaches: Set<URL> = []
    @State private var filterCategory: DownloadCategory? = nil
    @State private var confirmTrash: Bool = false
    @State private var confirmCleanCache: Bool = false

    enum Tab: String, CaseIterable { case downloads = "Downloads", caches = "App caches" }

    var body: some View {
        ScreenScroll {
            header
            if live.totalCount == 0 && !live.scanning {
                EmptyState(
                    icon: "arrow.down.circle",
                    title: "Nothing to clean yet",
                    message: "Bloatmac inventories ~/Downloads and per-app caches. Spotlight is consulted for download-source URLs.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                if tab == .downloads { downloadsView } else { cachesView }
            }
        }
        .task { live.startIfNeeded() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Downloads & Cache").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                if tab == .downloads, !selectedDownloads.isEmpty {
                    Btn(label: "Move \(selectedDownloads.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
                if tab == .caches, !selectedCaches.isEmpty {
                    Btn(label: "Clean \(selectedCaches.count) cache\(selectedCaches.count > 1 ? "s" : "")", icon: "sparkles", style: .primary) {
                        confirmCleanCache = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selectedDownloads.count) item(s) to Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.trashDownloads(selectedDownloads); selectedDownloads.removeAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Empty \(selectedCaches.count) cache director\(selectedCaches.count > 1 ? "ies" : "y")?",
               isPresented: $confirmCleanCache) {
            Button("Clean", role: .destructive) {
                let n = live.cleanCaches(selectedCaches); selectedCaches.removeAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app will rebuild its cache the next time it runs.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalCount == 0 { return "" }
        return "\(live.downloads.count) downloads (\(live.totalDownloadsText)) · \(live.caches.count) caches · up to \(live.safeCleanText) safe to clean"
    }

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .downloads ? live.downloads.count : live.caches.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t == .downloads ? "arrow.down.circle" : "tray.full")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgPanel : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Downloads view

    private var filteredDownloads: [DLEntry] {
        guard let f = filterCategory else { return live.downloads }
        return live.downloads.filter { $0.category == f }
    }

    @ViewBuilder
    private var downloadsView: some View {
        categoryFilterChips
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAllDownloads() } label: {
                    AppCheckbox(on: !selectedDownloads.isEmpty && selectedDownloads.count == filteredDownloads.count)
                }.buttonStyle(.plain).frame(width: 22)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("FROM").frame(width: 160, alignment: .leading)
                Text("DOWNLOADED").frame(width: 110, alignment: .trailing)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(filteredDownloads) { item in
                    DownloadRow(item: item,
                                selected: selectedDownloads.contains(item.id),
                                toggle: { toggleDownload(item.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    @ViewBuilder
    private var categoryFilterChips: some View {
        let counts = Dictionary(grouping: live.downloads, by: \.category).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", count: live.downloads.count, color: state.accent.value, active: filterCategory == nil, showDot: false) {
                    filterCategory = nil; selectedDownloads.removeAll()
                }
                ForEach(DownloadCategory.allCases, id: \.self) { cat in
                    let c = counts[cat] ?? 0
                    if c > 0 {
                        chip(label: cat.label, count: c, color: cat.color, active: filterCategory == cat, showDot: true) {
                            filterCategory = (filterCategory == cat ? nil : cat)
                            selectedDownloads.removeAll()
                        }
                    }
                }
            }
        }
    }

    private func chip(label: String, count: Int, color: Color, active: Bool, showDot: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showDot {
                    Circle().fill(active ? Color.white : color).frame(width: 6, height: 6)
                }
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .heavy))
                    .monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(active ? Color.white.opacity(0.22) : Tokens.bgPanel2))
                    .foregroundStyle(active ? Color.white : Tokens.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? color : Tokens.bgPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Color.clear : Tokens.border, lineWidth: 1)
            )
            .foregroundStyle(active ? Color.white : Tokens.text)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func toggleDownload(_ id: URL) {
        if selectedDownloads.contains(id) { selectedDownloads.remove(id) } else { selectedDownloads.insert(id) }
    }
    private func toggleSelectAllDownloads() {
        let visible = filteredDownloads
        if selectedDownloads.count == visible.count { selectedDownloads.removeAll() }
        else { selectedDownloads = Set(visible.map(\.id)) }
    }

    // MARK: - Caches view

    @ViewBuilder
    private var cachesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAllCaches() } label: {
                    AppCheckbox(on: !selectedCaches.isEmpty && selectedCaches.count == live.caches.count)
                }.buttonStyle(.plain).frame(width: 22)
                Text("APP / SOURCE").frame(maxWidth: .infinity, alignment: .leading)
                Text("LAST WRITE").frame(width: 110, alignment: .trailing)
                Text("SIZE").frame(width: 100, alignment: .trailing)
                Text("STATUS").frame(width: 110, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(live.caches) { c in
                    CacheRow(item: c,
                             selected: selectedCaches.contains(c.id),
                             toggle: { toggleCache(c.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }

    private func toggleCache(_ id: URL) {
        if selectedCaches.contains(id) { selectedCaches.remove(id) } else { selectedCaches.insert(id) }
    }
    private func toggleSelectAllCaches() {
        let onlySafe = live.caches.filter(\.safeToClean).map(\.id)
        if selectedCaches == Set(onlySafe) { selectedCaches.removeAll() }
        else { selectedCaches = Set(onlySafe) }
    }
}

struct DownloadRow: View {
    let item: DLEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var ocrOpen = false
    @ObservedObject private var live = LiveDownloadsCache.shared
    @EnvironmentObject private var state: AppState

    private var isOCREligible: Bool {
        item.category == .media &&
        LiveDownloadsCache.ocrEligibleExtensions.contains(item.url.pathExtension.lowercased())
    }
    private var ocrText: String? {
        guard let t = live.ocr[item.url], !t.isEmpty else { return nil }
        return t
    }
    private var ocrLoading: Bool { isOCREligible && live.ocr[item.url] == nil }

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected) }
                .buttonStyle(.plain).frame(width: 22)

            HStack(spacing: 8) {
                if isOCREligible {
                    QLThumb(url: item.url, size: 36)
                } else {
                    Image(systemName: item.category.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.category.color)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(item.category.color.opacity(0.15)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.kind).font(.system(size: 10.5)).foregroundStyle(Tokens.text3).lineLimit(1)
                        if let text = ocrText {
                            Button { ocrOpen = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "text.viewfinder").font(.system(size: 9, weight: .semibold))
                                    Text("“\(text)”")
                                        .font(.system(size: 10.5, design: .serif)).italic()
                                        .lineLimit(1)
                                }
                                .foregroundStyle(state.accent.value)
                            }
                            .buttonStyle(.plain)
                            .help("Click to view full recognized text")
                            .popover(isPresented: $ocrOpen, arrowEdge: .bottom) {
                                OCRPreviewPopover(name: item.name, text: text)
                            }
                        } else if ocrLoading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini).scaleEffect(0.55)
                                Text("Reading text…").font(.system(size: 10)).italic().foregroundStyle(Tokens.text4)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { live.ocrIfEligible(for: item) }

            HStack(spacing: 4) {
                if let src = item.sourceDomain, !src.isEmpty {
                    Image(systemName: "link").font(.system(size: 10))
                    Text(src).font(.system(size: 11.5)).lineLimit(1)
                } else {
                    Text("—").font(.system(size: 11.5))
                }
            }
            .foregroundStyle(Tokens.text3)
            .frame(width: 160, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5))
                .foregroundStyle(item.ageDays > 30 ? Tokens.warn : Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Button { LiveDownloadsCache.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveDownloadsCache.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct OCRPreviewPopover: View {
    let name: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder")
                Text("Recognized text").font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
            }
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 9))
                Text("Extracted by Apple Vision · Recognize Text")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Tokens.text4)
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct CacheRow: View {
    let item: AppCacheEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected) }
                .buttonStyle(.plain).frame(width: 22)
                .opacity(item.safeToClean ? 1 : 0.4)
                .disabled(!item.safeToClean)

            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.safeToClean ? Tokens.good : Tokens.warn)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill((item.safeToClean ? Tokens.good : Tokens.warn).opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(item.bundleID).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            HStack {
                Spacer()
                Pill(text: item.safeToClean ? "Safe" : "Keep",
                     kind: item.safeToClean ? .good : .warn, dot: true)
                    .help(item.cleanReason ?? "")
            }
            .frame(width: 110, alignment: .trailing)

            Button { LiveDownloadsCache.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveDownloadsCache.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct MemoryScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveMemory.shared
    @State private var killTarget: ProcMem? = nil

    var body: some View {
        ScreenScroll {
            header
            compositionPanel
            HStack(alignment: .top, spacing: 16) {
                pressurePanel.frame(width: 320)
                historyPanel.frame(maxWidth: .infinity)
            }
            HStack(alignment: .top, spacing: 16) {
                gpuPanel.frame(width: 320)
                countersPanel.frame(maxWidth: .infinity)
            }
            topProcsPanel
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
        .alert(item: $killTarget) { p in
            Alert(
                title: Text("Quit \(p.name)?"),
                message: Text("This sends SIGTERM to PID \(p.id) (\(LiveMemory.fmt(p.bytes)) in use). Unsaved data may be lost."),
                primaryButton: .destructive(Text("Force quit")) { live.killProcess(p.id, force: true) },
                secondaryButton: .default(Text("Quit"))         { live.killProcess(p.id, force: false) }
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Memory").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    PulsingDot(color: live.pressure.color, size: 9)
                }
                Text("\(LiveMemory.fmt(live.totalBytes)) physical · pressure \(live.pressure.label.lowercased()) · \(live.gpuName)\(live.gpuCores > 0 ? " · \(live.gpuCores)-core GPU" : "")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: "Activity Monitor", icon: "arrow.up.right", style: .secondary) {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Composition

    private var compositionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Composition").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if live.lastUpdate != .distantPast {
                    Text("Updated \(live.lastUpdate, style: .relative) ago")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
                }
            }
            CompositionBar(segments: [
                .init(label: "App",        bytes: live.appBytes,        color: Tokens.catApps),
                .init(label: "Wired",      bytes: live.wiredBytes,      color: Tokens.danger),
                .init(label: "Compressed", bytes: live.compressedBytes, color: Tokens.purple),
                .init(label: "Cached",     bytes: live.cachedBytes,     color: Tokens.good),
                .init(label: "Free",       bytes: live.freeBytes,       color: Tokens.text4),
            ], total: live.totalBytes)
            .frame(height: 22)

            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                legendItem(color: Tokens.catApps, label: "App memory",  bytes: live.appBytes,
                           hint: "Active + inactive anonymous pages")
                legendItem(color: Tokens.danger,  label: "Wired",       bytes: live.wiredBytes,
                           hint: "Cannot be paged — kernel & locked")
                legendItem(color: Tokens.purple,  label: "Compressed",  bytes: live.compressedBytes,
                           hint: "Pages held in compressor")
                legendItem(color: Tokens.good,    label: "Cached files",bytes: live.cachedBytes,
                           hint: "File-backed, reusable instantly")
                legendItem(color: Tokens.text4,   label: "Free",        bytes: live.freeBytes,
                           hint: "Immediately available")
                legendItem(color: Tokens.warn,    label: "Swap used",   bytes: live.swapUsed,
                           hint: live.swapTotal == 0 ? "No swap allocated" : "of \(LiveMemory.fmt(live.swapTotal))")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func legendItem(color: Color, label: String, bytes: UInt64, hint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
                    Text(LiveMemory.fmt(bytes)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Tokens.text2)
                        .contentTransition(.numericText(value: Double(bytes)))
                }
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Tokens.text4).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pressure ring

    private var pressurePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pressure").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
            }
            ZStack {
                MemoryRing(used: live.usedFraction,
                           wired: Double(live.wiredBytes) / max(1, Double(live.totalBytes)),
                           color: live.pressure.color)
                    .frame(width: 188, height: 188)
                VStack(spacing: 2) {
                    Text("\(Int((live.usedFraction * 100).rounded()))%")
                        .font(.system(size: 34, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(Tokens.text)
                        .contentTransition(.numericText(value: live.usedFraction))
                    Text("\(LiveMemory.fmt(live.usedBytes)) of \(LiveMemory.fmt(live.totalBytes))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                pressureChip(.normal); pressureChip(.warning); pressureChip(.critical)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func pressureChip(_ p: MemoryPressure) -> some View {
        let active = live.pressure == p
        return HStack(spacing: 6) {
            Circle().fill(p.color).frame(width: 6, height: 6)
            Text(p.label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? p.color.opacity(0.18) : Tokens.bgPanel2))
        .foregroundStyle(active ? p.color : Tokens.text3)
        .frame(maxWidth: .infinity)
    }

    // MARK: - History

    private var historyPanel: some View {
        let samples = live.historyInRange
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Usage history").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                rangePicker
            }
            HStack(spacing: 12) {
                miniStat(label: "Now",  value: pct(samples.last?.u))
                miniStat(label: "Peak", value: pct(samples.map { $0.u }.max()))
                miniStat(label: "Avg",  value: pct(samples.isEmpty ? nil : Float(samples.reduce(0) { $0 + $1.u } / Float(samples.count))))
                miniStat(label: "Samples", value: "\(samples.count)")
            }
            MemorySparkline(values: samples.map { Double($0.u) },
                            secondary: samples.map { Double($0.g) },
                            color: live.pressure.color,
                            secondaryColor: Tokens.indigo)
                .frame(height: 110)
            HStack(spacing: 12) {
                seriesDot(color: live.pressure.color, label: "Memory used")
                seriesDot(color: Tokens.indigo,         label: "GPU utilization")
                Spacer()
                Button("Clear history") { live.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func pct(_ v: Float?) -> String {
        guard let v else { return "—" }
        return "\(Int((Double(v) * 100).rounded()))%"
    }

    private func seriesDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 14, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.bgPanel2))
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(HistoryRange.allCases) { r in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { live.range = r }
                } label: {
                    Text(r.label)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(live.range == r ? Tokens.bgPanel : .clear)
                                .shadow(color: .black.opacity(live.range == r ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .foregroundStyle(live.range == r ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
    }

    // MARK: - GPU panel

    private var gpuPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GPU").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(live.gpuCores > 0 ? "\(live.gpuCores) cores" : "")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Tokens.bgPanel2, lineWidth: 8).frame(width: 60, height: 60)
                    Circle().trim(from: 0, to: live.gpuUtilization)
                        .stroke(LinearGradient(colors: [Tokens.indigo.opacity(0.6), Tokens.indigo],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 60, height: 60)
                        .animation(.easeInOut(duration: 0.4), value: live.gpuUtilization)
                    Text("\(Int((live.gpuUtilization * 100).rounded()))%")
                        .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                        .contentTransition(.numericText(value: live.gpuUtilization))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.gpuName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Utilization · live").font(.system(size: 10.5)).foregroundStyle(Tokens.text4)
                }
                Spacer()
            }
            Divider().foregroundStyle(Tokens.divider)
            stat("In-use VRAM",    LiveMemory.fmt(live.gpuInUseBytes))
            stat("Allocated VRAM", LiveMemory.fmt(live.gpuAllocBytes))
            stat("Recoveries",     "\(live.gpuRecoveryCount)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Counters

    private var countersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Counters").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                kv("Page-ins",       "\(live.pageIns)")
                kv("Page-outs",      "\(live.pageOuts)")
                kv("Compressions",   "\(live.compressions)")
                kv("Decompressions", "\(live.decompressions)")
                kv("Swap used",      LiveMemory.fmt(live.swapUsed))
                kv("Swap total",     LiveMemory.fmt(live.swapTotal))
                kv("Free",           LiveMemory.fmt(live.freeBytes))
                kv("Cached",         LiveMemory.fmt(live.cachedBytes))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func kv(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 13, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Tokens.text3)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text)
        }
    }

    // MARK: - Top processes

    private var topProcsPanel: some View {
        let rows = live.filteredProcesses
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Processes").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                searchField
                sortPicker
                Toggle("Helpers", isOn: $live.procIncludeHelpers)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            if rows.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 24)
            } else {
                let maxBytes = live.topProcesses.map(\.bytes).max() ?? 1
                VStack(spacing: 0) {
                    ForEach(rows) { p in
                        ProcessRow(proc: p, maxBytes: maxBytes,
                                   onKill: { killTarget = p },
                                   onReveal: { revealProc(p) })
                        if p.id != rows.last?.id {
                            Divider().foregroundStyle(Tokens.divider)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func revealProc(_ p: ProcMem) {
        if let app = NSRunningApplication(processIdentifier: p.id),
           let url = app.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.text4)
            TextField("Filter processes…", text: $live.procSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 160)
            if !live.procSearch.isEmpty {
                Button { live.procSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Tokens.text4)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
    }

    private var sortPicker: some View {
        Menu {
            ForEach(ProcSort.allCases) { s in
                Button { live.procSort = s } label: {
                    HStack {
                        Text(s.rawValue)
                        if live.procSort == s { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .bold))
                Text(live.procSort.rawValue).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Memory ring

private struct MemoryRing: View {
    var used: Double
    var wired: Double
    var color: Color
    @State private var animatedUsed: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Tokens.bgPanel2, lineWidth: 14)
            Circle()
                .trim(from: 0, to: animatedUsed)
                .stroke(LinearGradient(colors: [color.opacity(0.55), color],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: min(animatedUsed, wired))
                .stroke(Tokens.danger.opacity(0.85),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(14)
            Circle().stroke(color.opacity(0.10), lineWidth: 1).padding(7)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { animatedUsed = used } }
        .onChange(of: used) { _, n in withAnimation(.easeInOut(duration: 0.4)) { animatedUsed = n } }
    }
}

// MARK: - Composition bar

private struct CompositionSegment: Identifiable {
    let id = UUID()
    let label: String
    let bytes: UInt64
    let color: Color
}

private struct CompositionBar: View {
    let segments: [CompositionSegment]
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            let sum = segments.reduce(UInt64(0)) { $0 &+ $1.bytes }
            // Normalize to whichever is larger so the bar never overflows its frame.
            let denom = Double(max(total, max(sum, 1)))
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    let frac = Double(seg.bytes) / denom
                    Rectangle()
                        .fill(LinearGradient(colors: [seg.color.opacity(0.85), seg.color],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: max(0, geo.size.width * frac))
                        .help("\(seg.label) — \(LiveMemory.fmt(seg.bytes))")
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeInOut(duration: 0.4), value: total)
            .animation(.easeInOut(duration: 0.4), value: segments.map(\.bytes))
        }
    }
}

// MARK: - Sparkline

private struct MemorySparkline: View {
    let values: [Double]
    let secondary: [Double]
    let color: Color
    let secondaryColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<5) { i in
                    let y = geo.size.height * CGFloat(i) / 4
                    Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)) }
                        .stroke(Tokens.divider, lineWidth: 0.5)
                }

                if values.count >= 2 {
                    linePath(values: values, in: geo.size, closed: true)
                        .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    linePath(values: values, in: geo.size, closed: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if let last = values.last {
                        let x = geo.size.width
                        let y = geo.size.height * (1 - CGFloat(min(max(last, 0), 1)))
                        Circle().fill(color).frame(width: 6, height: 6)
                            .position(x: x - 3, y: y).shadow(color: color.opacity(0.7), radius: 4)
                    }
                }
                if secondary.count >= 2 {
                    linePath(values: secondary, in: geo.size, closed: false)
                        .stroke(secondaryColor.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round,
                                                   dash: [3, 3]))
                }
            }
            .animation(.linear(duration: 0.5), value: values.count)
        }
    }

    private func linePath(values: [Double], in size: CGSize, closed: Bool) -> Path {
        let count = max(values.count, 1)
        let stepX = size.width / CGFloat(max(count - 1, 1))
        var p = Path()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat(min(max(v, 0), 1)))
            if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
        }
        if closed {
            p.addLine(to: .init(x: size.width, y: size.height))
            p.addLine(to: .init(x: 0,          y: size.height))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Process row

private struct ProcessRow: View {
    let proc: ProcMem
    let maxBytes: UInt64
    let onKill: () -> Void
    let onReveal: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2).frame(width: 28, height: 28)
                LazyAppIcon(bundleURL: proc.bundlePath.map { URL(fileURLWithPath: $0) },
                            fallback: "gearshape.2",
                            fallbackColor: Tokens.text3)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(proc.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if proc.cpu > 1 {
                        Text("\(String(format: "%.0f", proc.cpu))% CPU")
                            .font(.system(size: 10, weight: .heavy)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Tokens.bgPanel2))
                            .foregroundStyle(proc.cpu > 50 ? Tokens.warn : Tokens.text3)
                    }
                    Spacer()
                    Text(LiveMemory.fmt(proc.bytes))
                        .font(.system(size: 11.5, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(Tokens.text2)
                        .contentTransition(.numericText(value: Double(proc.bytes)))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.bgPanel2)
                        Capsule()
                            .fill(LinearGradient(colors: [Tokens.catApps.opacity(0.6), Tokens.catApps],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(min(1, Double(proc.bytes) / Double(max(maxBytes, 1)))))
                    }
                }
                .frame(height: 4)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("PID \(proc.id)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Tokens.text4)
                HStack(spacing: 4) {
                    if proc.isApp {
                        Button(action: onReveal) {
                            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Tokens.text3)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.bgPanel2))
                        }.buttonStyle(.plain).help("Reveal in Finder")
                    }
                    Button(action: onKill) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.danger.opacity(hover ? 1 : 0.85)))
                    }.buttonStyle(.plain).help("Quit process")
                }
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Tokens.bgHover : .clear))
        .onHover { hover = $0 }
    }
}

struct StartupScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveStartup.shared
    @State private var removeTarget: LaunchAgentItem? = nil
    @State private var inspect: LaunchAgentItem? = nil

    var body: some View {
        ScreenScroll {
            header
            summaryRow
            scopeChips
            HStack(spacing: 10) {
                searchField
                filterPicker
                sortPicker
                Spacer()
            }
            itemsPanel
        }
        .alert(item: $removeTarget) { item in
            Alert(
                title: Text("Remove \(item.displayName)?"),
                message: Text("This unloads the agent and moves\n\(item.id.path)\nto the Trash. You can restore it from the Trash if needed."),
                primaryButton: .destructive(Text("Remove")) { live.remove(item) },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $inspect) { item in
            StartupInspector(item: item).environmentObject(state)
        }
        .onAppear { live.startIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Startup items").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text("\(live.items.count) launch agents & daemons · \(live.loadedCount) loaded · \(live.disabledCount) disabled · \(live.unknownCount) unverified")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: "Login Items", icon: "arrow.up.right", style: .secondary) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                Btn(label: live.scanning ? "Scanning…" : "Rescan", icon: "arrow.clockwise", style: .secondary) {
                    live.rescan()
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var summaryRow: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(StartupScope.allCases) { scope in
                summaryCard(scope)
            }
        }
    }

    private func summaryCard(_ scope: StartupScope) -> some View {
        let count = live.counts[scope] ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(scope.color).frame(width: 6, height: 6)
                Text(scope.label.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
                    .foregroundStyle(Tokens.text4).lineLimit(1)
            }
            Text("\(count)")
                .font(.system(size: 22, weight: .heavy)).monospacedDigit()
                .foregroundStyle(Tokens.text)
                .contentTransition(.numericText(value: Double(count)))
            Text(scope.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10)).monospaced().foregroundStyle(Tokens.text4)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
    }

    private var scopeChips: some View {
        HStack(spacing: 8) {
            ForEach(StartupScope.allCases) { scope in
                let active = live.scopeFilter.contains(scope)
                Button {
                    if active { live.scopeFilter.remove(scope) } else { live.scopeFilter.insert(scope) }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(active ? Color.white : scope.color).frame(width: 6, height: 6)
                        Text(scope.shortLabel).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(active ? scope.color : Tokens.bgPanel))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? Color.clear : Tokens.border))
                    .foregroundStyle(active ? Color.white : Tokens.text)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.text4)
            TextField("Search labels, programs, publishers…", text: $live.search)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 280)
            if !live.search.isEmpty {
                Button { live.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Tokens.text4)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
    }

    private var filterPicker: some View {
        Menu {
            ForEach(StartupFilter.allCases) { f in
                Button { live.filter = f } label: {
                    HStack { Text(f.label); if live.filter == f { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .bold))
                Text(live.filter.label).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text2)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var sortPicker: some View {
        Menu {
            ForEach(StartupSort.allCases) { s in
                Button { live.sort = s } label: {
                    HStack { Text(s.rawValue); if live.sort == s { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .bold))
                Text(live.sort.rawValue).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .foregroundStyle(Tokens.text2)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var itemsPanel: some View {
        VStack(spacing: 0) {
            if live.visible.isEmpty && live.scanning {
                ScanningStartupView(phaseText: live.phase, progress: live.progress)
                    .frame(height: 340)
                    .frame(maxWidth: .infinity)
            } else if live.visible.isEmpty {
                EmptyState(icon: "powerplug",
                           title: "Nothing matches",
                           message: "Try widening the filters or clearing the search.",
                           actionLabel: nil, action: nil)
                    .frame(height: 260)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(live.visible) { item in
                        StartupRow(item: item,
                                   onInspect: { inspect = item },
                                   onReveal:  { live.revealInFinder(item) },
                                   onOpen:    { live.openPlist(item) },
                                   onToggle:  { live.setEnabled(item, enabled: item.isDisabled) },
                                   onRemove:  { removeTarget = item })
                            .equatable()
                        Divider().foregroundStyle(Tokens.divider)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }
}

private struct ScanningStartupView: View {
    let phaseText: String
    let progress: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 16) {
                radar(time: t)
                VStack(spacing: 4) {
                    Text("Inspecting startup items")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Tokens.text)
                    Text(phaseText.isEmpty ? "Working…" : phaseText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                    progressBar.frame(width: 220)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        skeletonRow(time: t, row: i)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    @ViewBuilder
    private func radar(time t: Double) -> some View {
        ZStack {
            ForEach(0..<3) { i in
                let cycle = 1.6
                let phase = (t - Double(i) * 0.4).truncatingRemainder(dividingBy: cycle) / cycle
                let scale = 0.5 + phase * (1.9 - Double(i) * 0.3)
                let opacity = max(0, 0.85 - phase * 1.0)
                Circle()
                    .stroke(Tokens.warn, lineWidth: 1.4)
                    .frame(width: 64, height: 64)
                    .scaleEffect(scale)
                    .opacity(opacity)
            }
            Circle()
                .fill(LinearGradient(colors: [Tokens.warn.opacity(0.5), Tokens.warn],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .shadow(color: Tokens.warn.opacity(0.55), radius: 16)
            Image(systemName: "powerplug.fill")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 180, height: 180)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.bgPanel2)
                Capsule()
                    .fill(LinearGradient(colors: [Tokens.warn.opacity(0.7), Tokens.warn],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * max(0.05, min(1, progress)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: progress)
    }

    private func skeletonRow(time t: Double, row i: Int) -> some View {
        // Sweep cycles every 1.4s, offset per row.
        let sweepPhase = ((t - Double(i) * 0.18).truncatingRemainder(dividingBy: 1.4)) / 1.4
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Tokens.bgPanel2).frame(width: 160 + CGFloat(i*16), height: 8)
                Capsule().fill(Tokens.bgPanel2).frame(width: 220 + CGFloat(i*20), height: 6)
            }
            Spacer()
            Capsule().fill(Tokens.bgPanel2).frame(width: 44, height: 8)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(
            GeometryReader { geo in
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Tokens.warn.opacity(0.22), location: 0.45),
                    .init(color: Tokens.warn.opacity(0.22), location: 0.55),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.6)
                .offset(x: CGFloat(sweepPhase) * (geo.size.width + geo.size.width * 0.6) - geo.size.width * 0.6)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tokens.border, lineWidth: 0.5))
    }
}

private struct LazyAppIcon: View {
    let bundleURL: URL?
    let fallback: String
    let fallbackColor: Color
    var size: CGFloat = 22
    @State private var icon: NSImage? = nil

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(fallbackColor)
            }
        }
        .onAppear { resolve() }
    }

    private func resolve() {
        guard icon == nil, let url = bundleURL else { return }
        DispatchQueue.main.async {
            self.icon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

private struct StartupRow: View, Equatable {
    let item: LaunchAgentItem
    let onInspect: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    static func == (a: StartupRow, b: StartupRow) -> Bool {
        a.item.id == b.item.id
            && a.item.isLoaded == b.item.isLoaded
            && a.item.isDisabled == b.item.isDisabled
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Tokens.bgPanel2).frame(width: 36, height: 36)
                LazyAppIcon(bundleURL: item.appBundleURL,
                            fallback: item.scope.isDaemon ? "gearshape.2.fill" : "person.crop.circle.fill",
                            fallbackColor: item.scope.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    pill(text: item.scope.shortLabel, color: item.scope.color)
                    pill(text: item.statePill, color: item.stateColor)
                    if item.runAtLoad {
                        pill(text: "Run at load", color: Tokens.indigo)
                    }
                    if item.keepAlive {
                        pill(text: "Keep alive", color: Tokens.purple)
                    }
                    if item.risk != .known {
                        pill(text: item.risk.label, color: item.risk.color)
                    }
                    Spacer()
                    if let pid = item.pid { Text("PID \(pid)").font(.system(size: 10.5)).monospaced().foregroundStyle(Tokens.text4) }
                }
                Text(item.label).font(.system(size: 11)).monospaced().foregroundStyle(Tokens.text3).lineLimit(1)
                if let p = item.program {
                    Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10.5)).monospaced().foregroundStyle(Tokens.text4)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                iconBtn("info.circle", help: "Inspect", action: onInspect)
                iconBtn("magnifyingglass", help: "Reveal in Finder", action: onReveal)
                iconBtn("doc.text", help: "Open plist", action: onOpen)
                if item.canRemove {
                    iconBtn(item.isDisabled ? "play.fill" : "pause.fill",
                            help: item.isDisabled ? "Enable" : "Disable",
                            action: onToggle, color: Tokens.warn)
                    iconBtn("trash", help: "Remove from startup", action: onRemove, color: Tokens.danger)
                } else {
                    Text("Admin").font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Tokens.bgPanel2))
                        .foregroundStyle(Tokens.text4)
                        .help("Items in this scope require admin rights to modify. Use System Settings.")
                }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(hover ? Tokens.bgHover : .clear)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Inspect…") { onInspect() }
            Button("Reveal plist in Finder") { onReveal() }
            Button("Open plist") { onOpen() }
            if item.canRemove {
                Divider()
                Button(item.isDisabled ? "Enable" : "Disable") { onToggle() }
                Button("Remove from startup", role: .destructive) { onRemove() }
            }
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func iconBtn(_ name: String, help: String, action: @escaping () -> Void, color: Color = Tokens.text2) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
        }.buttonStyle(.plain).help(help)
    }
}

private struct StartupInspector: View {
    let item: LaunchAgentItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                LazyAppIcon(bundleURL: item.appBundleURL, fallback: "doc.text.fill", fallbackColor: Tokens.text3, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.system(size: 16, weight: .heavy))
                    Text(item.label).font(.system(size: 11)).monospaced().foregroundStyle(Tokens.text3)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)
            Divider().foregroundStyle(Tokens.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("State") {
                        kv("Source",        item.scope.label)
                        kv("State",         item.statePill)
                        kv("PID",           item.pid.map { "\($0)" } ?? "—")
                        kv("Last exit",     item.exitCode.map { "\($0)" } ?? "—")
                        kv("Run at load",   item.runAtLoad ? "Yes" : "No")
                        kv("Keep alive",    item.keepAlive ? "Yes" : "No")
                        kv("Risk",          item.risk.label)
                        kv("Publisher",     item.publisher.isEmpty ? "—" : item.publisher)
                    }
                    section("Files") {
                        kv("plist", item.id.path)
                        kv("Program", item.program ?? "—")
                        if !item.arguments.isEmpty {
                            kv("Arguments", item.arguments.joined(separator: " "))
                        }
                        if let mod = item.lastModified {
                            kv("Modified", mod.formatted(.dateTime.year().month().day().hour().minute()))
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 460)
        .background(Tokens.bgWindow)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.6)
                .foregroundStyle(Tokens.text4)
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
        }
    }
    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundStyle(Tokens.text3).frame(width: 110, alignment: .leading)
            Text(v).font(.system(size: 12)).monospaced().foregroundStyle(Tokens.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct BatteryScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveBattery.shared

    var body: some View {
        Group {
            if live.hasBattery {
                ScreenScroll {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        chargePanel.frame(width: 360)
                        liveStatsPanel.frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        healthPanel.frame(width: 360)
                        insightsPanel.frame(maxWidth: .infinity)
                    }
                    historyPanel
                    HStack(alignment: .top, spacing: 16) {
                        routinePanel.frame(maxWidth: .infinity)
                        topConsumersPanel.frame(width: 380)
                    }
                    identityPanel
                }
            } else {
                EmptyState(icon: "battery.0",
                           title: "No internal battery",
                           message: "BloatMac couldn't read AppleSmartBattery — this Mac may be a desktop.",
                           actionLabel: nil, action: nil)
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Battery").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    PulsingDot(color: live.state.color, size: 9)
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                if live.lowPowerMode {
                    badge("Low Power", color: Tokens.warn, icon: "leaf.fill")
                }
                if live.optimizedCharging {
                    badge("Optimized charging", color: Tokens.good, icon: "checkmark.seal.fill")
                }
                Btn(label: "Energy Saver…", icon: "arrow.up.right", style: .secondary) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var headerSubtitle: String {
        var bits: [String] = []
        bits.append("\(Int((live.percent * 100).rounded()))% · \(live.state.label.lowercased())")
        if live.state == .charging && live.adapterWatts > 0 {
            bits.append("\(live.adapterWatts) W adapter")
        }
        if !live.deviceName.isEmpty { bits.append(live.deviceName) }
        bits.append("\(live.cycleCount) cycles")
        return bits.joined(separator: " · ")
    }

    private func badge(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }

    // MARK: - Charge panel

    private var chargePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Charge").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: live.state.icon).font(.system(size: 10, weight: .bold))
                    Text(live.state.label).font(.system(size: 11, weight: .semibold))
                }.foregroundStyle(live.state.color)
            }
            BatteryGlyph(percent: live.percent, color: live.state.color, charging: live.state == .charging)
                .frame(height: 96)
            VStack(spacing: 2) {
                Text("\(Int((live.percent * 100).rounded()))%")
                    .font(.system(size: 44, weight: .heavy)).monospacedDigit()
                    .contentTransition(.numericText(value: live.percent))
                if live.state == .discharging {
                    Text("\(live.timeRemainingText) remaining · \(String(format: "%.1f", live.predictedDrainPctPerHour))%/hr")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                } else if live.state == .charging {
                    let ttf = live.timeRemaining > 0 ? "\(live.timeRemaining) min to full" : "Calculating…"
                    Text(ttf).font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.text3)
                } else if live.state == .full {
                    Text("Topped up").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.text3)
                } else {
                    Text("Plugged in · holding charge").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.text3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Live stats panel

    private var liveStatsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                stat(icon: "bolt.fill",      color: live.watts >= 0 ? Tokens.good : Tokens.warn,
                     label: live.watts >= 0 ? "Charging at" : "Drawing",
                     value: String(format: "%.1f W", abs(live.watts)))
                stat(icon: "battery.50",     color: Tokens.catApps,
                     label: "Voltage",       value: String(format: "%.2f V", live.voltage))
                stat(icon: "amplifier",      color: Tokens.indigo,
                     label: "Current",       value: String(format: "%.2f A", live.amperage))
                stat(icon: "thermometer",    color: live.tempC > 35 ? Tokens.warn : Tokens.text2,
                     label: "Temperature",   value: String(format: "%.1f°C", live.tempC))
                stat(icon: "powerplug",      color: live.externalConnected ? Tokens.good : Tokens.text3,
                     label: "Adapter",       value: live.externalConnected ? "\(live.adapterWatts) W" : "Unplugged")
                stat(icon: "clock.arrow.circlepath", color: Tokens.purple,
                     label: "Predicted",     value: live.timeRemainingText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func stat(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
                Text(value).font(.system(size: 14, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
            }
        }
    }

    // MARK: - Health panel

    private var healthPanel: some View {
        let pct = live.healthFraction
        let pctText = pct > 0 ? "\(Int((pct * 100).rounded()))%" : "—"
        let cyclePct = min(1.0, Double(live.cycleCount) / Double(max(live.maxCycleCount, 1)))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Health").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("Design \(live.designCapacity)mAh").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().stroke(Tokens.bgPanel2, lineWidth: 9).frame(width: 88, height: 88)
                    Circle().trim(from: 0, to: pct)
                        .stroke(LinearGradient(colors: [healthColor(pct).opacity(0.6), healthColor(pct)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 88, height: 88)
                        .animation(.easeOut(duration: 0.6), value: pct)
                    Text(pctText).font(.system(size: 18, weight: .heavy)).monospacedDigit()
                        .contentTransition(.numericText(value: pct))
                }
                VStack(alignment: .leading, spacing: 6) {
                    miniRow(label: "Cycles",      value: "\(live.cycleCount) / \(live.maxCycleCount)")
                    miniRow(label: "Capacity",    value: "\(live.maxCapacity) mAh")
                    miniRow(label: "Age",         value: live.ageText)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Cycle wear")
                    .font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(Tokens.text4)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.bgPanel2)
                        Capsule()
                            .fill(LinearGradient(colors: [Tokens.good, Tokens.warn, Tokens.danger],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * cyclePct)
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.4), value: cyclePct)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func healthColor(_ p: Double) -> Color {
        if p >= 0.85 { return Tokens.good }
        if p >= 0.70 { return Tokens.warn }
        return Tokens.danger
    }

    private func miniRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Tokens.text3)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text)
        }
    }

    // MARK: - Insights panel

    private var insightsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(Tokens.purple)
                Text("Insights").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach(live.insights) { ins in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(ins.tone.color.opacity(0.15)).frame(width: 32, height: 32)
                            Image(systemName: ins.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(ins.tone.color)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ins.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.text)
                            Text(ins.body).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - History

    private var historyPanel: some View {
        let s = live.samplesInRange
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Charge history").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                rangePicker
            }
            HStack(spacing: 12) {
                miniStat(label: "Now",   value: "\(Int((live.percent * 100).rounded()))%")
                miniStat(label: "Min",   value: pct(s.map { $0.percent }.min()))
                miniStat(label: "Max",   value: pct(s.map { $0.percent }.max()))
                miniStat(label: "Δ",     value: deltaText(s))
                miniStat(label: "Samples", value: "\(s.count)")
                Spacer()
                Button("Clear") { live.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            BatterySparkline(samples: s, color: live.state.color)
                .frame(height: 130)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }
    private func deltaText(_ s: [BatteryReading]) -> String {
        guard let first = s.first?.percent, let last = s.last?.percent else { return "—" }
        let d = (last - first) * 100
        let sign = d >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", d))%"
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 14, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.bgPanel2))
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(BatteryRange.allCases) { r in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { live.range = r }
                } label: {
                    Text(r.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(live.range == r ? Tokens.bgPanel : .clear)
                                .shadow(color: .black.opacity(live.range == r ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .foregroundStyle(live.range == r ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
    }

    // MARK: - Routine heatmap

    private var routinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily routine").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("Last 7 days · time on AC by hour")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            HourlyHeatmap(values: live.hourlyAC, color: Tokens.good)
                .frame(height: 80)
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? "\(h)" : "")
                        .font(.system(size: 9, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Top consumers

    private var topConsumersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top energy users").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(live.state == .discharging ? "live" : "charging — paused")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(live.state == .discharging ? Tokens.good : Tokens.text4)
            }
            if live.topConsumers.isEmpty {
                Text(live.state == .discharging ? "Sampling…" : "Connect to see baseline. We pause sampling while charging to keep readings clean.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    .padding(.vertical, 16)
            } else {
                let maxCPU = live.topConsumers.first?.cpu ?? 1
                VStack(spacing: 0) {
                    ForEach(live.topConsumers) { p in
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2).frame(width: 26, height: 26)
                                LazyAppIcon(bundleURL: p.bundlePath.map { URL(fileURLWithPath: $0) },
                                            fallback: "gearshape.2",
                                            fallbackColor: Tokens.text3)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Tokens.bgPanel2)
                                        Capsule().fill(LinearGradient(colors: [Tokens.warn.opacity(0.6), Tokens.warn], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: geo.size.width * CGFloat(min(1, p.cpu / max(maxCPU, 1))))
                                    }
                                }.frame(height: 4)
                            }
                            Text("\(Int(p.cpu.rounded()))%")
                                .font(.system(size: 11, weight: .heavy)).monospacedDigit()
                                .foregroundStyle(Tokens.text2)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        if p.id != live.topConsumers.last?.id { Divider().foregroundStyle(Tokens.divider) }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Identity

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery identity").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                kv("Manufacturer", live.manufacturer.isEmpty ? "—" : live.manufacturer)
                kv("Model",        live.deviceName.isEmpty ? "—" : live.deviceName)
                kv("Serial",       live.serial.isEmpty ? "—" : live.serial)
                kv("Manufactured", live.manufactureDate.map { $0.formatted(.dateTime.year().month().day()) } ?? "—")
                kv("Adapter",      live.adapterName.isEmpty ? "—" : live.adapterName)
                kv("Adapter watts", live.adapterWatts > 0 ? "\(live.adapterWatts) W" : "—")
                kv("Optimized",     live.optimizedCharging ? "On" : "Off")
                kv("Low Power Mode", live.lowPowerMode ? "On" : "Off")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func kv(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 13, weight: .heavy)).foregroundStyle(Tokens.text).lineLimit(1)
        }
    }
}

// MARK: - Battery glyph

private struct BatteryGlyph: View {
    let percent: Double
    let color: Color
    let charging: Bool
    @State private var animatedPercent: Double = 0
    @State private var bolt = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let bodyW = geo.size.width - 14
            let r: CGFloat = h * 0.18
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: r)
                    .stroke(Tokens.borderStrong, lineWidth: 2)
                    .frame(width: bodyW, height: h)
                RoundedRectangle(cornerRadius: r * 0.6)
                    .fill(Tokens.borderStrong)
                    .frame(width: 8, height: h * 0.45)
                    .offset(x: bodyW + 1)
                RoundedRectangle(cornerRadius: r * 0.7)
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, (bodyW - 8) * animatedPercent), height: h - 8)
                    .padding(4)
                    .shadow(color: color.opacity(0.5), radius: 6)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.5, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: color.opacity(0.6), radius: 4)
                        .scaleEffect(bolt ? 1.0 : 0.92)
                        .frame(width: bodyW, height: h)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                                bolt = true
                            }
                        }
                }
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { animatedPercent = percent } }
        .onChange(of: percent) { _, n in withAnimation(.easeInOut(duration: 0.5)) { animatedPercent = n } }
    }
}

// MARK: - Battery sparkline

private struct BatterySparkline: View {
    let samples: [BatteryReading]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<5) { i in
                    let y = geo.size.height * CGFloat(i) / 4
                    Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)) }
                        .stroke(Tokens.divider, lineWidth: 0.5)
                    Text("\(100 - i*25)%")
                        .font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                        .position(x: 14, y: y + 6)
                }
                if samples.count >= 2 {
                    chargeBands(in: geo.size)
                    fillPath(in: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    linePath(in: geo.size)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    if let last = samples.last {
                        let y = geo.size.height * (1 - CGFloat(last.percent))
                        Circle().fill(color).frame(width: 6, height: 6)
                            .position(x: geo.size.width - 3, y: y).shadow(color: color.opacity(0.7), radius: 4)
                    }
                }
            }
            .animation(.linear(duration: 0.5), value: samples.count)
        }
    }

    private func xFor(_ t: TimeInterval, in size: CGSize) -> CGFloat {
        guard let first = samples.first?.t, let last = samples.last?.t, last > first else { return 0 }
        return size.width * CGFloat((t - first) / (last - first))
    }

    private func linePath(in size: CGSize) -> Path {
        var p = Path()
        for (i, s) in samples.enumerated() {
            let x = xFor(s.t, in: size)
            let y = size.height * (1 - CGFloat(s.percent))
            if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
        }
        return p
    }
    private func fillPath(in size: CGSize) -> Path {
        var p = linePath(in: size)
        p.addLine(to: .init(x: size.width, y: size.height))
        p.addLine(to: .init(x: 0,          y: size.height))
        p.closeSubpath()
        return p
    }
    @ViewBuilder
    private func chargeBands(in size: CGSize) -> some View {
        // Highlight charging stretches with a soft green wash
        Canvas { ctx, sz in
            var i = 0
            while i < samples.count {
                if samples[i].charging == 1 {
                    var j = i
                    while j < samples.count && samples[j].charging == 1 { j += 1 }
                    let x1 = xFor(samples[i].t, in: sz)
                    let x2 = xFor(samples[max(j-1, i)].t, in: sz)
                    let rect = CGRect(x: x1, y: 0, width: max(2, x2 - x1), height: sz.height)
                    ctx.fill(Path(rect), with: .color(Tokens.good.opacity(0.10)))
                    i = j
                } else { i += 1 }
            }
        }
    }
}

// MARK: - Hourly heatmap

private struct HourlyHeatmap: View {
    let values: [Double]    // 24 entries 0...1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.10 + 0.85 * values[h]))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.30), lineWidth: values[h] > 0 ? 0.6 : 0)
                        )
                        .help("\(h):00 — \(Int((values[h]*100).rounded()))% on AC")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct NetworkScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveNetwork.shared

    var body: some View {
        ScreenScroll {
            header
            if live.needsRelaunch {
                relaunchBanner
            } else if live.ssid.lowercased().contains("redacted") || (!live.locationAuthorized && live.primary?.type == .wifi) {
                locationPromptBanner
            }
            HStack(alignment: .top, spacing: 16) {
                throughputPanel.frame(width: 380)
                identityPanel.frame(maxWidth: .infinity)
            }
            historyPanel
            HStack(alignment: .top, spacing: 16) {
                latencyPanel.frame(width: 380)
                topTalkersPanel.frame(maxWidth: .infinity)
            }
            interfacesPanel
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private var relaunchBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(Tokens.good)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.good.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart required")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Location access was granted, but macOS only refreshes the permission token at app launch. Quit & reopen to read the Wi-Fi name.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            Btn(label: "Quit & reopen", icon: "arrow.clockwise", style: .primary) {
                live.relaunchApp()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.good.opacity(0.30), lineWidth: 1))
    }

    private var locationPromptBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(Tokens.catApps)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.catApps.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Wi-Fi name is redacted")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("macOS hides the SSID from apps without Location access. Grant once to see it here.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            Btn(label: "Enable Location", icon: "checkmark", style: .primary) {
                live.requestLocationAuthorization()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.catApps.opacity(0.30), lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Network").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    PulsingDot(color: live.pingMs >= 0 && live.pingMs < 100 ? Tokens.good
                                       : live.pingMs >= 0 ? Tokens.warn : Tokens.danger,
                               size: 9)
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: "Network Settings", icon: "arrow.up.right", style: .secondary) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.network")!)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var headerSubtitle: String {
        var bits: [String] = []
        if let p = live.primary {
            bits.append("\(p.type.label) · \(p.displayName)")
            if !live.ssid.isEmpty { bits.append(live.ssid) }
            if p.linkSpeedMbps >= 1 {
                let s = p.linkSpeedMbps >= 1000 ? String(format: "%.1f Gbps", p.linkSpeedMbps / 1000)
                                                : String(format: "%.0f Mbps", p.linkSpeedMbps)
                bits.append(s)
            }
        } else {
            bits.append("Offline")
        }
        if live.pingMs >= 0 { bits.append("\(Int(live.pingMs.rounded())) ms") }
        return bits.joined(separator: " · ")
    }

    // MARK: - Throughput

    private var throughputPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Throughput").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if let p = live.primary {
                    Text(p.id).font(.system(size: 10.5, weight: .medium)).monospaced()
                        .foregroundStyle(Tokens.text4)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                speedPanel(label: "Down", value: live.rateInBps, total: live.sessionBytesIn,
                           sparkline: live.recentDown, color: Tokens.good,
                           icon: "arrow.down")
                speedPanel(label: "Up",   value: live.rateOutBps, total: live.sessionBytesOut,
                           sparkline: live.recentUp,   color: Tokens.catApps,
                           icon: "arrow.up")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func speedPanel(label: String, value: Double, total: UInt64,
                            sparkline: [Double], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .heavy)).foregroundStyle(color)
                Text(label).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(Tokens.text4)
            }
            Text(LiveNetwork.bps(value))
                .font(.system(size: 22, weight: .heavy)).monospacedDigit()
                .foregroundStyle(Tokens.text)
                .contentTransition(.numericText(value: value))
            ThroughputSparkline(values: sparkline, color: color)
                .frame(height: 30)
            Text("Session: \(LiveNetwork.bytes(total))")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
    }

    // MARK: - Identity

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Identity").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if !live.ssid.isEmpty {
                    SignalBars(strength: live.rssiPct, color: signalColor(live.rssiPct))
                        .frame(width: 22, height: 14)
                }
            }
            if !live.ssid.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.ssid).font(.system(size: 17, weight: .heavy))
                    HStack(spacing: 8) {
                        Text(live.security.isEmpty ? "—" : live.security)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Tokens.bgPanel2))
                        if live.channel > 0 {
                            Text("Ch \(live.channel)").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Tokens.bgPanel2))
                        }
                        if live.txRateMbps > 0 {
                            Text("\(Int(live.txRateMbps.rounded())) Mbps").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Tokens.bgPanel2))
                        }
                        if live.rssi != 0 {
                            Text("\(live.rssi) dBm · \(live.rssiLabel)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(signalColor(live.rssiPct).opacity(0.18)))
                                .foregroundStyle(signalColor(live.rssiPct))
                        }
                    }
                }
                Divider().foregroundStyle(Tokens.divider)
            }
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                kv("Local IPv4",  live.primary?.ipv4 ?? "—")
                kv("Local IPv6",  live.primary?.ipv6 ?? "—")
                kv("MAC",         live.primary?.mac ?? "—")
                kv("MTU",         live.primary.map { $0.mtu > 0 ? "\($0.mtu)" : "—" } ?? "—")
                kv("Gateway",     live.gateway.isEmpty ? "—" : live.gateway)
                kv("DNS",         live.dns.isEmpty ? "—" : live.dns.prefix(2).joined(separator: ", "))
                if !live.bssid.isEmpty { kv("BSSID", live.bssid) }
                if !live.pingHost.isEmpty { kv("Ping target", live.pingHost) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func signalColor(_ v: Double) -> Color {
        if v > 0.7 { return Tokens.good }
        if v > 0.45 { return Tokens.warn }
        return Tokens.danger
    }

    private func kv(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 13, weight: .heavy)).foregroundStyle(Tokens.text).lineLimit(1)
        }
    }

    // MARK: - History

    private var historyPanel: some View {
        let s = live.samplesInRange
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Throughput history").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                rangePicker
            }
            HStack(spacing: 12) {
                miniStat(label: "Now ↓",  value: LiveNetwork.bps(s.last?.downBps ?? 0))
                miniStat(label: "Now ↑",  value: LiveNetwork.bps(s.last?.upBps   ?? 0))
                miniStat(label: "Peak ↓", value: LiveNetwork.bps(s.map { $0.downBps }.max() ?? 0))
                miniStat(label: "Peak ↑", value: LiveNetwork.bps(s.map { $0.upBps   }.max() ?? 0))
                miniStat(label: "Samples", value: "\(s.count)")
                Spacer()
                Button("Clear") { live.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            ThroughputChart(samples: s, downColor: Tokens.good, upColor: Tokens.catApps)
                .frame(height: 140)
            HStack(spacing: 12) {
                seriesDot(color: Tokens.good, label: "Download")
                seriesDot(color: Tokens.catApps, label: "Upload")
                Spacer()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func seriesDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(Tokens.text4)
            Text(value).font(.system(size: 13, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.bgPanel2))
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(NetRange.allCases) { r in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { live.range = r }
                } label: {
                    Text(r.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(live.range == r ? Tokens.bgPanel : .clear)
                                .shadow(color: .black.opacity(live.range == r ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .foregroundStyle(live.range == r ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
    }

    // MARK: - Latency

    private var latencyPanel: some View {
        let s = live.samplesInRange.filter { $0.pingMs >= 0 }
        let avg = s.isEmpty ? 0 : s.reduce(0) { $0 + $1.pingMs } / Double(s.count)
        let p95 = percentile(0.95, s.map { $0.pingMs })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latency").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(live.pingHost.isEmpty ? "—" : "→ \(live.pingHost)")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(live.pingMs >= 0 ? "\(Int(live.pingMs.rounded()))" : "—")
                        .font(.system(size: 36, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(latencyColor(live.pingMs))
                        .contentTransition(.numericText(value: live.pingMs))
                    Text("ms now").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    miniRow("Average", "\(Int(avg.rounded())) ms")
                    miniRow("P95",     "\(Int(p95.rounded())) ms")
                    miniRow("Samples", "\(s.count)")
                }
            }
            LatencyChart(samples: live.samplesInRange).frame(height: 60)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func miniRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Tokens.text3)
            Text(value).font(.system(size: 12, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
        }
    }

    private func percentile(_ p: Double, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded()) - 1))
        return sorted[idx]
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 0     { return Tokens.text3 }
        if ms < 50    { return Tokens.good }
        if ms < 150   { return Tokens.warn }
        return Tokens.danger
    }

    // MARK: - Top talkers

    private var topTalkersPanel: some View {
        let rows = live.filteredTalkers
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Top talkers").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                searchField
            }
            if rows.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 24)
            } else {
                let visible = Array(rows.prefix(12))
                let maxBytes = (live.talkers.map { $0.bytesIn + $0.bytesOut }.max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(visible) { t in
                        TalkerRow(talker: t, maxBytes: maxBytes).equatable()
                        if t.id != visible.last?.id { Divider().foregroundStyle(Tokens.divider) }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.text4)
            TextField("Filter…", text: $live.talkerSearch)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
            if !live.talkerSearch.isEmpty {
                Button { live.talkerSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Tokens.text4)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
    }

    // MARK: - Interfaces

    private var interfacesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interfaces").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
            VStack(spacing: 0) {
                ForEach(live.interfaces) { iface in
                    InterfaceRow(iface: iface, isPrimary: iface.id == live.primary?.id).equatable()
                    if iface.id != live.interfaces.last?.id { Divider().foregroundStyle(Tokens.divider) }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }
}

// MARK: - Subviews

private struct ThroughputSparkline: View, Equatable {
    let values: [Double]
    let color: Color
    static func == (a: ThroughputSparkline, b: ThroughputSparkline) -> Bool {
        a.color == b.color && a.values.count == b.values.count && a.values.last == b.values.last
    }
    var body: some View {
        GeometryReader { geo in
            let mx = max(values.max() ?? 1, 1)
            ZStack {
                if values.count >= 2 {
                    path(in: geo.size, max: mx, closed: true)
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    path(in: geo.size, max: mx, closed: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
            .drawingGroup()
        }
    }
    private func path(in size: CGSize, max mx: Double, closed: Bool) -> Path {
        var p = Path()
        let n = max(values.count, 1)
        let stepX = size.width / CGFloat(max(n - 1, 1))
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat(v / mx))
            if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
        }
        if closed {
            p.addLine(to: .init(x: size.width, y: size.height))
            p.addLine(to: .init(x: 0, y: size.height))
            p.closeSubpath()
        }
        return p
    }
}

private struct ThroughputChart: View {
    let samples: [NetSample]
    let downColor: Color
    let upColor: Color
    var body: some View {
        GeometryReader { geo in
            let mx = max(samples.flatMap { [$0.downBps, $0.upBps] }.max() ?? 1, 1)
            ZStack {
                ForEach(0..<5) { i in
                    let y = geo.size.height * CGFloat(i) / 4
                    Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)) }
                        .stroke(Tokens.divider, lineWidth: 0.5)
                }
                if samples.count >= 2 {
                    line(values: samples.map(\.downBps), in: geo.size, max: mx, closed: true)
                        .fill(LinearGradient(colors: [downColor.opacity(0.30), downColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                    line(values: samples.map(\.downBps), in: geo.size, max: mx, closed: false)
                        .stroke(downColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    line(values: samples.map(\.upBps), in: geo.size, max: mx, closed: false)
                        .stroke(upColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                }
                VStack(alignment: .trailing) {
                    Text(LiveNetwork.bps(mx))
                        .font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                        .padding(.trailing, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            .drawingGroup()
        }
    }
    private func line(values: [Double], in size: CGSize, max mx: Double, closed: Bool) -> Path {
        var p = Path()
        let n = max(values.count, 1)
        let stepX = size.width / CGFloat(max(n - 1, 1))
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat(min(1, v / mx)))
            if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
        }
        if closed {
            p.addLine(to: .init(x: size.width, y: size.height))
            p.addLine(to: .init(x: 0, y: size.height))
            p.closeSubpath()
        }
        return p
    }
}

private struct LatencyChart: View {
    let samples: [NetSample]
    var body: some View {
        GeometryReader { geo in
            let pings = samples.map { max(0, $0.pingMs) }
            let mx = max(pings.max() ?? 100, 50)
            ZStack {
                Path { p in
                    p.move(to: .init(x: 0, y: geo.size.height * (1 - 50/mx)))
                    p.addLine(to: .init(x: geo.size.width, y: geo.size.height * (1 - 50/mx)))
                }.stroke(Tokens.warn.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                if samples.count >= 2 {
                    Self.buildPath(samples: samples, size: geo.size, max: mx)
                        .stroke(Tokens.purple, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
            .drawingGroup()
        }
    }

    private static func buildPath(samples: [NetSample], size: CGSize, max mx: Double) -> Path {
        var path = Path()
        let stepX = size.width / CGFloat(max(samples.count - 1, 1))
        var started = false
        for (i, s) in samples.enumerated() where s.pingMs >= 0 {
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat(s.pingMs / mx))
            if !started { path.move(to: .init(x: x, y: y)); started = true }
            else { path.addLine(to: .init(x: x, y: y)) }
        }
        return path
    }
}

private struct SignalBars: View {
    let strength: Double      // 0...1
    let color: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { i in
                let active = strength >= Double(i + 1) / 4.0
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(active ? color : Tokens.bgPanel2)
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}

private struct TalkerRow: View, Equatable {
    let talker: NetTalker
    let maxBytes: UInt64
    static func == (a: TalkerRow, b: TalkerRow) -> Bool {
        a.talker.id == b.talker.id
            && a.talker.bytesIn == b.talker.bytesIn
            && a.talker.bytesOut == b.talker.bytesOut
            && a.maxBytes == b.maxBytes
    }
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2).frame(width: 28, height: 28)
                LazyAppIcon(bundleURL: talker.bundlePath.map { URL(fileURLWithPath: $0) },
                            fallback: "globe",
                            fallbackColor: Tokens.text3)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(talker.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer()
                    HStack(spacing: 8) {
                        Label(LiveNetwork.bytes(talker.bytesIn), systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(Tokens.good)
                        Label(LiveNetwork.bytes(talker.bytesOut), systemImage: "arrow.up")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(Tokens.catApps)
                    }
                }
                GeometryReader { geo in
                    let total = Double(talker.bytesIn + talker.bytesOut)
                    let denom = Double(max(maxBytes, 1))
                    let inFrac = denom == 0 ? 0 : Double(talker.bytesIn)  / denom
                    let outFrac = denom == 0 ? 0 : Double(talker.bytesOut) / denom
                    HStack(spacing: 0) {
                        Capsule().fill(Tokens.good.opacity(0.85)).frame(width: geo.size.width * inFrac)
                        Capsule().fill(Tokens.catApps.opacity(0.85)).frame(width: geo.size.width * outFrac)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 4)
                    .opacity(total > 0 ? 1 : 0)
                }.frame(height: 4)
            }
            Text("PID \(talker.pid)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(Tokens.text4).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

private struct InterfaceRow: View, Equatable {
    let iface: NetIface
    let isPrimary: Bool
    static func == (a: InterfaceRow, b: InterfaceRow) -> Bool {
        a.isPrimary == b.isPrimary
            && a.iface.id == b.iface.id
            && a.iface.bytesIn == b.iface.bytesIn
            && a.iface.bytesOut == b.iface.bytesOut
            && a.iface.isUp == b.iface.isUp
            && a.iface.ipv4 == b.iface.ipv4
            && a.iface.ipv6 == b.iface.ipv6
    }
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(iface.isUp ? Tokens.good.opacity(0.18) : Tokens.bgPanel2).frame(width: 32, height: 32)
                Image(systemName: iface.type.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iface.isUp ? Tokens.good : Tokens.text3)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(iface.displayName).font(.system(size: 12.5, weight: .semibold))
                    Text(iface.id).font(.system(size: 10.5, weight: .medium)).monospaced().foregroundStyle(Tokens.text4)
                    if isPrimary {
                        Text("Primary").font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Tokens.catApps.opacity(0.18)))
                            .foregroundStyle(Tokens.catApps)
                    }
                    Text(iface.type.label).font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.bgPanel2))
                        .foregroundStyle(Tokens.text3)
                }
                HStack(spacing: 8) {
                    if let v = iface.ipv4 { Text(v).font(.system(size: 11)).monospaced().foregroundStyle(Tokens.text2) }
                    if let v = iface.ipv6 { Text(v).font(.system(size: 11)).monospaced().foregroundStyle(Tokens.text3).lineLimit(1).truncationMode(.middle) }
                    if let m = iface.mac  { Text(m).font(.system(size: 11)).monospaced().foregroundStyle(Tokens.text4) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Text("↓ \(LiveNetwork.bps(iface.rateInBps))").font(.system(size: 11, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.good)
                    Text("↑ \(LiveNetwork.bps(iface.rateOutBps))").font(.system(size: 11, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.catApps)
                }
                Text("\(LiveNetwork.bytes(iface.bytesIn)) in · \(LiveNetwork.bytes(iface.bytesOut)) out")
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.text4)
            }
        }
        .padding(.vertical, 9)
    }
}

struct AnalyticsScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveAnalytics.shared

    var body: some View {
        ScreenScroll {
            header
            summaryCard
            metricSelector
            overlayChartPanel
            recordsStrip
            deltasStrip
            heatmapsPanel
            histogramsPanel
            cleanupPanel
            sessionsPanel
            exportPanel
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Analytics").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.loading { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                rangePicker
                Btn(label: live.loading ? "Loading…" : "Refresh", icon: "arrow.clockwise", style: .secondary) {
                    live.refresh()
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var headerSubtitle: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        let cleaned = bcf.string(fromByteCount: live.totalCleanedBytes)
        let hours = String(format: "%.1f", live.totalActiveHours)
        return "Range: \(live.range.label) · \(cleaned) freed by BloatMac · \(hours) active hours"
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(AnalyticsRange.allCases) { r in
                Button { withAnimation(.easeOut(duration: 0.15)) { live.range = r } } label: {
                    Text(r.label)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(live.range == r ? Tokens.bgPanel : .clear)
                                .shadow(color: .black.opacity(live.range == r ? 0.06 : 0), radius: 1, y: 1)
                        )
                        .foregroundStyle(live.range == r ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.purple)
                Text("Long-term summary").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if !live.summaryAuthor.isEmpty {
                    Text(live.summaryAuthor.uppercased())
                        .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Tokens.purple.opacity(0.18)))
                        .foregroundStyle(Tokens.purple)
                }
            }
            Text(live.summary.isEmpty ? "Loading…" : live.summary)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.text)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(live.summary)
                .transition(.opacity)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Metric selector + overlay chart

    private var metricSelector: some View {
        HStack(spacing: 16) {
            metricMenu(label: "Primary", binding: $live.primaryMetric)
            metricMenu(label: "Secondary", binding: $live.secondaryMetric)
            Spacer()
        }
    }

    private func metricMenu(label: String, binding: Binding<AnalyticsMetric>) -> some View {
        Menu {
            ForEach(AnalyticsMetric.allCases) { m in
                Button { binding.wrappedValue = m } label: {
                    HStack { Text(m.rawValue); if binding.wrappedValue == m { Image(systemName: "checkmark") } }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Circle().fill(binding.wrappedValue.color).frame(width: 7, height: 7)
                Text(binding.wrappedValue.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var overlayChartPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Overlay").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                if let p = live.primarySeries {
                    chartLegend(metric: p.metric, peak: p.peak)
                }
                if let s = live.secondarySeries {
                    chartLegend(metric: s.metric, peak: s.peak)
                }
            }
            OverlayChart(primary: live.primarySeries, secondary: live.secondarySeries)
                .frame(height: 220)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func chartLegend(metric: AnalyticsMetric, peak: Double) -> some View {
        let valueText: String
        switch metric {
        case .memoryUsed, .diskUsed: valueText = "\(Int((peak * 100).rounded()))% peak"
        case .downBps, .upBps:       valueText = "\(LiveNetwork.bps(peak)) peak"
        case .ping:                  valueText = "\(Int(peak.rounded())) ms peak"
        }
        return HStack(spacing: 6) {
            Circle().fill(metric.color).frame(width: 6, height: 6)
            Text(metric.rawValue).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
            Text("· \(valueText)").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Tokens.text4)
        }
    }

    // MARK: - Records

    private var recordsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Records").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
            }
            if live.records.isEmpty {
                Text("No records yet for this range.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3).padding(.vertical, 12)
            } else {
                let cols = [GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    ForEach(live.records) { r in
                        Button { state.goto(r.target) } label: { recordCard(r) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func recordCard(_ r: AnalyticsRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: r.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(r.color)
                Text(r.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                    .lineLimit(1)
            }
            Text(r.value).font(.system(size: 18, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
            Text(r.detail).font(.system(size: 10)).foregroundStyle(Tokens.text4).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(r.color.opacity(0.30), lineWidth: 1))
    }

    // MARK: - WoW deltas

    private var deltasStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Window comparison").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("vs prior \(live.range.label.lowercased())")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(Tokens.text4)
            }
            if live.deltas.isEmpty {
                Text("Need more samples to compare windows.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3).padding(.vertical, 12)
            } else {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                    ForEach(live.deltas) { d in
                        Button { state.goto(d.target) } label: { deltaCard(d) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    private func deltaCard(_ d: WoWDelta) -> some View {
        let arrow = d.positive ? "arrow.up.right" : "arrow.down.right"
        let badIfPositive = d.deltaPositiveIsBad
        let arrowColor: Color = {
            if d.deltaText == "—" || d.deltaText.contains("in this window") { return Tokens.text3 }
            return d.positive == badIfPositive ? Tokens.warn : Tokens.good
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: d.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(d.color)
                Text(d.label.uppercased())
                    .font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
            }
            Text(d.value).font(.system(size: 18, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text)
            HStack(spacing: 4) {
                Image(systemName: arrow).font(.system(size: 9, weight: .heavy)).foregroundStyle(arrowColor)
                Text(d.deltaText).font(.system(size: 10, weight: .semibold)).foregroundStyle(arrowColor)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
    }

    // MARK: - Heatmaps

    private var heatmapsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hour × Day-of-week").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("Mon-Sun · 24h grid").font(.system(size: 10, weight: .heavy)).foregroundStyle(Tokens.text4)
            }
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(live.heatmaps.indices, id: \.self) { i in
                    HeatmapTile(map: live.heatmaps[i])
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Histograms

    private var histogramsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Distributions").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
            }
            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(live.histograms.indices, id: \.self) { i in
                    HistogramTile(hist: live.histograms[i])
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Cleanup history

    private var cleanupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanups").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: live.totalCleanedBytes, countStyle: .file))
                    .font(.system(size: 11, weight: .heavy)).monospacedDigit().foregroundStyle(Tokens.text2)
            }
            if live.cleanupHistory.isEmpty {
                Text("No cleanups recorded in this range yet — items removed via BloatMac will appear here.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    .padding(.vertical, 16)
            } else {
                CleanupChart(days: live.cleanupHistory)
                    .frame(height: 130)
                HStack(spacing: 12) {
                    ForEach([CleanupModule.duplicates, .largeFiles, .unused, .downloads, .caches], id: \.self) { m in
                        HStack(spacing: 5) {
                            Circle().fill(moduleColor(m)).frame(width: 6, height: 6)
                            Text(m.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    static func moduleColor(_ m: CleanupModule) -> Color {
        switch m {
        case .duplicates: return Tokens.danger
        case .largeFiles: return Tokens.warn
        case .unused:     return Tokens.indigo
        case .downloads:  return Tokens.catApps
        case .caches:     return Tokens.good
        }
    }

    private func moduleColor(_ m: CleanupModule) -> Color { Self.moduleColor(m) }

    // MARK: - Sessions

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active sessions").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                let total = live.sessions.reduce(0) { $0 + $1.sessionCount }
                Text("\(total) sessions · \(String(format: "%.1f", live.totalActiveHours)) hr active")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tokens.text4)
            }
            if live.sessions.isEmpty {
                Text("No session data yet.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3).padding(.vertical, 12)
            } else {
                SessionChart(days: live.sessions).frame(height: 90)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }

    // MARK: - Export

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Export & data location").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
            }
            HStack(spacing: 8) {
                Btn(label: "Export network", icon: "square.and.arrow.up", style: .secondary) { live.exportCSV(table: .network) }
                Btn(label: "Export battery", icon: "square.and.arrow.up", style: .secondary) { live.exportCSV(table: .battery) }
                Btn(label: "Export storage", icon: "square.and.arrow.up", style: .secondary) { live.exportCSV(table: .storage) }
                Btn(label: "Export cleanups", icon: "square.and.arrow.up", style: .secondary) { live.exportCSV(table: .cleanups) }
                Btn(label: "Reveal data folder", icon: "folder", style: .secondary) { live.revealDataFolder() }
            }
            Text("All time-series data is stored locally in ~/Library/Application Support/BloatMac and never leaves your machine.")
                .font(.system(size: 10.5)).foregroundStyle(Tokens.text4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
    }
}

// MARK: - Charts (Analytics)

private struct OverlayChart: View {
    let primary: MetricSeries?
    let secondary: MetricSeries?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<5) { i in
                    let y = geo.size.height * CGFloat(i) / 4
                    Path { p in p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)) }
                        .stroke(Tokens.divider, lineWidth: 0.5)
                }
                if let p = primary {
                    chart(series: p, in: geo.size, fill: true, dashed: false)
                }
                if let s = secondary, primary?.metric != s.metric {
                    chart(series: s, in: geo.size, fill: false, dashed: true)
                }
            }
            .drawingGroup()
        }
    }

    private func chart(series: MetricSeries, in size: CGSize, fill: Bool, dashed: Bool) -> some View {
        let v = series.normalizedValues
        let stepX = size.width / CGFloat(max(v.count - 1, 1))
        return ZStack {
            if fill {
                Path { p in
                    p.move(to: .init(x: 0, y: size.height))
                    for (i, val) in v.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = size.height * (1 - CGFloat(val))
                        p.addLine(to: .init(x: x, y: y))
                    }
                    p.addLine(to: .init(x: size.width, y: size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [series.metric.color.opacity(0.30), series.metric.color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            }
            Path { p in
                for (i, val) in v.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = size.height * (1 - CGFloat(val))
                    if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
                }
            }
            .stroke(series.metric.color,
                    style: StrokeStyle(lineWidth: dashed ? 1.4 : 1.7,
                                       lineCap: .round, lineJoin: .round,
                                       dash: dashed ? [5, 4] : []))
        }
    }
}

private struct HeatmapTile: View {
    let map: Heatmap
    private let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(map.label.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text(map.peakLabel).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(map.color)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(days.indices, id: \.self) { i in
                        Text(days[i]).font(.system(size: 8, weight: .heavy)).foregroundStyle(Tokens.text4)
                            .frame(width: 24, height: 12, alignment: .trailing)
                    }
                }
                GeometryReader { geo in
                    let cellW = geo.size.width / 24
                    let cellH = (geo.size.height - 12) / 7
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<7, id: \.self) { d in
                            ForEach(0..<24, id: \.self) { h in
                                let v = map.peakValue > 0 ? map.cells[d][h] / map.peakValue : 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(map.color.opacity(0.10 + 0.85 * v))
                                    .frame(width: cellW - 1.5, height: cellH - 1.5)
                                    .position(x: CGFloat(h) * cellW + cellW/2,
                                              y: CGFloat(d) * cellH + cellH/2)
                                    .help("\(days[d]) \(h):00 — \(String(format: "%.1f", map.cells[d][h]))")
                            }
                        }
                        // Hour ticks
                        HStack(spacing: 0) {
                            ForEach(0..<6) { i in
                                Text("\(i*4)")
                                    .font(.system(size: 8, weight: .heavy)).foregroundStyle(Tokens.text4)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height - 6)
                    }
                }
                .frame(height: 130)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
    }
}

private struct HistogramTile: View {
    let hist: Histogram
    var body: some View {
        let mx = max(hist.counts.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hist.label.uppercased())
                    .font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(Tokens.text4)
                Spacer()
                Text("\(hist.counts.reduce(0, +)) samples").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Tokens.text4)
            }
            GeometryReader { geo in
                let n = max(hist.counts.count, 1)
                let barW = (geo.size.width - CGFloat(n - 1) * 3) / CGFloat(n)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(hist.counts.indices, id: \.self) { i in
                        let v = Double(hist.counts[i]) / Double(mx)
                        VStack(spacing: 2) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [hist.color.opacity(0.55), hist.color],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: barW, height: max(2, geo.size.height * 0.85 * CGFloat(v)))
                        }
                    }
                }
            }
            .frame(height: 70)
            HStack(spacing: 0) {
                ForEach(hist.bins.indices, id: \.self) { i in
                    Text(hist.bins[i])
                        .font(.system(size: 8, weight: .heavy)).foregroundStyle(Tokens.text4)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.bgPanel2))
    }
}

private struct CleanupChart: View {
    let days: [DayCleanup]
    private let modulesOrder: [CleanupModule] = [.duplicates, .largeFiles, .unused, .downloads, .caches]
    var body: some View {
        let maxBytes = max(days.map { $0.total }.max() ?? 1, 1)
        return GeometryReader { geo in
            let n = max(days.count, 1)
            let barW = (geo.size.width - CGFloat(n - 1) * 3) / CGFloat(n)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    VStack(spacing: 0) {
                        ForEach(modulesOrder, id: \.self) { m in
                            let bytes = day.perModule[m] ?? 0
                            let height = geo.size.height * 0.8 * CGFloat(Double(bytes) / Double(maxBytes))
                            Rectangle()
                                .fill(AnalyticsScreen.moduleColor(m))
                                .frame(width: barW, height: height)
                        }
                    }
                    .frame(width: barW, alignment: .bottom)
                    .help("\(day.day.formatted(.dateTime.month().day())) · \(ByteCountFormatter.string(fromByteCount: day.total, countStyle: .file))")
                }
            }
        }
    }
}

private struct SessionChart: View {
    let days: [SessionDay]
    var body: some View {
        let maxMins = max(days.map { $0.activeMinutes }.max() ?? 1, 1)
        return GeometryReader { geo in
            let n = max(days.count, 1)
            let barW = (geo.size.width - CGFloat(n - 1) * 4) / CGFloat(n)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Tokens.indigo.opacity(0.55), Tokens.indigo],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: barW, height: max(3, geo.size.height * 0.7 * CGFloat(Double(day.activeMinutes) / Double(maxMins))))
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated)).prefix(2))
                            .font(.system(size: 8, weight: .heavy)).foregroundStyle(Tokens.text4)
                    }
                    .help("\(day.day.formatted(.dateTime.weekday().month().day())) · \(day.sessionCount) sessions, \(day.activeMinutes) min")
                }
            }
        }
    }
}

// MARK: - Settings (real, persisted)

struct SettingsScreen: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScreenScroll {
            settingsCard(title: "Appearance") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Theme").font(.system(size: 13, weight: .medium)).frame(width: 160, alignment: .leading)
                        Picker("", selection: $state.themeRaw) {
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }.pickerStyle(.segmented).frame(width: 220)
                    }
                    HStack {
                        Text("Accent").font(.system(size: 13, weight: .medium)).frame(width: 160, alignment: .leading)
                        HStack(spacing: 8) {
                            ForEach(AccentKey.allCases) { k in
                                Button { state.accent = k } label: {
                                    Circle().fill(k.value)
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(.white, lineWidth: state.accent == k ? 2 : 0))
                                        .overlay(Circle().stroke(Tokens.border, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            settingsCard(title: "Modes") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Menu bar widget").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        AppSwitch(on: $state.menubarWidgetEnabled)
                    }
                    HStack {
                        Text("Replay first scan").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        Btn(label: "Replay", style: .secondary) { state.replayOnboarding() }
                    }
                }
            }
            settingsCard(title: "About") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BloatMac").font(.system(size: 14, weight: .bold))
                    Text("v 2.4.1 — design preview").font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsCard<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .bold))
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metallic(radius: Tokens.Radius.lg)
    }
}
