import Foundation
import Combine
import SwiftUI

/// One-click orchestration over the existing real-detection modules.
/// Mirrors CleanMyMac's "Smart Care" flow: kicks off scans across
/// storage / caches / duplicates / startup, gathers the results, and
/// surfaces a consolidated reclaimable-bytes total + a list of
/// actionable recommendations the user can drill into.
///
/// All work is done on the modules' existing detached scan tasks — this
/// type just sequences them, watches their `scanning` flags, and
/// computes a result struct when everything has settled.
@MainActor
final class LiveSmartCare: ObservableObject {
    static let shared = LiveSmartCare()

    enum Step: String, CaseIterable {
        case idle, storage, caches, duplicates, startup, memory, done

        /// Order in the scan pipeline. `idle` and `done` are sentinels and
        /// don't have a place in the rendered step list.
        static var pipeline: [Step] { [.storage, .caches, .duplicates, .startup, .memory] }

        var label: String {
            switch self {
            case .idle:       return "Ready"
            case .storage:    return "Storage"
            case .caches:     return "Caches & downloads"
            case .duplicates: return "Duplicates"
            case .startup:    return "Startup items"
            case .memory:     return "Memory pressure"
            case .done:       return "Done"
            }
        }

        /// Verb-form copy used in the centered hero text while the step is
        /// running. The label form above is for the step list.
        var runningCopy: String {
            switch self {
            case .idle:       return "Ready"
            case .storage:    return "Refreshing storage…"
            case .caches:     return "Walking caches & downloads…"
            case .duplicates: return "Hashing duplicate candidates…"
            case .startup:    return "Reviewing launch agents…"
            case .memory:     return "Sampling memory…"
            case .done:       return "Done"
            }
        }

        var icon: String {
            switch self {
            case .idle, .done: return "sparkles"
            case .storage:     return "internaldrive"
            case .caches:      return "tray.full"
            case .duplicates:  return "doc.on.doc"
            case .startup:     return "powerplug"
            case .memory:      return "memorychip"
            }
        }
    }

    enum RecModule: String { case caches, downloads, duplicates, startup, memory, storage }

    struct Recommendation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let actionLabel: String
        let module: RecModule
        let bytes: Int64
    }

    struct Result {
        let cleanableBytes: Int64
        let cacheBytes: Int64
        let downloadBytes: Int64
        let duplicateBytes: Int64
        let flaggedStartup: Int
        let memoryPressure: MemoryPressure
        let storagePct: Double
        let recommendations: [Recommendation]
        let runAt: Date
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var running: Bool = false
    @Published private(set) var result: Result? = nil
    @Published private(set) var lastError: String? = nil

    private var runGeneration = ScanGeneration()

    private init() {}

    /// Run the full sequence. Cooperatively cancellable via `cancel()`.
    func run() async {
        guard !running else { return }
        let generation = runGeneration.next()
        running = true; lastError = nil; step = .idle; progress = 0
        defer {
            if runGeneration.accepts(generation) {
                running = false
                if Task.isCancelled {
                    step = .idle
                    progress = 0
                }
            }
        }

        // Step 1 — Storage refresh. Cheap; just bumps publishers.
        step = .storage
        LiveStorage.shared.refresh()
        guard await waitWhile({ LiveStorage.shared.calculating }, generation: generation) else { return }
        progress = 0.20

        // Step 2 — Downloads + caches scan.
        step = .caches
        LiveDownloadsCache.shared.scan()
        guard await waitWhile({ LiveDownloadsCache.shared.scanning }, generation: generation) else { return }
        progress = 0.50

        // Step 3 — Duplicates scan. This is the slow one (hashing). Smart Care
        // accepts whatever the scanner produces in a reasonable wall-clock
        // window — the scanner caps results internally.
        step = .duplicates
        LiveDuplicates.shared.scan()
        guard await waitWhile({ LiveDuplicates.shared.scanning }, generation: generation) else { return }
        progress = 0.80

        // Step 4 — Startup item rescan.
        step = .startup
        LiveStartup.shared.rescan()
        guard await waitWhile({ LiveStartup.shared.scanning }, generation: generation) else { return }
        progress = 0.95

        // Step 5 — Memory pressure read (LiveMemory ticks itself; just snapshot).
        step = .memory
        progress = 1.0

        result = computeResult()
        step = .done
    }

    func cancel() {
        _ = runGeneration.next()
        LiveDownloadsCache.shared.cancel()
        LiveDuplicates.shared.cancel()
        LiveStartup.shared.cancel()
        running = false
        step = .idle
        progress = 0
    }

    // MARK: - Helpers

    private func waitWhile(_ predicate: @escaping () -> Bool, generation: Int) async -> Bool {
        // Poll at 250ms — the scans tick their own progress publishers,
        // we just need to know when they've fully settled.
        guard !Task.isCancelled, runGeneration.accepts(generation) else { return false }
        while predicate() {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return false
            }
            if Task.isCancelled || !runGeneration.accepts(generation) { return false }
        }
        return !Task.isCancelled && runGeneration.accepts(generation)
    }

    private func computeResult() -> Result {
        let dc = LiveDownloadsCache.shared
        let oldDownloads = dc.downloads.filter { $0.ageDays >= 30 }
        let safeCaches = dc.caches.filter(\.safeToClean)
        let downloads: Int64 = oldDownloads.reduce(0) { $0 + $1.sizeBytes }
        let caches: Int64 = safeCaches.reduce(0) { $0 + $1.sizeBytes }

        let dup = LiveDuplicates.shared
        let countedRoots = oldDownloads.map(\.url) + safeCaches.map(\.url)
        let countedDuplicateURLs = Set(dup.exact.flatMap(\.items).compactMap { item in
            CleanupSafety.isSameOrDescendant(item.url, of: countedRoots) ? item.url : nil
        })
        let dupBytes = dup.exactPotentialRecoverable(excluding: countedDuplicateURLs)

        let stor = LiveStorage.shared
        let pct = stor.totalGB > 0 ? stor.usedGB / stor.totalGB : 0

        let flagged = LiveStartup.shared.items.filter { $0.risk == .flagged }.count
        let pressure = LiveMemory.shared.pressure

        let cleanable = caches + downloads + dupBytes

        var recs: [Recommendation] = []
        if pct > 0.85 {
            recs.append(.init(
                title: "Storage above 85%",
                detail: "Free at least 10 GB to keep macOS healthy",
                actionLabel: "Open Storage",
                module: .storage,
                bytes: 0
            ))
        }
        if caches >= 200_000_000 {
            recs.append(.init(
                title: "Empty app caches",
                detail: "\(formatBytes(caches)) safe to review across \(safeCaches.count) apps",
                actionLabel: "Open Caches",
                module: .caches,
                bytes: caches
            ))
        }
        if downloads >= 200_000_000 {
            recs.append(.init(
                title: "Clear old downloads",
                detail: "\(formatBytes(downloads)) older than 30 days in ~/Downloads",
                actionLabel: "Open Downloads",
                module: .downloads,
                bytes: downloads
            ))
        }
        if dupBytes >= 100_000_000 {
            recs.append(.init(
                title: "Resolve duplicates",
                detail: "\(formatBytes(dupBytes)) across \(dup.exact.count) verified exact groups",
                actionLabel: "Open Duplicates",
                module: .duplicates,
                bytes: dupBytes
            ))
        }
        if flagged > 0 {
            recs.append(.init(
                title: "Review startup items",
                detail: "\(flagged) flagged for risk",
                actionLabel: "Open Startup",
                module: .startup,
                bytes: 0
            ))
        }
        if pressure != .normal {
            recs.append(.init(
                title: "Memory pressure: \(pressureLabel(pressure))",
                detail: "Quit heavy apps to recover",
                actionLabel: "Open Memory",
                module: .memory,
                bytes: 0
            ))
        }

        return Result(
            cleanableBytes: cleanable,
            cacheBytes: caches,
            downloadBytes: downloads,
            duplicateBytes: dupBytes,
            flaggedStartup: flagged,
            memoryPressure: pressure,
            storagePct: pct,
            recommendations: recs,
            runAt: Date()
        )
    }

    private func pressureLabel(_ p: MemoryPressure) -> String {
        switch p {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
