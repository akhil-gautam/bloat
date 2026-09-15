import SwiftUI

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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
                                .fill(live.range == r ? Tokens.bgSelected : .clear)
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
                            .accessibilityLabel("Reveal \(proc.name) in Finder")
                    }
                    Button(action: onKill) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.danger.opacity(hover ? 1 : 0.85)))
                    }.buttonStyle(.plain).help("Quit process")
                        .accessibilityLabel("Quit \(proc.name), process \(proc.id)")
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
            ActionError(message: live.lastError)
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
        .glassPanel(radius: Tokens.Radius.md)
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
        .glassPanel()
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

struct LazyAppIcon: View {
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
                .glassPanel(radius: Tokens.Radius.md)
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
