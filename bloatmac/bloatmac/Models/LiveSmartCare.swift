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
        var label: String {
            switch self {
            case .idle:       return "Ready"
            case .storage:    return "Refreshing storage…"
            case .caches:     return "Scanning caches & downloads…"
            case .duplicates: return "Hashing duplicates…"
            case .startup:    return "Reviewing startup items…"
            case .memory:     return "Sampling memory…"
            case .done:       return "Done"
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

    private init() {}

    /// Run the full sequence. Cooperatively cancellable via `cancel()`.
    func run() async {
        guard !running else { return }
        running = true; lastError = nil; step = .idle; progress = 0

        // Step 1 — Storage refresh. Cheap; just bumps publishers.
        step = .storage
        LiveStorage.shared.refresh()
        await waitWhile { LiveStorage.shared.calculating }
        progress = 0.20

        // Step 2 — Downloads + caches scan.
        step = .caches
        LiveDownloadsCache.shared.scan()
        await waitWhile { LiveDownloadsCache.shared.scanning }
        progress = 0.50

        // Step 3 — Duplicates scan. This is the slow one (hashing). Smart Care
        // accepts whatever the scanner produces in a reasonable wall-clock
        // window — the scanner caps results internally.
        step = .duplicates
        LiveDuplicates.shared.scan()
        await waitWhile { LiveDuplicates.shared.scanning }
        // Auto-mark duplicates beyond the newest copy as not-kept so our
        // cleanable estimate matches what `resolveAll()` would actually trash.
        LiveDuplicates.shared.smartPick()
        progress = 0.80

        // Step 4 — Startup item rescan.
        step = .startup
        LiveStartup.shared.rescan()
        await waitWhile { LiveStartup.shared.scanning }
        progress = 0.95

        // Step 5 — Memory pressure read (LiveMemory ticks itself; just snapshot).
        step = .memory
        progress = 1.0

        result = computeResult()
        step = .done
        running = false
    }

    func cancel() {
        LiveDownloadsCache.shared.cancel()
        LiveDuplicates.shared.cancel()
        running = false
        step = .idle
        progress = 0
    }

    // MARK: - Helpers

    private func waitWhile(_ predicate: @escaping () -> Bool) async {
        // Poll at 250ms — the scans tick their own progress publishers,
        // we just need to know when they've fully settled.
        while predicate() {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
    }

    private func computeResult() -> Result {
        let dc = LiveDownloadsCache.shared
        let downloads: Int64 = dc.downloads.reduce(0) { $0 + $1.sizeBytes }
        let caches: Int64 = dc.caches.reduce(0) { $0 + $1.sizeBytes }

        let dup = LiveDuplicates.shared
        let dupBytes: Int64 = (dup.exact + dup.similar).reduce(Int64(0)) { acc, group in
            // After smartPick(), keep == false items are slated for trash.
            acc + group.items.reduce(Int64(0)) { $0 + ($1.keep ? 0 : $1.sizeBytes) }
        }

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
                detail: "\(formatBytes(caches)) reclaimable across \(dc.caches.count) apps",
                actionLabel: "Open Caches",
                module: .caches,
                bytes: caches
            ))
        }
        if downloads >= 200_000_000 {
            recs.append(.init(
                title: "Clear old downloads",
                detail: "\(formatBytes(downloads)) sitting in ~/Downloads",
                actionLabel: "Open Downloads",
                module: .downloads,
                bytes: downloads
            ))
        }
        if dupBytes >= 100_000_000 {
            recs.append(.init(
                title: "Resolve duplicates",
                detail: "\(formatBytes(dupBytes)) duplicated across \(dup.exact.count + dup.similar.count) groups",
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
