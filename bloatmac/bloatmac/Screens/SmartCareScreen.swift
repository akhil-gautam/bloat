import SwiftUI

struct SmartCareScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var care = LiveSmartCare.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if care.running { progressPanel }
                if let r = care.result, !care.running { resultPanel(r) }
                if care.result == nil && !care.running { idlePanel }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.bgWindow)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Smart Care").font(.system(size: 26, weight: .bold))
                Text("One scan covers storage, caches, duplicates, startup items, and memory. Apply individual recommendations or trigger a full clean.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: 540, alignment: .leading)
                HStack(spacing: 10) {
                    Btn(label: care.running ? "Scanning…" : "Run Smart Care",
                        icon: care.running ? "hourglass" : "sparkles",
                        style: .primary) {
                        if !care.running {
                            Task { await care.run() }
                        }
                    }
                    if care.running {
                        Btn(label: "Cancel", icon: "xmark", style: .ghost) {
                            care.cancel()
                        }
                    } else if care.result != nil {
                        Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) {
                            Task { await care.run() }
                        }
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Progress

    private var progressPanel: some View {
        VStack(spacing: 22) {
            scanHero
            scanStepList
            ProgressView(value: care.progress).progressViewStyle(.linear).tint(state.accent.value)
        }
        .padding(.horizontal, 24).padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                Tokens.bgPanel
                // Faint accent gradient sweep behind the hero so the panel
                // doesn't feel like a flat box during the scan.
                LinearGradient(
                    colors: [state.accent.value.opacity(0.08), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Pulsing accent ring + step-icon centerpiece + verb-form copy + percent.
    /// Drives the visual heartbeat of the scan.
    private var scanHero: some View {
        VStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = (sin(t * 1.8) + 1) / 2          // 0…1, ~0.5 Hz
                let spin  = (t.truncatingRemainder(dividingBy: 4)) / 4 * 360
                ZStack {
                    // Outer breathing ring — fades + scales.
                    Circle()
                        .stroke(state.accent.value.opacity(0.20), lineWidth: 2)
                        .frame(width: 160, height: 160)
                        .scaleEffect(1.0 + pulse * 0.10)
                        .opacity(1.0 - pulse * 0.65)
                    // Mid ring — solid.
                    Circle()
                        .stroke(state.accent.value.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 130, height: 130)
                    // Inner progress arc — driven by overall scan progress.
                    Circle()
                        .trim(from: 0, to: max(0.04, CGFloat(care.progress)))
                        .stroke(state.accent.value, style: .init(lineWidth: 4, lineCap: .round))
                        .frame(width: 110, height: 110)
                        .rotationEffect(.degrees(-90))
                    // Subtle tick marks rotating around at constant speed —
                    // pure ornament, signals "active".
                    Circle()
                        .trim(from: 0, to: 0.05)
                        .stroke(state.accent.value.opacity(0.45), lineWidth: 2)
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(spin))
                    // Step icon at the center — swaps as the scan progresses.
                    Image(systemName: care.step.icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(state.accent.value)
                        .symbolEffect(.pulse, options: .repeating, value: care.step)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(height: 170)

            VStack(spacing: 4) {
                Text(care.step.runningCopy)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .contentTransition(.opacity)
                Text("\(Int(care.progress * 100))% complete")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .monospacedDigit()
            }
        }
    }

    /// Five-row pipeline list. Each row reads its underlying Live*.shared
    /// store directly to surface live counts as the scan advances.
    private var scanStepList: some View {
        VStack(spacing: 0) {
            ForEach(LiveSmartCare.Step.pipeline, id: \.self) { step in
                stepRow(step)
                if step != LiveSmartCare.Step.pipeline.last {
                    Divider().padding(.horizontal, 14).opacity(0.4)
                }
            }
        }
        .background(Tokens.bgPanel2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stepRow(_ step: LiveSmartCare.Step) -> some View {
        let (status, detail) = stepState(step)
        HStack(spacing: 12) {
            stepStatusIndicator(status)
                .frame(width: 22, height: 22)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(status == .pending ? Tokens.text3 : Tokens.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.text3)
                    .contentTransition(.numericText())
            }
            Spacer()
            if status == .running {
                Image(systemName: step.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.accent.value)
                    .symbolEffect(.pulse, options: .repeating, value: care.step)
                    .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 10)
        .opacity(status == .pending ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    /// Renders pending/running/done as a circle / pulsing dot / checkmark.
    @ViewBuilder
    private func stepStatusIndicator(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .stroke(Tokens.text4, lineWidth: 1.4)
                .frame(width: 16, height: 16)
        case .running:
            ZStack {
                Circle().fill(state.accent.value.opacity(0.20)).frame(width: 22, height: 22)
                Circle().fill(state.accent.value).frame(width: 10, height: 10)
                    .symbolEffect(.pulse, options: .repeating, value: care.step)
            }
        case .done:
            ZStack {
                Circle().fill(Tokens.good.opacity(0.18)).frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Tokens.good)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    private enum StepStatus: Equatable { case pending, running, done }

    /// Compute (status, detailText) for one pipeline step. While the step
    /// is running we surface the underlying scanner's phase string. After
    /// it finishes we read the singleton's collected counts/sizes and
    /// format them as a one-line summary.
    private func stepState(_ step: LiveSmartCare.Step) -> (StepStatus, String) {
        let pipeline = LiveSmartCare.Step.pipeline
        guard let currentIdx = pipeline.firstIndex(of: care.step),
              let stepIdx    = pipeline.firstIndex(of: step) else {
            // care.step is .idle or .done — everything is pending or done.
            switch care.step {
            case .done: return (.done, completedDetail(step))
            default:    return (.pending, "")
            }
        }
        if stepIdx <  currentIdx { return (.done,    completedDetail(step)) }
        if stepIdx == currentIdx { return (.running, runningDetail(step)) }
        return (.pending, "Pending")
    }

    private func runningDetail(_ step: LiveSmartCare.Step) -> String {
        switch step {
        case .storage:
            return LiveStorage.shared.calculating ? "Indexing volumes…" : "Done"
        case .caches:
            let dc = LiveDownloadsCache.shared
            if dc.scanning {
                let phase = dc.phase.isEmpty ? "Walking…" : dc.phase
                return "\(phase) · \(dc.downloads.count) downloads · \(dc.caches.count) caches"
            }
            return "Done"
        case .duplicates:
            let d = LiveDuplicates.shared
            if d.scanning {
                let phase = d.phase.isEmpty ? "Hashing…" : d.phase
                return "\(phase) · \(d.exact.count + d.similar.count) groups so far"
            }
            return "Done"
        case .startup:
            let s = LiveStartup.shared
            if s.scanning { return s.phase.isEmpty ? "Reading launch agents…" : s.phase }
            return "Done"
        case .memory:
            return "Reading vm_statistics64…"
        default: return ""
        }
    }

    private func completedDetail(_ step: LiveSmartCare.Step) -> String {
        switch step {
        case .storage:
            let s = LiveStorage.shared
            let pct = s.totalGB > 0 ? Int((s.usedGB / s.totalGB * 100).rounded()) : 0
            return "\(pct)% used · \(Int(s.freeGB.rounded())) GB free"
        case .caches:
            let dc = LiveDownloadsCache.shared
            let bytes = dc.downloads.reduce(0) { $0 + $1.sizeBytes }
                      + dc.caches.reduce(0) { $0 + $1.sizeBytes }
            return "\(formatGB(bytes)) across \(dc.downloads.count + dc.caches.count) items"
        case .duplicates:
            let d = LiveDuplicates.shared
            let bytes = (d.exact + d.similar).reduce(Int64(0)) { acc, g in
                acc + g.items.reduce(Int64(0)) { $0 + ($1.keep ? 0 : $1.sizeBytes) }
            }
            return "\(formatGB(bytes)) reclaimable · \(d.exact.count + d.similar.count) groups"
        case .startup:
            let items = LiveStartup.shared.items
            let flagged = items.filter { $0.risk == .flagged }.count
            return "\(items.count) items · \(flagged) flagged"
        case .memory:
            switch LiveMemory.shared.pressure {
            case .normal:   return "Pressure: normal"
            case .warning:  return "Pressure: warning"
            case .critical: return "Pressure: critical"
            }
        default: return ""
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func resultPanel(_ r: LiveSmartCare.Result) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Big number — total reclaimable
            VStack(alignment: .leading, spacing: 6) {
                Text("Reclaimable")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                Text(formatGB(r.cleanableBytes))
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(state.accent.value)
                Text(r.runAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            .padding(20)
            .frame(width: 240, alignment: .leading)
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Quick stats
            VStack(spacing: 0) {
                statRow("Caches",     formatGB(r.cacheBytes),     icon: "tray.full")
                Divider()
                statRow("Downloads",  formatGB(r.downloadBytes),  icon: "arrow.down.circle")
                Divider()
                statRow("Duplicates", formatGB(r.duplicateBytes), icon: "doc.on.doc")
                Divider()
                statRow("Startup risk", "\(r.flaggedStartup) flagged", icon: "powerplug")
                Divider()
                statRow("Memory", pressureText(r.memoryPressure), icon: "memorychip")
                Divider()
                statRow("Storage", "\(Int((r.storagePct * 100).rounded()))% used", icon: "internaldrive")
            }
            .frame(maxWidth: .infinity)
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if !r.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recommendations")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tokens.text)
                ForEach(r.recommendations) { rec in
                    recommendationRow(rec)
                }
            }
            .padding(.top, 6)
        } else {
            Text("Nothing actionable right now — your Mac is in good shape.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text3)
                .padding(.top, 6)
        }
    }

    private func statRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text3)
                .frame(width: 18)
            Text(label).font(.system(size: 12)).foregroundStyle(Tokens.text2)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func recommendationRow(_ r: LiveSmartCare.Recommendation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: r.module))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.accent.value)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Tokens.bgPanel2))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.text)
                Text(r.detail).font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            Btn(label: r.actionLabel, icon: "arrow.right", style: .ghost) {
                state.goto(screenFor(r.module))
            }
        }
        .padding(12)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Idle

    private var idlePanel: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(state.accent.value)
            VStack(alignment: .leading, spacing: 4) {
                Text("Run a scan to see what's reclaimable").font(.system(size: 14, weight: .semibold))
                Text("Takes about a minute on most Macs.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
            }
            Spacer()
        }
        .padding(18)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Format helpers

    private func formatGB(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    private func icon(for m: LiveSmartCare.RecModule) -> String {
        switch m {
        case .caches:     return "tray.full"
        case .downloads:  return "arrow.down.circle"
        case .duplicates: return "doc.on.doc"
        case .startup:    return "powerplug"
        case .memory:     return "memorychip"
        case .storage:    return "internaldrive"
        }
    }

    private func screenFor(_ m: LiveSmartCare.RecModule) -> Screen {
        switch m {
        case .caches, .downloads: return .downloads
        case .duplicates:         return .duplicates
        case .startup:            return .startup
        case .memory:             return .memory
        case .storage:            return .storage
        }
    }
}
