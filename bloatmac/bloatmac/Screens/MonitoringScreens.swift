import SwiftUI

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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
    }

    // MARK: - Top consumers

    private var topConsumersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top CPU users").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
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
        .glassPanel()
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
        .glassPanel()
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
        .glassChip(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous),
                   border: Tokens.good.opacity(0.30))
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
        .glassChip(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous),
                   border: Tokens.catApps.opacity(0.30))
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
        .glassPanel()
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
                Text("Top talkers · process totals").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Tokens.text4)
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
        .glassPanel()
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
        .glassPanel()
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
