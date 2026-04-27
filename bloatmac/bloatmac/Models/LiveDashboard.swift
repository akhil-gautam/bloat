import Foundation
import SwiftUI
import Combine
import AppKit
import Accelerate
import NaturalLanguage
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

private let DASH_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct StorageSample: Codable {
    let t: TimeInterval
    let usedGB: Double
    let totalGB: Double
}

struct TrendSeries: Identifiable {
    let id = UUID()
    let label: String
    let unit: String
    let values: [Double]      // 0…1 for chart
    let valueText: String
    let detail: String
    let color: Color
    let target: Screen
}

enum HealthGrade: String { case excellent, good, fair, warn, critical
    var label: String {
        switch self { case .excellent: "Excellent"; case .good: "Good"; case .fair: "Fair"; case .warn: "Needs attention"; case .critical: "Critical" }
    }
    var color: Color {
        switch self {
        case .excellent: return Tokens.good
        case .good:      return Tokens.good
        case .fair:      return Tokens.catApps
        case .warn:      return Tokens.warn
        case .critical:  return Tokens.danger
        }
    }
}

struct HealthScore {
    var storage: Double = 1
    var memory: Double = 1
    var battery: Double = 1
    var network: Double = 1
    var hygiene: Double = 1
    var hasBattery: Bool = false

    /// Weighted overall, batteryless desktops get its share redistributed.
    var overall: Double {
        let weights: [String: Double] = hasBattery
            ? ["s": 0.22, "m": 0.22, "b": 0.18, "n": 0.18, "h": 0.20]
            : ["s": 0.28, "m": 0.28, "b": 0.0,  "n": 0.22, "h": 0.22]
        let raw = storage * weights["s"]! + memory * weights["m"]!
                + battery * weights["b"]! + network * weights["n"]!
                + hygiene * weights["h"]!
        return max(0, min(1, raw))
    }

    var asInt: Int { Int((overall * 100).rounded()) }

    var grade: HealthGrade {
        switch asInt {
        case 90...100: .excellent
        case 75...89:  .good
        case 60...74:  .fair
        case 40...59:  .warn
        default:       .critical
        }
    }

    static let empty = HealthScore()
}

struct DashRecommendation: Identifiable {
    let id = UUID()
    enum Tone { case good, info, warn, danger
        var color: Color {
            switch self { case .good: Tokens.good; case .info: Tokens.catApps; case .warn: Tokens.warn; case .danger: Tokens.danger }
        }
    }
    let tone: Tone
    let icon: String
    let title: String
    let body: String
    let actionLabel: String
    let target: Screen
    let priority: Int           // higher = more urgent
}

struct DashForecast: Identifiable {
    let id = UUID()
    let icon: String
    let label: String           // "Disk full"
    let when: String            // "in 12 days"  /  "in 3 hr 24 min"
    let detail: String          // "+1.4 GB/day at current rate"
    let confidence: Double      // 0…1
    let color: Color
    let target: Screen
}

struct DashTicker: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    let detail: String
    let color: Color
    let target: Screen
}

enum ActivityKind: String { case charge, drain, scan, memorySpike, networkSpike
    var icon: String {
        switch self {
        case .charge:       "bolt.fill"
        case .drain:        "battery.25"
        case .scan:         "magnifyingglass.circle.fill"
        case .memorySpike:  "memorychip.fill"
        case .networkSpike: "antenna.radiowaves.left.and.right"
        }
    }
    var color: Color {
        switch self {
        case .charge:       Tokens.good
        case .drain:        Tokens.warn
        case .scan:         Tokens.catApps
        case .memorySpike:  Tokens.purple
        case .networkSpike: Tokens.indigo
        }
    }
}

struct ActivityEvent: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let kind: ActivityKind
    let detail: String
}

@MainActor
final class LiveDashboard: ObservableObject {
    static let shared = LiveDashboard()

    @Published private(set) var score: HealthScore = .empty
    @Published private(set) var briefing: String = ""
    @Published private(set) var briefingAuthor: String = ""    // "Apple Intelligence" / "Heuristic"
    @Published private(set) var recommendations: [DashRecommendation] = []
    @Published private(set) var forecasts: [DashForecast] = []
    @Published private(set) var tickers: [DashTicker] = []
    @Published private(set) var timeline: [ActivityEvent] = []
    @Published private(set) var lastRefresh: Date = .distantPast
    @Published private(set) var refreshing: Bool = false
    @Published private(set) var trends: [TrendSeries] = []

    private var timer: Timer? = nil
    private var storageSampleTick: Int = 0
    private var db: OpaquePointer? = nil
    private var storageHistory: [StorageSample] = []

    nonisolated private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dashboard.sqlite")
    }()

    private init() { openDB(); loadStorageHistory() }

    // MARK: - Lifecycle

    func start() {
        // Make sure the live data sources we depend on are running while the
        // user is looking at the dashboard.
        LiveStorage.shared.refresh()
        LiveMemory.shared.start()
        LiveBattery.shared.start()
        LiveNetwork.shared.start()
        LiveStartup.shared.startIfNeeded()

        guard timer == nil else { return }
        recompute()
        let t = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() { recompute() }

    func runQuickScan() {
        LiveStorage.shared.refresh()
        LiveLargeFiles.shared.scan()
        LiveDuplicates.shared.scan()
        LiveUnused.shared.scan()
        LiveDownloadsCache.shared.scan()
        LiveStartup.shared.rescan()
    }

    // MARK: - Composition

    private func recompute() {
        refreshing = true
        // Sample storage roughly every 60s while the dashboard is open.
        storageSampleTick += 1
        if storageSampleTick == 1 || storageSampleTick % 12 == 0 { recordStorageSample() }

        score = computeScore()
        tickers = computeTickers()
        recommendations = computeRecommendations()
        forecasts = computeForecasts()
        timeline = computeTimeline()
        trends = computeTrends()
        // Always show the deterministic briefing immediately so the UI never blanks.
        briefing = composeBriefing()
        briefingAuthor = "Heuristic"
        lastRefresh = Date()
        refreshing = false
        // Then upgrade with Apple Intelligence on-device LLM if available.
        upgradeBriefingWithAppleIntelligence()
    }

    private func upgradeBriefingWithAppleIntelligence() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Don't try if Apple Intelligence isn't available on this machine.
            guard SystemLanguageModel.default.isAvailable else { return }
            let facts = factSheetForLLM()
            Task { @MainActor in
                do {
                    let session = LanguageModelSession(instructions: """
                        You are the assistant inside a macOS system-utility app called BloatMac.
                        Write a 2-3 sentence dashboard briefing for the user, in plain English.
                        Be concrete and reference the strongest signals only. Avoid filler. \
                        Don't invent numbers — only use the facts provided. No bullet points, \
                        no markdown, no headings. Use a friendly but matter-of-fact tone.
                    """)
                    let response = try await session.respond(to: facts)
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        withAnimation(.easeOut(duration: 0.35)) {
                            self.briefing = text
                            self.briefingAuthor = "Apple Intelligence"
                        }
                    }
                } catch {
                    // Keep the heuristic briefing — silent failure is fine.
                }
            }
        }
        #endif
    }

    /// Produce a compact, structured fact sheet for the LLM. No PII.
    private func factSheetForLLM() -> String {
        let s = score
        let mem = LiveMemory.shared
        let bat = LiveBattery.shared
        let net = LiveNetwork.shared
        let storage = LiveStorage.shared
        let dups = LiveDuplicates.shared
        let st = LiveStartup.shared
        let lf = LiveLargeFiles.shared
        let un = LiveUnused.shared

        let usedPct = storage.totalGB > 0 ? Int((storage.usedGB / storage.totalGB * 100).rounded()) : 0
        var lines: [String] = []
        lines.append("Health score: \(s.asInt)/100 (grade: \(s.grade.label))")
        lines.append("Storage: \(usedPct)% used of \(Int(storage.totalGB.rounded())) GB total, \(Int(storage.freeGB.rounded())) GB free")
        lines.append("Memory pressure: \(mem.pressure.label.lowercased()), used \(Int((mem.usedFraction*100).rounded()))%")
        if bat.hasBattery {
            lines.append("Battery: \(Int((bat.percent*100).rounded()))%, state \(bat.state.label.lowercased()), health \(Int((bat.healthFraction*100).rounded()))%, \(bat.cycleCount) cycles")
            if bat.state == .discharging && bat.predictedDrainPctPerHour > 0 {
                lines.append(String(format: "Battery drain rate: %.1f%% per hour", bat.predictedDrainPctPerHour))
            }
        }
        if let p = net.primary {
            lines.append("Network: \(p.type.label) on \(p.id), ping \(net.pingMs >= 0 ? "\(Int(net.pingMs.rounded())) ms" : "unknown")")
        }
        lines.append("Duplicates: \(dups.totalGroups) groups, \(dups.totalRecoverableText) recoverable")
        lines.append("Large files: \(lf.items.count) (\(lf.totalSizeText))")
        lines.append("Unused & old: \(un.totalCount) items (\(un.totalText))")
        lines.append("Startup items: \(st.items.count) total, \(st.unknownCount) unverified, \(st.disabledCount) disabled")
        lines.append("Top recommendation (if any): " + (recommendations.first?.title ?? "none"))
        let anomalies = computeAnomalies()
        if !anomalies.isEmpty {
            lines.append("Anomalies (z-score based):")
            for a in anomalies { lines.append("  • " + a) }
        }
        return "Facts:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Score

    private func computeScore() -> HealthScore {
        var s = HealthScore()
        // Storage: penalize when used > 70%
        let storage = LiveStorage.shared
        let usedPct = storage.totalGB > 0 ? storage.usedGB / storage.totalGB : 0
        if usedPct >= 0.95      { s.storage = 0.10 }
        else if usedPct >= 0.85 { s.storage = 0.40 }
        else if usedPct >= 0.70 { s.storage = 0.75 }
        else                    { s.storage = 1.00 }

        // Memory: pressure first, then nudge by used%
        let mem = LiveMemory.shared
        let used = mem.usedFraction
        switch mem.pressure {
        case .normal:   s.memory = used > 0.92 ? 0.7 : 1.0
        case .warning:  s.memory = used > 0.95 ? 0.35 : 0.55
        case .critical: s.memory = 0.10
        }

        // Battery
        let bat = LiveBattery.shared
        if bat.hasBattery {
            s.hasBattery = true
            let h = bat.healthFraction
            if h <= 0           { s.battery = 1.0 }
            else if h >= 0.90   { s.battery = 1.0 }
            else if h >= 0.80   { s.battery = 0.85 }
            else if h >= 0.70   { s.battery = 0.6 }
            else                { s.battery = 0.3 }
            // Cycle wear nudges down
            if bat.maxCycleCount > 0 {
                let wear = Double(bat.cycleCount) / Double(bat.maxCycleCount)
                if wear > 0.85 { s.battery *= 0.7 }
            }
        }

        // Network
        let net = LiveNetwork.shared
        if net.primary == nil {
            s.network = 0.5     // unknown — give benefit of the doubt
        } else if net.pingMs < 0 {
            s.network = 0.75
        } else if net.pingMs < 50 {
            s.network = 1.0
        } else if net.pingMs < 150 {
            s.network = 0.7
        } else {
            s.network = 0.4
        }

        // Hygiene: penalize unverified startup, big duplicate sets, lots of unused
        var hy = 1.0
        let st = LiveStartup.shared
        if st.unknownCount > 0 { hy -= min(0.30, Double(st.unknownCount) * 0.02) }
        let dups = LiveDuplicates.shared
        if dups.totalGroups > 0 { hy -= min(0.25, Double(dups.totalGroups) * 0.01) }
        let un = LiveUnused.shared
        if un.totalCount > 0 { hy -= min(0.20, Double(un.totalCount) * 0.005) }
        let dlc = LiveDownloadsCache.shared
        if dlc.totalCount > 100 { hy -= min(0.10, Double(dlc.totalCount - 100) * 0.001) }
        s.hygiene = max(0, min(1, hy))

        return s
    }

    // MARK: - Tickers

    private func computeTickers() -> [DashTicker] {
        let storage = LiveStorage.shared
        let mem = LiveMemory.shared
        let bat = LiveBattery.shared
        let net = LiveNetwork.shared

        let storagePct = storage.totalGB > 0 ? storage.usedGB / storage.totalGB : 0
        let memPct = mem.usedFraction

        var rows: [DashTicker] = []
        rows.append(.init(
            icon: "internaldrive", label: "Storage",
            value: "\(Int((storagePct * 100).rounded()))%",
            detail: String(format: "%.0f GB free", storage.freeGB),
            color: storagePct > 0.85 ? Tokens.danger : storagePct > 0.7 ? Tokens.warn : Tokens.good,
            target: .storage
        ))
        rows.append(.init(
            icon: "memorychip", label: "Memory",
            value: "\(Int((memPct * 100).rounded()))%",
            detail: mem.pressure.label,
            color: mem.pressure.color,
            target: .memory
        ))
        if bat.hasBattery {
            rows.append(.init(
                icon: bat.state.icon, label: "Battery",
                value: "\(Int((bat.percent * 100).rounded()))%",
                detail: bat.state.label,
                color: bat.state.color,
                target: .battery
            ))
        }
        rows.append(.init(
            icon: "arrow.down", label: "Down",
            value: LiveNetwork.bps(net.rateInBps),
            detail: "Session \(LiveNetwork.bytes(net.sessionBytesIn))",
            color: Tokens.good,
            target: .network
        ))
        rows.append(.init(
            icon: "arrow.up", label: "Up",
            value: LiveNetwork.bps(net.rateOutBps),
            detail: "Session \(LiveNetwork.bytes(net.sessionBytesOut))",
            color: Tokens.catApps,
            target: .network
        ))
        rows.append(.init(
            icon: "stopwatch", label: "Latency",
            value: net.pingMs >= 0 ? "\(Int(net.pingMs.rounded())) ms" : "—",
            detail: net.gateway.isEmpty ? "—" : "→ \(net.gateway)",
            color: net.pingMs < 0 ? Tokens.text3 : net.pingMs < 50 ? Tokens.good
                  : net.pingMs < 150 ? Tokens.warn : Tokens.danger,
            target: .network
        ))
        return rows
    }

    // MARK: - Recommendations

    private func computeRecommendations() -> [DashRecommendation] {
        var out: [DashRecommendation] = []
        let storage = LiveStorage.shared
        let mem = LiveMemory.shared
        let bat = LiveBattery.shared
        let dups = LiveDuplicates.shared
        let un = LiveUnused.shared
        let dlc = LiveDownloadsCache.shared
        let st = LiveStartup.shared
        let lf = LiveLargeFiles.shared

        let usedPct = storage.totalGB > 0 ? storage.usedGB / storage.totalGB : 0
        if usedPct >= 0.85 {
            out.append(.init(
                tone: .danger, icon: "internaldrive.fill",
                title: "Disk is \(Int((usedPct*100).rounded()))% full",
                body: "macOS performance degrades quickly past 90% — clear out large files or duplicates.",
                actionLabel: "Open Storage", target: .storage, priority: 100
            ))
        }
        if mem.pressure != .normal {
            out.append(.init(
                tone: mem.pressure == .critical ? .danger : .warn, icon: "memorychip",
                title: "Memory pressure: \(mem.pressure.label.lowercased())",
                body: "Quit apps you're not using to relieve pressure and avoid swap thrashing.",
                actionLabel: "Top processes", target: .memory, priority: mem.pressure == .critical ? 95 : 70
            ))
        }
        if bat.hasBattery {
            let h = bat.healthFraction
            if h > 0 && h < 0.80 {
                out.append(.init(
                    tone: .warn, icon: "heart.text.square.fill",
                    title: "Battery health is \(Int((h*100).rounded()))%",
                    body: "Capacity has dropped below 80% of design. A service appointment is worth considering.",
                    actionLabel: "Battery details", target: .battery, priority: 75
                ))
            }
            if bat.predictedDrainPctPerHour > 18 && bat.state == .discharging {
                out.append(.init(
                    tone: .warn, icon: "exclamationmark.triangle.fill",
                    title: "Battery is draining fast — \(String(format: "%.1f", bat.predictedDrainPctPerHour))%/hr",
                    body: "Significantly higher than your typical rate. Check the top energy users.",
                    actionLabel: "Battery", target: .battery, priority: 60
                ))
            }
        }
        if dups.totalGroups > 0 && dups.totalRecoverable > 1_000_000_000 {
            out.append(.init(
                tone: .info, icon: "doc.on.doc.fill",
                title: "Recover \(dups.totalRecoverableText) from duplicates",
                body: "\(dups.totalGroups) groups of byte- or visually-identical files were found.",
                actionLabel: "Resolve", target: .duplicates, priority: 80
            ))
        }
        if lf.totalBytes > 5_000_000_000 {
            out.append(.init(
                tone: .info, icon: "doc",
                title: "\(lf.items.count) large files use \(lf.totalSizeText)",
                body: "Files at or above the size threshold. Trim media, downloads, and old VMs first.",
                actionLabel: "Open Large Files", target: .large, priority: 55
            ))
        }
        if un.totalCount > 10 {
            out.append(.init(
                tone: .info, icon: "clock.arrow.circlepath",
                title: "\(un.totalCount) items haven't been touched in months",
                body: "Apps and folders untouched past your unused threshold — \(un.totalText) total.",
                actionLabel: "Review", target: .unused, priority: 50
            ))
        }
        if dlc.totalCount > 0 {
            out.append(.init(
                tone: .info, icon: "arrow.down.circle",
                title: "\(dlc.totalCount) files queued in Downloads & cache",
                body: "Likely safe to remove old installers, screenshots, and app caches.",
                actionLabel: "Open", target: .downloads, priority: 45
            ))
        }
        if st.unknownCount > 0 {
            out.append(.init(
                tone: .warn, icon: "powerplug.fill",
                title: "\(st.unknownCount) unverified startup item\(st.unknownCount > 1 ? "s" : "")",
                body: "Launch agents from publishers we don't recognize — review and disable any you didn't install.",
                actionLabel: "Review startup", target: .startup, priority: 65
            ))
        }
        // NaturalLanguage-derived process clusters: surface fragmented apps using a lot of RAM.
        for cluster in clusterTopProcesses().prefix(2) {
            let gb = Double(cluster.bytes) / 1_073_741_824
            out.append(.init(
                tone: gb > 4 ? .warn : .info, icon: "rectangle.3.group.fill",
                title: "\(cluster.name) is using \(String(format: "%.1f GB", gb)) across \(cluster.count) processes",
                body: "Browser/app helpers add up — quit unused tabs or windows to release memory.",
                actionLabel: "Top processes", target: .memory,
                priority: gb > 4 ? 72 : 55
            ))
        }
        if out.isEmpty {
            out.append(.init(
                tone: .good, icon: "checkmark.seal.fill",
                title: "Nothing urgent",
                body: "All subsystems are within normal ranges. Run a fresh scan periodically to keep it that way.",
                actionLabel: "Run quick scan", target: .dashboard, priority: 0
            ))
        }
        out.sort { $0.priority > $1.priority }
        return out
    }

    // MARK: - Forecasts

    private func computeForecasts() -> [DashForecast] {
        var out: [DashForecast] = []
        let mem = LiveMemory.shared
        let bat = LiveBattery.shared
        let storage = LiveStorage.shared

        // Memory: vDSP linear regression on history (used%) → time to 95% used.
        if let mf = memoryRunway(history: mem.history) {
            out.append(mf)
        }

        // Battery: prediction already lives in LiveBattery
        if bat.hasBattery {
            if bat.state == .discharging && bat.predictedRemainingMin > 0 {
                let mins = bat.predictedRemainingMin
                let h = mins / 60, m = mins % 60
                out.append(.init(
                    icon: "battery.25",
                    label: "Battery to empty",
                    when: h > 0 ? "in \(h) hr \(m) min" : "in \(m) min",
                    detail: String(format: "Drain %.1f%%/hr", bat.predictedDrainPctPerHour),
                    confidence: 0.85,
                    color: bat.state.color,
                    target: .battery
                ))
            } else if bat.state == .charging && bat.timeRemaining > 0 {
                let mins = bat.timeRemaining
                let h = mins / 60, m = mins % 60
                out.append(.init(
                    icon: "bolt.fill",
                    label: "Battery to full",
                    when: h > 0 ? "in \(h) hr \(m) min" : "in \(m) min",
                    detail: bat.adapterWatts > 0 ? "\(bat.adapterWatts) W adapter" : "Charging",
                    confidence: 0.75,
                    color: bat.state.color,
                    target: .battery
                ))
            }
        }

        // Storage: regression over recorded history. If <2h of data, fall back to current state.
        let usedPct = storage.totalGB > 0 ? storage.usedGB / storage.totalGB : 0
        if let f = diskRunway() {
            out.append(f)
        } else {
            out.append(.init(
                icon: "internaldrive",
                label: "Disk capacity",
                when: usedPct >= 0.95 ? "Critical" : usedPct >= 0.85 ? "Watch closely" : "Healthy",
                detail: "\(Int((usedPct*100).rounded()))% used · \(String(format: "%.0f GB", storage.freeGB)) free — gathering trend",
                confidence: 0.5,
                color: usedPct > 0.85 ? Tokens.danger : usedPct > 0.7 ? Tokens.warn : Tokens.good,
                target: .storage
            ))
        }
        return out
    }

    /// vDSP regression over storage history → projected days until disk hits 90% used.
    private func diskRunway() -> DashForecast? {
        guard storageHistory.count >= 4 else { return nil }
        let recent = Array(storageHistory.suffix(2000))
        guard let first = recent.first, let last = recent.last,
              last.t - first.t >= 7200 else { return nil }
        let xs = recent.map { $0.t }
        let ys = recent.map { $0.usedGB }
        guard let lr = LiveDashboard.linearFit(xs: xs, ys: ys) else { return nil }
        let storage = LiveStorage.shared
        let total = storage.totalGB
        let current = ys.last ?? storage.usedGB
        let target = total * 0.90
        let storagePct = total > 0 ? storage.usedGB / total : 0
        if lr.slope <= 0 || current >= target {
            return DashForecast(
                icon: "internaldrive",
                label: "Disk trend",
                when: lr.slope <= 0 ? "Stable / shrinking" : "Already past 90%",
                detail: String(format: "%.0f GB free · trend %+.2f GB/day", storage.freeGB, lr.slope * 86400),
                confidence: lr.r2,
                color: storagePct > 0.85 ? Tokens.danger : storagePct > 0.7 ? Tokens.warn : Tokens.good,
                target: .storage
            )
        }
        let secsToTarget = (target - current) / lr.slope
        guard secsToTarget.isFinite, secsToTarget > 0 else { return nil }
        let days = secsToTarget / 86400
        let when: String
        if days < 1 { when = "in \(Int((days * 24).rounded())) hr" }
        else if days < 60 { when = "in \(Int(days.rounded())) days" }
        else { when = "in \(Int((days / 30).rounded())) months" }
        return DashForecast(
            icon: "internaldrive.fill",
            label: "Disk full (90%)",
            when: when,
            detail: String(format: "+%.2f GB/day at current rate", lr.slope * 86400),
            confidence: lr.r2,
            color: days < 14 ? Tokens.danger : days < 60 ? Tokens.warn : Tokens.good,
            target: .storage
        )
    }

    /// Linear regression on memory used% — returns a forecast if pressure is rising.
    private func memoryRunway(history: [MemorySample]) -> DashForecast? {
        guard history.count >= 6 else { return nil }
        let xs = history.map { $0.t }
        let ys = history.map { Double($0.u) }
        guard let lr = LiveDashboard.linearFit(xs: xs, ys: ys) else { return nil }
        let slope = lr.slope                // fraction per second
        if slope <= 0 {
            return DashForecast(
                icon: "memorychip",
                label: "Memory trend",
                when: "Stable",
                detail: "No upward pressure detected",
                confidence: lr.r2,
                color: Tokens.good,
                target: .memory
            )
        }
        let now = Date().timeIntervalSince1970
        let current = ys.last ?? 0
        // Project to 95% used
        let target = 0.95
        guard current < target else { return nil }
        let secsToTarget = (target - current) / slope
        guard secsToTarget.isFinite, secsToTarget > 0 else { return nil }
        let mins = Int(secsToTarget / 60)
        let when: String
        if mins < 60 { when = "in \(mins) min" }
        else { when = "in \(mins/60) hr \(mins%60) min" }
        return DashForecast(
            icon: "memorychip.fill",
            label: "Memory critical",
            when: when,
            detail: String(format: "+%.1f%% / hr", slope * 3600 * 100),
            confidence: lr.r2,
            color: mins < 30 ? Tokens.danger : mins < 120 ? Tokens.warn : Tokens.catApps,
            target: .memory
        )
        _ = now    // silence unused-variable warning if we ever drop the projection
    }

    // MARK: - Timeline (last 24h)

    private func computeTimeline() -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let cutoff = Date().addingTimeInterval(-86400)

        // Battery: collapse contiguous charging/discharging stretches
        let bat = LiveBattery.shared.samples.filter { Date(timeIntervalSince1970: $0.t) >= cutoff }
        if !bat.isEmpty {
            var i = 0
            while i < bat.count {
                let kind: ActivityKind?
                switch bat[i].charging {
                case 1:  kind = .charge
                case -1: kind = .drain
                default: kind = nil
                }
                guard let k = kind else { i += 1; continue }
                var j = i
                while j < bat.count {
                    let next: ActivityKind? = {
                        switch bat[j].charging { case 1: .charge; case -1: .drain; default: nil }
                    }()
                    if next != k { break }
                    j += 1
                }
                let start = Date(timeIntervalSince1970: bat[i].t)
                let end = Date(timeIntervalSince1970: bat[max(j-1, i)].t)
                if end.timeIntervalSince(start) > 60 {  // ignore <1 min slices
                    let pctStart = Int((bat[i].percent * 100).rounded())
                    let pctEnd = Int((bat[max(j-1, i)].percent * 100).rounded())
                    events.append(.init(
                        start: start, end: end, kind: k,
                        detail: k == .charge ? "Charged \(pctStart)% → \(pctEnd)%" : "Drained \(pctStart)% → \(pctEnd)%"
                    ))
                }
                i = j
            }
        }

        // Memory spikes: any sample where used > 0.93
        let mem = LiveMemory.shared.history.filter { Date(timeIntervalSince1970: $0.t) >= cutoff }
        var spikeStart: TimeInterval? = nil
        for s in mem {
            if Double(s.u) > 0.93 {
                if spikeStart == nil { spikeStart = s.t }
            } else if let st = spikeStart {
                events.append(.init(
                    start: Date(timeIntervalSince1970: st),
                    end: Date(timeIntervalSince1970: s.t),
                    kind: .memorySpike,
                    detail: "Memory >93% used"
                ))
                spikeStart = nil
            }
        }
        if let st = spikeStart, let last = mem.last?.t {
            events.append(.init(
                start: Date(timeIntervalSince1970: st),
                end: Date(timeIntervalSince1970: last),
                kind: .memorySpike,
                detail: "Memory >93% used"
            ))
        }

        // Network: sustained throughput > 5 MB/s
        let net = LiveNetwork.shared.samples.filter { Date(timeIntervalSince1970: $0.t) >= cutoff }
        var netStart: TimeInterval? = nil
        for s in net {
            let total = s.downBps + s.upBps
            if total > 5_000_000 {
                if netStart == nil { netStart = s.t }
            } else if let st = netStart {
                events.append(.init(
                    start: Date(timeIntervalSince1970: st),
                    end: Date(timeIntervalSince1970: s.t),
                    kind: .networkSpike,
                    detail: ">5 MB/s sustained"
                ))
                netStart = nil
            }
        }

        events.sort { $0.start < $1.start }
        return events
    }

    // MARK: - Briefing (template; Foundation Models added in Step 3)

    private func composeBriefing() -> String {
        let g = score.grade
        let mem = LiveMemory.shared
        let bat = LiveBattery.shared
        let net = LiveNetwork.shared
        let dups = LiveDuplicates.shared
        let st = LiveStartup.shared

        var beats: [String] = []
        // 1) Headline
        switch g {
        case .excellent: beats.append("Your Mac is in excellent shape.")
        case .good:      beats.append("Your Mac looks good overall.")
        case .fair:      beats.append("Your Mac is running fine, with a few things worth a glance.")
        case .warn:      beats.append("A few subsystems need attention.")
        case .critical:  beats.append("Several systems are struggling — review the items below.")
        }
        // 2) The strongest signal
        if let top = recommendations.first, top.priority >= 60 {
            beats.append(top.title + ".")
        }
        // 3) Memory or battery callout
        if mem.pressure != .normal {
            beats.append("Memory pressure is \(mem.pressure.label.lowercased()) right now.")
        }
        if bat.hasBattery && bat.state == .discharging && bat.predictedDrainPctPerHour > 0 {
            beats.append(String(format: "On battery, draining at %.1f%%/hr.", bat.predictedDrainPctPerHour))
        }
        // 4) Network color
        if net.primary != nil && net.pingMs >= 0 {
            if net.pingMs > 200 { beats.append("Network latency is high (\(Int(net.pingMs.rounded())) ms).") }
        }
        // 5) Recoverable disk
        if dups.totalRecoverable > 5_000_000_000 {
            beats.append("\(dups.totalRecoverableText) is recoverable from duplicates.")
        }
        if st.unknownCount > 0 {
            beats.append("\(st.unknownCount) startup item\(st.unknownCount > 1 ? "s are" : " is") from publishers we couldn't verify.")
        }
        let anomalies = computeAnomalies()
        if !anomalies.isEmpty {
            beats.append(anomalies.first!)
        }
        return beats.joined(separator: " ")
    }

    // MARK: - Math

    private static func linearFit(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double, r2: Double)? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = vDSP_Length(xs.count)
        var meanX = 0.0, meanY = 0.0
        vDSP_meanvD(xs, 1, &meanX, n)
        vDSP_meanvD(ys, 1, &meanY, n)
        var num = 0.0, den = 0.0, totSS = 0.0, resSS = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            num += dx * dy
            den += dx * dx
            totSS += dy * dy
        }
        guard den > 0 else { return nil }
        let slope = num / den
        let intercept = meanY - slope * meanX
        for i in 0..<xs.count {
            let pred = slope * xs[i] + intercept
            let err = ys[i] - pred
            resSS += err * err
        }
        let r2 = totSS == 0 ? 1.0 : max(0, 1.0 - resSS / totSS)
        return (slope, intercept, r2)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var m = 0.0; vDSP_meanvD(values, 1, &m, vDSP_Length(values.count)); return m
    }
    private static func stddev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let m = mean(values)
        var sumSq = 0.0
        for v in values { let d = v - m; sumSq += d * d }
        return sqrt(sumSq / Double(values.count))
    }

    // MARK: - Storage SQLite

    private func openDB() {
        if sqlite3_open(Self.dbURL.path, &db) != SQLITE_OK { db = nil; return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS storage_samples(
                t REAL PRIMARY KEY, used_gb REAL, total_gb REAL
            );
            CREATE INDEX IF NOT EXISTS idx_storage_t ON storage_samples(t);
        """, nil, nil, nil)
        // Trim past 30 days
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM storage_samples WHERE t<?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff); sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func loadStorageHistory() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        if sqlite3_prepare_v2(db, "SELECT t,used_gb,total_gb FROM storage_samples WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        var rows: [StorageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(StorageSample(
                t: sqlite3_column_double(stmt, 0),
                usedGB: sqlite3_column_double(stmt, 1),
                totalGB: sqlite3_column_double(stmt, 2)
            ))
        }
        storageHistory = rows
    }

    private func recordStorageSample() {
        let storage = LiveStorage.shared
        guard storage.totalGB > 0 else { return }
        let s = StorageSample(t: Date().timeIntervalSince1970,
                              usedGB: storage.usedGB,
                              totalGB: storage.totalGB)
        storageHistory.append(s)
        // Keep memory-resident window to last 7 days only
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        if let i = storageHistory.firstIndex(where: { $0.t >= cutoff }), i > 0 {
            storageHistory.removeFirst(i)
        }
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO storage_samples(t,used_gb,total_gb) VALUES (?,?,?)", -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, s.t)
        sqlite3_bind_double(stmt, 2, s.usedGB)
        sqlite3_bind_double(stmt, 3, s.totalGB)
        sqlite3_step(stmt)
    }

    // MARK: - Anomaly z-scores

    /// Compare the current value to the mean+stddev over the recent window. Returns the z-score.
    private static func zScore(current: Double, baseline: [Double]) -> Double? {
        guard baseline.count >= 10 else { return nil }
        let m = mean(baseline)
        let sd = stddev(baseline)
        guard sd > 1e-9 else { return nil }
        return (current - m) / sd
    }

    private func computeAnomalies() -> [String] {
        var out: [String] = []
        let mem = LiveMemory.shared
        let net = LiveNetwork.shared
        let bat = LiveBattery.shared
        // Memory: current used% vs last 30m mean
        if let last = mem.history.last {
            let baseline = mem.history.map { Double($0.u) }
            if let z = Self.zScore(current: Double(last.u), baseline: baseline), abs(z) >= 1.8 {
                out.append(z > 0
                    ? String(format: "Memory used is %.1fσ above the recent average.", z)
                    : String(format: "Memory used is %.1fσ below the recent average.", -z))
            }
        }
        // Network: current down rate vs samples baseline
        if let last = net.samples.last {
            let baseline = net.samples.map { $0.downBps }
            if let z = Self.zScore(current: last.downBps, baseline: baseline), z >= 2.0 {
                out.append(String(format: "Download throughput is %.1fσ above your normal rate.", z))
            }
        }
        // Battery: drain rate vs discharging samples
        if bat.hasBattery, bat.state == .discharging, bat.predictedDrainPctPerHour > 0 {
            // Build per-hour baseline drain from samples (rough: differentials between consecutive
            // discharging samples). Skip if too sparse.
            var rates: [Double] = []
            let samples = bat.samples
            for i in 1..<samples.count where samples[i].charging == -1 && samples[i-1].charging == -1 {
                let dt = samples[i].t - samples[i-1].t
                if dt > 30 && dt < 600 {
                    let dp = (samples[i-1].percent - samples[i].percent) / dt * 3600 * 100
                    if dp >= 0 { rates.append(dp) }
                }
            }
            if let z = Self.zScore(current: bat.predictedDrainPctPerHour, baseline: rates), z >= 1.8 {
                out.append(String(format: "Battery drain is %.1fσ faster than usual.", z))
            }
        }
        return out
    }

    // MARK: - Process clustering with NaturalLanguage

    /// Group LiveMemory.topProcesses by a normalized base name (e.g. "Chrome Helper (Renderer)" → "Chrome").
    /// Uses NLTokenizer to split into words, then drops known boilerplate suffixes.
    private static let boilerplate: Set<String> = [
        "helper", "renderer", "gpu", "agent", "service", "daemon",
        "background", "extension", "subagent", "worker", "node"
    ]

    private func clusterTopProcesses() -> [(name: String, count: Int, bytes: UInt64)] {
        let procs = LiveMemory.shared.topProcesses
        guard procs.count >= 2 else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        var buckets: [String: (count: Int, bytes: UInt64)] = [:]
        for p in procs {
            let raw = p.name
            tokenizer.string = raw
            var first: String? = nil
            tokenizer.enumerateTokens(in: raw.startIndex..<raw.endIndex) { range, _ in
                let token = raw[range].lowercased()
                if !Self.boilerplate.contains(token), token.count >= 2, token.first?.isLetter == true {
                    first = String(token).capitalized
                    return false
                }
                return true
            }
            let base = first ?? raw
            let existing = buckets[base] ?? (0, 0)
            buckets[base] = (existing.count + 1, existing.bytes &+ p.bytes)
        }
        return buckets
            .filter { $0.value.count >= 3 || $0.value.bytes >= 800_000_000 }
            .map { (name: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: - 7-day trends

    private func computeTrends() -> [TrendSeries] {
        var out: [TrendSeries] = []

        // Storage trend (used GB over time → normalized to 0-1 as fraction of total)
        if storageHistory.count >= 2 {
            let lastTotal = storageHistory.last!.totalGB
            let bucketed = bucketize(storageHistory.map { $0.t },
                                     values: storageHistory.map { $0.usedGB / max(lastTotal, 1) },
                                     buckets: 28)
            let last = bucketed.last ?? 0
            out.append(.init(
                label: "Storage", unit: "% used",
                values: bucketed,
                valueText: "\(Int((last * 100).rounded()))%",
                detail: storageHistory.count >= 4 ? "Last 7 days" : "Recording…",
                color: last > 0.85 ? Tokens.danger : last > 0.7 ? Tokens.warn : Tokens.good,
                target: .storage
            ))
        }

        // Memory peak per hour
        let memSamples = LiveMemory.shared.history
        if memSamples.count >= 8 {
            let bucketed = bucketize(memSamples.map { $0.t },
                                     values: memSamples.map { Double($0.u) },
                                     buckets: 24, agg: .max)
            let peak = bucketed.max() ?? 0
            out.append(.init(
                label: "Memory peak", unit: "%",
                values: bucketed,
                valueText: "\(Int((peak * 100).rounded()))%",
                detail: "Hourly highs",
                color: peak > 0.92 ? Tokens.danger : peak > 0.8 ? Tokens.warn : Tokens.good,
                target: .memory
            ))
        }

        // Network volume per hour (sum of bytes)
        let netSamples = LiveNetwork.shared.samples
        if netSamples.count >= 8 {
            // sum (down+up) bytes per bucket
            let bucketed = bucketize(netSamples.map { $0.t },
                                     values: netSamples.map { ($0.downBps + $0.upBps) },
                                     buckets: 24, agg: .sum)
            let mx = bucketed.max() ?? 1
            let normalized = bucketed.map { mx > 0 ? $0 / mx : 0 }
            out.append(.init(
                label: "Network", unit: "throughput",
                values: normalized,
                valueText: LiveNetwork.bps(bucketed.last ?? 0),
                detail: "Hourly volume",
                color: Tokens.catApps,
                target: .network
            ))
        }

        // Battery health drift (max_capacity / design_capacity per snapshot)
        let healthSnaps = LiveBattery.shared.healthHistory
        if healthSnaps.count >= 2 {
            let frac = healthSnaps.map { snap -> Double in
                guard snap.designCapacity > 0 else { return 1 }
                return Double(snap.maxCapacity) / Double(snap.designCapacity)
            }
            let bucketed = bucketize(healthSnaps.map { $0.t }, values: frac, buckets: 30, agg: .last)
            let last = bucketed.last ?? 1
            out.append(.init(
                label: "Battery health", unit: "%",
                values: bucketed,
                valueText: "\(Int((last * 100).rounded()))%",
                detail: "30-day drift",
                color: last < 0.8 ? Tokens.warn : Tokens.good,
                target: .battery
            ))
        }
        return out
    }

    private enum BucketAgg { case mean, max, sum, last }
    /// Group raw samples into N evenly-spaced buckets across the time span and aggregate.
    private func bucketize(_ ts: [TimeInterval], values vs: [Double], buckets: Int,
                           agg: BucketAgg = .mean) -> [Double] {
        guard ts.count == vs.count, let first = ts.first, let last = ts.last, last > first else {
            return Array(repeating: 0, count: buckets)
        }
        let span = last - first
        let bucketSpan = span / Double(buckets)
        var bins: [[Double]] = Array(repeating: [], count: buckets)
        for i in 0..<ts.count {
            let idx = min(buckets - 1, max(0, Int((ts[i] - first) / bucketSpan)))
            bins[idx].append(vs[i])
        }
        var out: [Double] = []
        var carry: Double = 0
        for b in bins {
            if b.isEmpty { out.append(carry); continue }
            let v: Double
            switch agg {
            case .mean: v = b.reduce(0, +) / Double(b.count)
            case .max:  v = b.max() ?? 0
            case .sum:  v = b.reduce(0, +)
            case .last: v = b.last ?? 0
            }
            carry = v
            out.append(v)
        }
        return out
    }
}
