import Foundation
import SwiftUI
import Combine
import AppKit
import Accelerate
import NaturalLanguage
import SQLite3
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case h24 = "24h", d7 = "7d", d30 = "30d", d90 = "90d", all = "All"
    var id: String { rawValue }
    /// Seconds, or `nil` for "all".
    var seconds: TimeInterval? {
        switch self {
        case .h24: return 86400
        case .d7:  return 7 * 86400
        case .d30: return 30 * 86400
        case .d90: return 90 * 86400
        case .all: return nil
        }
    }
    var label: String { rawValue }
}

enum AnalyticsMetric: String, CaseIterable, Identifiable {
    case memoryUsed = "Memory used"
    case downBps    = "Download"
    case upBps      = "Upload"
    case ping       = "Latency"
    case diskUsed   = "Disk used"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .memoryUsed: return Tokens.purple
        case .downBps:    return Tokens.good
        case .upBps:      return Tokens.catApps
        case .ping:       return Tokens.warn
        case .diskUsed:   return Tokens.indigo
        }
    }
    var unit: String {
        switch self { case .memoryUsed, .diskUsed: "%"; case .downBps, .upBps: "bps"; case .ping: "ms" }
    }
}

struct MetricSeries {
    let metric: AnalyticsMetric
    let times: [TimeInterval]
    let values: [Double]
    let normalizedValues: [Double]   // 0…1 for chart
    let peak: Double
}

struct Heatmap {
    let label: String
    let cells: [[Double]]   // [day][hour], 7×24, normalized 0…1
    let peakValue: Double
    let peakLabel: String
    let color: Color
}

struct Histogram {
    let label: String
    let bins: [String]      // labels per bin
    let counts: [Int]
    let color: Color
}

struct AnalyticsRecord: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    let detail: String
    let date: Date?
    let color: Color
    let target: Screen
}

struct WoWDelta: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let deltaText: String
    let deltaPositiveIsBad: Bool   // e.g. memory peak going up = bad
    let positive: Bool             // sign of delta
    let icon: String
    let color: Color
    let target: Screen
}

struct DayCleanup: Identifiable {
    let id = UUID()
    let day: Date
    let perModule: [CleanupModule: Int64]    // bytes
    var total: Int64 { perModule.values.reduce(0, +) }
}

struct SessionDay: Identifiable {
    let id = UUID()
    let day: Date
    let sessionCount: Int
    let activeMinutes: Int
}

@MainActor
final class LiveAnalytics: ObservableObject {
    static let shared = LiveAnalytics()

    @Published var range: AnalyticsRange = .d7
    @Published var primaryMetric: AnalyticsMetric = .memoryUsed
    @Published var secondaryMetric: AnalyticsMetric = .downBps

    @Published private(set) var loading: Bool = false
    @Published private(set) var lastRefresh: Date = .distantPast

    @Published private(set) var primarySeries: MetricSeries? = nil
    @Published private(set) var secondarySeries: MetricSeries? = nil

    @Published private(set) var heatmaps: [Heatmap] = []
    @Published private(set) var histograms: [Histogram] = []
    @Published private(set) var records: [AnalyticsRecord] = []
    @Published private(set) var deltas: [WoWDelta] = []
    @Published private(set) var cleanupHistory: [DayCleanup] = []
    @Published private(set) var totalCleanedBytes: Int64 = 0
    @Published private(set) var sessions: [SessionDay] = []
    @Published private(set) var totalActiveHours: Double = 0

    @Published private(set) var summary: String = ""
    @Published private(set) var intelligenceStatus: IntelligenceStatus = .rules
    @Published private(set) var observedCoverage: String = "no samples"

    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>? = nil
    private var intelligenceTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var intelligenceGeneration = 0
    private var currentIntelligenceFingerprint = ""
    private var activeIntelligenceFingerprint: String?
    private var completedIntelligenceFingerprint: String?
    private var lastIntelligenceAttempt: Date?
    private var lastIntelligenceAttemptFingerprint: String?

    private init() {
        // Recompute (debounced) when any input changes.
        Publishers.CombineLatest3($range.removeDuplicates(),
                                  $primaryMetric.removeDuplicates(),
                                  $secondaryMetric.removeDuplicates())
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.recompute() }
            .store(in: &cancellables)
    }

    func start() {
        if records.isEmpty { recompute() }
    }
    func stop() {
        refreshTask?.cancel(); refreshTask = nil
        intelligenceTask?.cancel(); intelligenceTask = nil
        activeIntelligenceFingerprint = nil
        refreshGeneration &+= 1
        intelligenceGeneration &+= 1
    }

    func refresh() { recompute() }

    private func recompute() {
        refreshTask?.cancel()
        intelligenceTask?.cancel(); intelligenceTask = nil
        activeIntelligenceFingerprint = nil
        refreshGeneration &+= 1
        intelligenceGeneration &+= 1
        let generation = refreshGeneration
        loading = true
        let r = range
        let primary = primaryMetric
        let secondary = secondaryMetric
        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snap = AnalyticsCompute.run(range: r, primary: primary, secondary: secondary)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.refreshGeneration else { return }
                self.primarySeries     = snap.primarySeries
                self.secondarySeries   = snap.secondarySeries
                self.heatmaps          = snap.heatmaps
                self.histograms        = snap.histograms
                self.records           = snap.records
                self.deltas            = snap.deltas
                self.cleanupHistory    = snap.cleanupHistory
                self.totalCleanedBytes = snap.totalCleanedBytes
                self.sessions          = snap.sessions
                self.totalActiveHours  = snap.totalActiveHours
                self.summary           = snap.summary
                self.observedCoverage  = snap.coverage.summary
                let fingerprint = IntelligencePolicy.fingerprint(for: snap.intelligenceFacts)
                self.currentIntelligenceFingerprint = fingerprint
                if self.completedIntelligenceFingerprint != fingerprint {
                    if self.lastIntelligenceAttemptFingerprint == fingerprint,
                       case .failed = self.intelligenceStatus {
                        // Keep the failure visible until the cooldown permits another attempt.
                    } else {
                        self.intelligenceStatus = .rules
                    }
                }
                self.lastRefresh       = Date()
                self.loading           = false
                self.upgradeSummaryWithAppleIntelligence(
                    facts: snap.intelligenceFacts,
                    fallback: snap.summary,
                    fingerprint: fingerprint
                )
            }
        }
    }

    private func upgradeSummaryWithAppleIntelligence(
        facts: [GroundedFact],
        fallback: String,
        fingerprint: String
    ) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if let reason = IntelligencePolicy.unavailableReason(for: model) {
                intelligenceStatus = .unavailable(reason)
                return
            }
            let now = Date()
            guard IntelligencePolicy.shouldStart(
                fingerprint: fingerprint,
                activeFingerprint: activeIntelligenceFingerprint,
                completedFingerprint: completedIntelligenceFingerprint,
                lastAttempt: lastIntelligenceAttemptFingerprint == fingerprint ? lastIntelligenceAttempt : nil,
                now: now
            ) else { return }
            intelligenceGeneration &+= 1
            let generation = intelligenceGeneration
            activeIntelligenceFingerprint = fingerprint
            lastIntelligenceAttempt = now
            lastIntelligenceAttemptFingerprint = fingerprint
            intelligenceStatus = .generating
            let prompt = "Rank the supplied measured facts by importance. Return only their IDs.\n" +
                facts.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
            intelligenceTask = Task { @MainActor [weak self] in
                do {
                    let session = LanguageModelSession(instructions: """
                        You are the analytics narrator inside a macOS utility app called BloatMac.
                        Select the most important supplied fact IDs. Never create IDs or prose.
                    """)
                    let schema = try IntelligencePolicy.rankingSchema(for: facts)
                    let response = try await session.respond(
                        to: prompt,
                        schema: schema,
                        options: GenerationOptions(sampling: .greedy)
                    )
                    guard !Task.isCancelled, let self,
                          IntelligencePolicy.accepts(
                            generation: generation,
                            currentGeneration: self.intelligenceGeneration,
                            fingerprint: fingerprint,
                            currentFingerprint: self.currentIntelligenceFingerprint
                          ) else { return }
                    let returnedIDs = try response.content.value([String].self, forProperty: "factIDs")
                    let selectedIDs = IntelligencePolicy.acceptedIDs(returnedIDs, facts: facts)
                    let text = IntelligencePolicy.groundedText(
                        selectedIDs: selectedIDs,
                        facts: facts,
                        fallback: fallback
                    )
                    withAnimation(.easeOut(duration: 0.35)) {
                        self.summary = text
                        self.intelligenceStatus = selectedIDs.isEmpty ? .rules : .generated
                    }
                    self.completedIntelligenceFingerprint = fingerprint
                    self.activeIntelligenceFingerprint = nil
                    self.intelligenceTask = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          IntelligencePolicy.accepts(
                            generation: generation,
                            currentGeneration: self.intelligenceGeneration,
                            fingerprint: fingerprint,
                            currentFingerprint: self.currentIntelligenceFingerprint
                          ) else { return }
                    self.activeIntelligenceFingerprint = nil
                    self.intelligenceTask = nil
                    self.intelligenceStatus = .failed("Apple Intelligence could not rank the current facts. BloatMac kept the measured summary; refresh to retry.")
                }
            }
        }
        #else
        intelligenceStatus = .unavailable("Apple Intelligence is unavailable in this build. BloatMac is showing measured rules.")
        #endif
    }

    // MARK: - Export

    func exportCSV(table: ExportTable) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(table.rawValue)-\(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            let csv = AnalyticsCompute.exportCSV(table: table)
            try? csv.data(using: .utf8)?.write(to: url)
        }
    }

    func revealDataFolder() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

enum ExportTable: String { case network, battery, storage, cleanups }

// MARK: - Compute backend

private enum AnalyticsCompute {

    struct Snapshot {
        var primarySeries: MetricSeries? = nil
        var secondarySeries: MetricSeries? = nil
        var heatmaps: [Heatmap] = []
        var histograms: [Histogram] = []
        var records: [AnalyticsRecord] = []
        var deltas: [WoWDelta] = []
        var cleanupHistory: [DayCleanup] = []
        var totalCleanedBytes: Int64 = 0
        var sessions: [SessionDay] = []
        var totalActiveHours: Double = 0
        var summary: String = ""
        var intelligenceFacts: [GroundedFact] = []
        var coverage = ObservationCoverage(timestamps: [])
    }

    static func run(range: AnalyticsRange, primary: AnalyticsMetric, secondary: AnalyticsMetric) -> Snapshot {
        var snap = Snapshot()
        let now = Date().timeIntervalSince1970
        let cutoff = range.seconds.map { now - $0 } ?? 0
        let readCutoff = range.seconds.map { now - 2 * $0 } ?? 0

        // Read one preceding window as well, then keep displayed data scoped to the selected window.
        let allMemSamples = readMemoryJSON(since: readCutoff)
        let allNetSamples = readNetSQLite(since: readCutoff)
        let allBatSamples = readBatterySamples(since: readCutoff)
        let allStorSamples = readStorageSamples(since: readCutoff)
        let memSamples = allMemSamples.filter { $0.t >= cutoff }
        let netSamples = allNetSamples.filter { $0.t >= cutoff }
        let batSamples = allBatSamples.filter { $0.t >= cutoff }
        let storSamples = allStorSamples.filter { $0.t >= cutoff }
        let previousMem = allMemSamples.filter { $0.t < cutoff }
        let previousNet = allNetSamples.filter { $0.t < cutoff }
        let previousStor = allStorSamples.filter { $0.t < cutoff }
        let cleanupRows = CleanupLog.read(since: cutoff)

        snap.primarySeries   = makeSeries(primary,   memSamples: memSamples, netSamples: netSamples, storSamples: storSamples, points: 240)
        snap.secondarySeries = makeSeries(secondary, memSamples: memSamples, netSamples: netSamples, storSamples: storSamples, points: 240)

        if ObservationCoverage(timestamps: memSamples.map(\.t)).canPlot {
            snap.heatmaps.append(heatmapMemory(memSamples))
            snap.histograms.append(histMemory(memSamples))
        }
        if ObservationCoverage(timestamps: netSamples.map(\.t)).canPlot {
            snap.heatmaps.append(heatmapNetwork(netSamples))
            snap.histograms.append(histLatency(netSamples))
            snap.histograms.append(histDailyDownload(netSamples))
        }
        if ObservationCoverage(timestamps: batSamples.map(\.t)).canPlot {
            snap.heatmaps.append(heatmapCharging(batSamples))
        }

        snap.records = computeRecords(memSamples: memSamples, netSamples: netSamples,
                                      batSamples: batSamples, cleanupRows: cleanupRows)
        snap.deltas = computeDeltas(
            memSamples: memSamples, previousMem: previousMem,
            netSamples: netSamples, previousNet: previousNet,
            storSamples: storSamples, previousStor: previousStor
        )

        let cleanups = bucketCleanups(cleanupRows)
        snap.cleanupHistory    = cleanups
        snap.totalCleanedBytes = cleanupRows.reduce(0) { $0 + $1.bytes }

        let sessions = computeSessions(memSamples: memSamples, netSamples: netSamples)
        snap.sessions = sessions
        snap.totalActiveHours = Double(sessions.reduce(0) { $0 + $1.activeMinutes }) / 60.0

        snap.coverage = ObservationCoverage(timestamps:
            memSamples.map(\.t) + netSamples.map(\.t) + batSamples.map(\.t) + storSamples.map(\.t)
        )
        let composed = composeSummaryAndFacts(range: range, snap: snap,
                                              memCount: memSamples.count, netCount: netSamples.count,
                                              batCount: batSamples.count, storCount: storSamples.count)
        snap.summary   = composed.summary
        snap.intelligenceFacts = composed.facts
        return snap
    }

    // MARK: SQLite readers

    private static let dashboardDB: URL = appSupport().appendingPathComponent("dashboard.sqlite")
    private static let networkDB:   URL = appSupport().appendingPathComponent("network.sqlite")
    private static let batteryDB:   URL = appSupport().appendingPathComponent("battery.sqlite")
    private static let memoryJSON:  URL = appSupport().appendingPathComponent("memory_history.json")

    private static func appSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
    }

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK { return db }
        sqlite3_close(db); return nil
    }

    private static func readMemoryJSON(since cutoff: TimeInterval) -> [MemorySample] {
        guard let data = try? Data(contentsOf: memoryJSON),
              let arr  = try? JSONDecoder().decode([MemorySample].self, from: data) else { return [] }
        return arr.filter { $0.t >= cutoff }
    }

    private static func readNetSQLite(since cutoff: TimeInterval) -> [NetSample] {
        guard let db = openReadOnly(networkDB) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT t,down_bps,up_bps,ping_ms FROM net_samples WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, cutoff)
        var out: [NetSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(NetSample(
                t: sqlite3_column_double(stmt, 0),
                downBps: sqlite3_column_double(stmt, 1),
                upBps: sqlite3_column_double(stmt, 2),
                pingMs: sqlite3_column_double(stmt, 3)
            ))
        }
        return out
    }

    private static func readBatterySamples(since cutoff: TimeInterval) -> [BatteryReading] {
        guard let db = openReadOnly(batteryDB) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,
            "SELECT t,percent,charging,watts,voltage,amperage,temp,time_remaining FROM samples WHERE t>=? ORDER BY t ASC",
            -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, cutoff)
        var out: [BatteryReading] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(BatteryReading(
                t: sqlite3_column_double(stmt, 0),
                percent: sqlite3_column_double(stmt, 1),
                charging: Int(sqlite3_column_int(stmt, 2)),
                watts: sqlite3_column_double(stmt, 3),
                voltage: sqlite3_column_double(stmt, 4),
                amperage: sqlite3_column_double(stmt, 5),
                tempC: sqlite3_column_double(stmt, 6),
                timeRemaining: Int(sqlite3_column_int(stmt, 7))
            ))
        }
        return out
    }

    private static func readStorageSamples(since cutoff: TimeInterval) -> [StorageSample] {
        guard let db = openReadOnly(dashboardDB) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT t,used_gb,total_gb FROM storage_samples WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, cutoff)
        var out: [StorageSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(StorageSample(
                t: sqlite3_column_double(stmt, 0),
                usedGB: sqlite3_column_double(stmt, 1),
                totalGB: sqlite3_column_double(stmt, 2)
            ))
        }
        return out
    }

    // MARK: Series

    private static func makeSeries(_ metric: AnalyticsMetric,
                                   memSamples: [MemorySample],
                                   netSamples: [NetSample],
                                   storSamples: [StorageSample],
                                   points: Int) -> MetricSeries? {
        let xs: [Double], ys: [Double]
        switch metric {
        case .memoryUsed:
            guard ObservationCoverage(timestamps: memSamples.map(\.t)).canPlot else { return nil }
            xs = memSamples.map { $0.t }; ys = memSamples.map { Double($0.u) }
        case .downBps:
            guard ObservationCoverage(timestamps: netSamples.map(\.t)).canPlot else { return nil }
            xs = netSamples.map { $0.t }; ys = netSamples.map { $0.downBps }
        case .upBps:
            guard ObservationCoverage(timestamps: netSamples.map(\.t)).canPlot else { return nil }
            xs = netSamples.map { $0.t }; ys = netSamples.map { $0.upBps }
        case .ping:
            let filtered = netSamples.filter { $0.pingMs >= 0 }
            guard ObservationCoverage(timestamps: filtered.map(\.t)).canPlot else { return nil }
            xs = filtered.map { $0.t }; ys = filtered.map { $0.pingMs }
        case .diskUsed:
            guard ObservationCoverage(timestamps: storSamples.map(\.t)).canPlot else { return nil }
            xs = storSamples.map { $0.t }
            ys = storSamples.map { $0.totalGB > 0 ? $0.usedGB / $0.totalGB : 0 }
        }
        let bucketed = bucketize(xs, values: ys, buckets: points, agg: metric == .downBps || metric == .upBps ? .mean : .mean)
        let peak = bucketed.max() ?? 0
        let normalized = peak > 0 ? bucketed.map { $0 / peak } : bucketed
        let bucketTimes: [TimeInterval] = {
            guard let first = xs.first, let last = xs.last, last > first, points > 1 else {
                return Array(repeating: xs.last ?? 0, count: bucketed.count)
            }
            let span = last - first
            return (0..<points).map { first + Double($0) * span / Double(points - 1) }
        }()
        return MetricSeries(metric: metric, times: bucketTimes, values: bucketed,
                            normalizedValues: normalized, peak: peak)
    }

    enum BucketAgg { case mean, max, sum, last }

    static func bucketize(_ xs: [Double], values vs: [Double], buckets: Int, agg: BucketAgg = .mean) -> [Double] {
        guard xs.count == vs.count, let first = xs.first, let last = xs.last, last > first, buckets > 0 else {
            return Array(repeating: 0, count: buckets)
        }
        let span = last - first
        let bucketSpan = span / Double(buckets)
        var bins: [[Double]] = Array(repeating: [], count: buckets)
        for i in 0..<xs.count {
            let idx = min(buckets - 1, max(0, Int((xs[i] - first) / bucketSpan)))
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

    // MARK: Heatmaps

    private static func heatmapMemory(_ samples: [MemorySample]) -> Heatmap {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cal = Calendar(identifier: .gregorian)
        for s in samples {
            let d = Date(timeIntervalSince1970: s.t)
            let dow = (cal.component(.weekday, from: d) + 5) % 7   // Mon = 0
            let hr  = cal.component(.hour, from: d)
            grid[dow][hr]   += Double(s.u)
            counts[dow][hr] += 1
        }
        var peak = 0.0
        for d in 0..<7 { for h in 0..<24 {
            if counts[d][h] > 0 { grid[d][h] /= Double(counts[d][h]) }
            peak = max(peak, grid[d][h])
        }}
        return Heatmap(label: "Memory used %", cells: grid,
                       peakValue: peak,
                       peakLabel: "\(Int((peak*100).rounded()))% peak avg",
                       color: Tokens.purple)
    }

    private static func heatmapNetwork(_ samples: [NetSample]) -> Heatmap {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cal = Calendar(identifier: .gregorian)
        for s in samples {
            let d = Date(timeIntervalSince1970: s.t)
            let dow = (cal.component(.weekday, from: d) + 5) % 7
            let hr  = cal.component(.hour, from: d)
            grid[dow][hr] += s.downBps + s.upBps
            counts[dow][hr] += 1
        }
        for day in 0..<7 {
            for hour in 0..<24 where counts[day][hour] > 0 {
                grid[day][hour] /= Double(counts[day][hour])
            }
        }
        var peak = 0.0
        for d in 0..<7 { for h in 0..<24 { peak = max(peak, grid[d][h]) }}
        return Heatmap(label: "Network throughput", cells: grid,
                       peakValue: peak,
                       peakLabel: peak > 0 ? "Peak average \(LiveNetwork.bps(peak))" : "—",
                       color: Tokens.good)
    }

    private static func heatmapCharging(_ samples: [BatteryReading]) -> Heatmap {
        var sums = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let cal = Calendar(identifier: .gregorian)
        for s in samples {
            let d = Date(timeIntervalSince1970: s.t)
            let dow = (cal.component(.weekday, from: d) + 5) % 7
            let hr  = cal.component(.hour, from: d)
            counts[dow][hr] += 1
            if s.charging != -1 { sums[dow][hr] += 1 }
        }
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for d in 0..<7 { for h in 0..<24 {
            grid[d][h] = counts[d][h] > 0 ? sums[d][h] / Double(counts[d][h]) : 0
        }}
        return Heatmap(label: "Charging routine", cells: grid,
                       peakValue: 1.0, peakLabel: "Fraction on AC",
                       color: Tokens.good)
    }

    // MARK: Histograms

    private static func histMemory(_ samples: [MemorySample]) -> Histogram {
        var bins = Array(repeating: 0, count: 10)
        for s in samples {
            let i = min(9, max(0, Int(s.u * 10)))
            bins[i] += 1
        }
        let labels = (0..<10).map { i -> String in
            let lo = i * 10, hi = min((i + 1) * 10, 100)
            return "\(lo)–\(hi)%"
        }
        return Histogram(label: "Memory used distribution", bins: labels, counts: bins, color: Tokens.purple)
    }

    private static func histLatency(_ samples: [NetSample]) -> Histogram {
        let edges: [Double] = [0, 20, 50, 100, 200, .infinity]
        let labels = ["<20", "20-50", "50-100", "100-200", "200+"]
        var bins = Array(repeating: 0, count: 5)
        for s in samples where s.pingMs >= 0 {
            for i in 0..<5 where s.pingMs >= edges[i] && s.pingMs < edges[i + 1] {
                bins[i] += 1; break
            }
        }
        return Histogram(label: "Ping latency (ms)", bins: labels, counts: bins, color: Tokens.warn)
    }

    private static func histDailyDownload(_ samples: [NetSample]) -> Histogram {
        let cal = Calendar(identifier: .gregorian)
        var perDay: [Date: Double] = [:]
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let elapsed = min(max(samples[index].t - previous.t, 0), 60)
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: previous.t))
            perDay[day, default: 0] += previous.downBps * elapsed
        }
        let edges: [Double] = [0, 100_000_000, 1_000_000_000, 5_000_000_000, 20_000_000_000, .infinity]
        let labels = ["<100MB", "100MB-1GB", "1-5 GB", "5-20 GB", "20 GB+"]
        var bins = Array(repeating: 0, count: 5)
        for v in perDay.values {
            for i in 0..<5 where v >= edges[i] && v < edges[i + 1] {
                bins[i] += 1; break
            }
        }
        return Histogram(label: "Daily download volume", bins: labels, counts: bins, color: Tokens.good)
    }

    // MARK: Records

    private static func computeRecords(memSamples: [MemorySample], netSamples: [NetSample],
                                       batSamples: [BatteryReading], cleanupRows: [CleanupRecord]) -> [AnalyticsRecord] {
        var out: [AnalyticsRecord] = []

        if let peak = memSamples.max(by: { $0.u < $1.u }) {
            out.append(.init(
                icon: "memorychip.fill", label: "Peak memory used",
                value: "\(Int((Double(peak.u) * 100).rounded()))%",
                detail: relativeDate(peak.t), date: Date(timeIntervalSince1970: peak.t),
                color: Tokens.purple, target: .memory
            ))
        }
        if let peak = netSamples.max(by: { $0.downBps < $1.downBps }), peak.downBps > 0 {
            out.append(.init(
                icon: "arrow.down", label: "Peak download",
                value: LiveNetwork.bps(peak.downBps),
                detail: relativeDate(peak.t), date: Date(timeIntervalSince1970: peak.t),
                color: Tokens.good, target: .network
            ))
        }
        if let peakUp = netSamples.max(by: { $0.upBps < $1.upBps }), peakUp.upBps > 0 {
            out.append(.init(
                icon: "arrow.up", label: "Peak upload",
                value: LiveNetwork.bps(peakUp.upBps),
                detail: relativeDate(peakUp.t), date: Date(timeIntervalSince1970: peakUp.t),
                color: Tokens.catApps, target: .network
            ))
        }
        if !batSamples.isEmpty {
            // Longest charge stretch
            var bestStart: TimeInterval = 0, bestEnd: TimeInterval = 0
            var i = 0
            while i < batSamples.count {
                if batSamples[i].charging == 1 {
                    var j = i
                    while j < batSamples.count && batSamples[j].charging == 1 { j += 1 }
                    let a = batSamples[i].t, b = batSamples[max(j-1,i)].t
                    if (b - a) > (bestEnd - bestStart) { bestStart = a; bestEnd = b }
                    i = j
                } else { i += 1 }
            }
            if bestEnd > bestStart {
                let mins = Int((bestEnd - bestStart) / 60)
                out.append(.init(
                    icon: "bolt.fill", label: "Longest charge",
                    value: mins >= 60 ? "\(mins/60) hr \(mins%60) min" : "\(mins) min",
                    detail: relativeDate(bestStart), date: Date(timeIntervalSince1970: bestStart),
                    color: Tokens.good, target: .battery
                ))
            }
        }
        if let biggest = cleanupRows.max(by: { $0.bytes < $1.bytes }) {
            out.append(.init(
                icon: "sparkles", label: "Largest cleanup",
                value: ByteCountFormatter.string(fromByteCount: biggest.bytes, countStyle: .file),
                detail: "\(biggest.module.label) · \(relativeDate(biggest.t.timeIntervalSince1970))",
                date: biggest.t,
                color: Tokens.indigo, target: .dashboard
            ))
        }
        return out
    }

    private static func relativeDate(_ t: TimeInterval) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }

    // MARK: Prior-window comparisons

    private static func computeDeltas(
        memSamples: [MemorySample], previousMem: [MemorySample],
        netSamples: [NetSample], previousNet: [NetSample],
        storSamples: [StorageSample], previousStor: [StorageSample]
    ) -> [WoWDelta] {
        var out: [WoWDelta] = []

        if ObservationCoverage.canCompare(previous: previousMem.map(\.t), current: memSamples.map(\.t)),
           let priorPeak = previousMem.map({ Double($0.u) }).max(),
           let currentPeak = memSamples.map({ Double($0.u) }).max() {
            let delta = (currentPeak - priorPeak) * 100
            out.append(.init(
                label: "Memory peak", value: "\(Int((currentPeak * 100).rounded()))%",
                deltaText: String(format: "%+.1f pp vs prior window", delta),
                deltaPositiveIsBad: true,
                positive: delta >= 0,
                icon: "memorychip",
                color: delta > 5 ? Tokens.warn : delta < -5 ? Tokens.good : Tokens.text2,
                target: .memory
            ))
        }

        if ObservationCoverage.canCompare(previous: previousNet.map(\.t), current: netSamples.map(\.t)) {
            let priorBytes = estimatedNetworkBytes(previousNet)
            let currentBytes = estimatedNetworkBytes(netSamples)
            let pct = priorBytes > 0 ? (currentBytes - priorBytes) / priorBytes * 100 : nil
            out.append(.init(
                label: "Network volume",
                value: ByteCountFormatter.string(fromByteCount: Int64(currentBytes), countStyle: .file),
                deltaText: pct.map { String(format: "%+.0f%% vs prior window", $0) } ?? "Prior window had no traffic",
                deltaPositiveIsBad: false,
                positive: (pct ?? 0) >= 0,
                icon: "arrow.down",
                color: Tokens.catApps,
                target: .network
            ))
        }

        if ObservationCoverage.canCompare(previous: previousStor.map(\.t), current: storSamples.map(\.t)),
           let priorLast = previousStor.last,
           let currentLast = storSamples.last {
            let delta = currentLast.usedGB - priorLast.usedGB
            out.append(.init(
                label: "Disk used", value: String(format: "%.0f GB", currentLast.usedGB),
                deltaText: String(format: "%+.1f GB vs prior window", delta),
                deltaPositiveIsBad: true,
                positive: delta >= 0,
                icon: "internaldrive",
                color: delta > 5 ? Tokens.warn : Tokens.indigo,
                target: .storage
            ))
        }
        return out
    }

    private static func estimatedNetworkBytes(_ samples: [NetSample]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<samples.count {
            let elapsed = min(max(samples[index].t - samples[index - 1].t, 0), 60)
            total += (samples[index - 1].downBps + samples[index - 1].upBps) * elapsed
        }
        return total
    }

    // MARK: Cleanups

    private static func bucketCleanups(_ rows: [CleanupRecord]) -> [DayCleanup] {
        guard !rows.isEmpty else { return [] }
        let cal = Calendar(identifier: .gregorian)
        var byDay: [Date: [CleanupModule: Int64]] = [:]
        for r in rows {
            let day = cal.startOfDay(for: r.t)
            byDay[day, default: [:]][r.module, default: 0] += r.bytes
        }
        return byDay.keys.sorted().map { day in
            DayCleanup(day: day, perModule: byDay[day] ?? [:])
        }
    }

    // MARK: Sessions

    private static func computeSessions(memSamples: [MemorySample], netSamples: [NetSample]) -> [SessionDay] {
        // Combine memory + network sample timestamps as activity beacons.
        var ts = memSamples.map { $0.t } + netSamples.map { $0.t }
        ts.sort()
        guard !ts.isEmpty else { return [] }

        // A "session" is a stretch where consecutive samples are <600s apart.
        struct Session { var start: TimeInterval; var end: TimeInterval }
        var sessions: [Session] = []
        var cur = Session(start: ts[0], end: ts[0])
        for t in ts.dropFirst() {
            if t - cur.end <= 600 {
                cur.end = t
            } else {
                if cur.end > cur.start + 60 { sessions.append(cur) }
                cur = Session(start: t, end: t)
            }
        }
        if cur.end > cur.start + 60 { sessions.append(cur) }

        // Group by day
        let cal = Calendar(identifier: .gregorian)
        var daily: [Date: (count: Int, mins: Int)] = [:]
        for s in sessions {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: s.start))
            let mins = Int((s.end - s.start) / 60)
            let cur = daily[day] ?? (0, 0)
            daily[day] = (cur.count + 1, cur.mins + mins)
        }
        return daily.keys.sorted().map { d in
            SessionDay(day: d, sessionCount: daily[d]!.count, activeMinutes: daily[d]!.mins)
        }
    }

    // MARK: Summary

    private static func composeSummaryAndFacts(range: AnalyticsRange, snap: Snapshot,
                                               memCount: Int, netCount: Int, batCount: Int, storCount: Int)
    -> (summary: String, facts: [GroundedFact]) {
        if memCount + netCount + batCount + storCount == 0 {
            return ("Not enough data to summarize this window yet — let BloatMac collect samples for a while.",
                    [])
        }

        var facts = [GroundedFact(
            id: "coverage",
            text: "In the selected \(range.label) view, BloatMac has \(snap.coverage.summary) of observations."
        )]

        for (index, record) in snap.records.enumerated() {
            facts.append(.init(
                id: "record-\(index)",
                text: "\(record.label) was \(record.value) (\(record.detail))."
            ))
        }
        if snap.totalCleanedBytes > 0 {
            facts.append(.init(
                id: "trash",
                text: "BloatMac moved \(ByteCountFormatter.string(fromByteCount: snap.totalCleanedBytes, countStyle: .file)) to Trash in this selected window."
            ))
        }
        for (index, delta) in snap.deltas.enumerated() {
            facts.append(.init(
                id: "comparison-\(index)",
                text: "\(delta.label) was \(delta.value), \(delta.deltaText)."
            ))
        }
        if snap.totalActiveHours > 0 {
            facts.append(.init(
                id: "activity",
                text: String(format: "Observed activity totals %.1f hours across %d sessions in this selected window.",
                             snap.totalActiveHours, snap.sessions.reduce(0) { $0 + $1.sessionCount })
            ))
        }

        return (facts.prefix(4).map(\.text).joined(separator: " "), facts)
    }

    // MARK: Export

    static func exportCSV(table: ExportTable) -> String {
        let cutoff: TimeInterval = 0   // export everything
        switch table {
        case .network:
            let rows = readNetSQLite(since: cutoff)
            var s = "t,down_bps,up_bps,ping_ms\n"
            for r in rows { s += "\(r.t),\(r.downBps),\(r.upBps),\(r.pingMs)\n" }
            return s
        case .battery:
            let rows = readBatterySamples(since: cutoff)
            var s = "t,percent,charging,watts,voltage,amperage,temp,time_remaining\n"
            for r in rows { s += "\(r.t),\(r.percent),\(r.charging),\(r.watts),\(r.voltage),\(r.amperage),\(r.tempC),\(r.timeRemaining)\n" }
            return s
        case .storage:
            let rows = readStorageSamples(since: cutoff)
            var s = "t,used_gb,total_gb\n"
            for r in rows { s += "\(r.t),\(r.usedGB),\(r.totalGB)\n" }
            return s
        case .cleanups:
            let rows = CleanupLog.read(since: cutoff)
            var s = "t,module,item_count,bytes\n"
            for r in rows { s += "\(r.t.timeIntervalSince1970),\(r.module.rawValue),\(r.itemCount),\(r.bytes)\n" }
            return s
        }
    }
}
