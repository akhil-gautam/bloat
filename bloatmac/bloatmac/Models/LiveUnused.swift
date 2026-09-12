import SwiftUI
import Foundation
import CoreServices
import AppKit
import Combine

enum UnusedKind: String { case app, folder, file }

struct UnusedEntry: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    let kind: UnusedKind
    let name: String
    let parent: String
    let sizeBytes: Int64
    let lastUsed: Date?
    let modified: Date?

    var ageDays: Int {
        guard let d = lastUsed ?? modified else { return Int.max }
        return Int(Date().timeIntervalSince(d) / 86400)
    }
    var ageText: String {
        guard let _ = lastUsed ?? modified else { return "Never used" }
        let d = ageDays
        if d < 30 { return "\(d)d ago" }
        if d < 365 { return "\(d/30)mo ago" }
        return "\(d/365)y ago"
    }
    var sizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: sizeBytes)
    }
}

@MainActor
final class LiveUnused: ObservableObject {
    static let shared = LiveUnused()

    @Published private(set) var apps: [UnusedEntry] = []
    @Published private(set) var files: [UnusedEntry] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published var thresholdDays: Int = 180
    @Published private(set) var lastError: String? = nil

    var totalCount: Int { apps.count + files.count }
    var totalBytes: Int64 { (apps + files).reduce(0) { $0 + $1.sizeBytes } }
    var totalText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: totalBytes)
    }

    private var task: Task<Void, Never>? = nil
    private var scanGeneration = ScanGeneration()

    private init() {}

    func startIfNeeded() {
        if apps.isEmpty && files.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        let generation = scanGeneration.next()
        scanning = true; apps = []; files = []
        phase = "Scanning installed apps…"; progress = 0
        let threshold = thresholdDays
        task = Task.detached(priority: .userInitiated) {
            await Self.runScan(thresholdDays: threshold, generation: generation)
        }
    }

    func cancel() {
        _ = scanGeneration.next()
        task?.cancel(); task = nil; scanning = false
    }

    @discardableResult
    func moveToTrash(_ ids: Set<URL>) -> Int {
        let fm = FileManager.default
        lastError = nil
        let candidates = (apps + files).filter { ids.contains($0.id) }
            .map { CleanupCandidate(id: $0.id, url: $0.url, bytes: $0.sizeBytes) }
        let outcome = CleanupSafety.performTrash(candidates) {
            try fm.trashItem(at: $0, resultingItemURL: nil)
        }
        apps.removeAll { outcome.succeeded.contains($0.id) }
        files.removeAll { outcome.succeeded.contains($0.id) }
        if !outcome.failures.isEmpty { lastError = outcome.failures.joined(separator: "\n") }
        if !outcome.succeeded.isEmpty {
            CleanupLog.record(module: .unused, itemCount: outcome.succeeded.count, bytes: outcome.bytes)
        }
        return outcome.succeeded.count
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Scan

    nonisolated private static func runScan(thresholdDays: Int, generation: Int) async {
        let cutoff = Date().addingTimeInterval(-Double(thresholdDays) * 86400)
        await update(phase: "Scanning installed apps…", progress: 0.05, generation: generation)
        let appRoots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        var unusedApps: [UnusedEntry] = []
        for root in appRoots where FileManager.default.fileExists(atPath: root) {
            if Task.isCancelled { return }
            unusedApps.append(contentsOf: scanApps(in: root, cutoff: cutoff))
        }
        unusedApps.sort { $0.sizeBytes > $1.sizeBytes }
        await publishApps(unusedApps, generation: generation)
        await update(phase: "Scanning files & folders…", progress: 0.4, generation: generation)

        let userRoots = [
            "\(NSHomeDirectory())/Documents",
            "\(NSHomeDirectory())/Downloads",
            "\(NSHomeDirectory())/Desktop",
            "\(NSHomeDirectory())/Movies",
            "\(NSHomeDirectory())/Pictures",
        ]
        var unusedFiles: [UnusedEntry] = []
        let total = max(1, userRoots.count)
        for (i, root) in userRoots.enumerated() {
            if Task.isCancelled { return }
            if FileManager.default.fileExists(atPath: root) {
                unusedFiles.append(contentsOf: scanFolder(at: root, cutoff: cutoff))
            }
            await update(phase: "Scanning files & folders…",
                         progress: 0.4 + Double(i + 1) / Double(total) * 0.55,
                         generation: generation)
        }
        unusedFiles.sort { $0.sizeBytes > $1.sizeBytes }
        await publishFiles(unusedFiles, generation: generation)
        await finish(generation: generation)
    }

    nonisolated private static func scanApps(in root: String, cutoff: Date) -> [UnusedEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [UnusedEntry] = []
        for entry in entries where entry.hasSuffix(".app") {
            let url = URL(fileURLWithPath: "\(root)/\(entry)")
            let lastUsed = spotlightLastUsedDate(for: url) ?? contentAccessDate(at: url)
            let mod = modDate(at: url)
            // No usage signal at all = too risky to flag (could be system app)
            guard let signal = lastUsed ?? mod else { continue }
            guard signal < cutoff else { continue }
            let size = directorySize(at: url)
            guard size >= 5_000_000 else { continue }   // skip tiny stubs
            out.append(UnusedEntry(
                id: url, kind: .app,
                name: entry.replacingOccurrences(of: ".app", with: ""),
                parent: prettyPath(url.deletingLastPathComponent()),
                sizeBytes: size, lastUsed: lastUsed, modified: mod
            ))
        }
        return out
    }

    nonisolated private static func scanFolder(at root: String, cutoff: Date) -> [UnusedEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [UnusedEntry] = []
        for entry in entries where !entry.hasPrefix(".") {
            let url = URL(fileURLWithPath: "\(root)/\(entry)")
            let v = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey,
                .contentAccessDateKey, .contentModificationDateKey, .fileSizeKey
            ])
            let isDir = v?.isDirectory ?? false
            let access = v?.contentAccessDate
            let mod = v?.contentModificationDate
            guard let signal = access ?? mod else { continue }
            guard signal < cutoff else { continue }

            let size: Int64
            if isDir { size = directorySize(at: url) }
            else { size = Int64(v?.fileSize ?? 0) }
            guard size >= 50_000_000 else { continue }   // only show ≥50 MB

            out.append(UnusedEntry(
                id: url,
                kind: isDir ? .folder : .file,
                name: entry,
                parent: prettyPath(url.deletingLastPathComponent()),
                sizeBytes: size, lastUsed: access, modified: mod
            ))
        }
        return out
    }

    nonisolated private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    nonisolated private static func contentAccessDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }
    nonisolated private static func modDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let en = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }) else { return 0 }
        for case let item as URL in en {
            if Task.isCancelled { break }
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                if let s = v?.totalFileAllocatedSize { total += Int64(s) }
                else if let s = v?.fileSize { total += Int64(s) }
            }
        }
        return total
    }
    nonisolated private static func prettyPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    nonisolated private static func update(phase: String, progress: Double, generation: Int) async {
        await MainActor.run {
            let live = LiveUnused.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.phase = phase
            live.progress = progress
        }
    }
    nonisolated private static func publishApps(_ a: [UnusedEntry], generation: Int) async {
        await MainActor.run {
            let live = LiveUnused.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.apps = a
        }
    }
    nonisolated private static func publishFiles(_ f: [UnusedEntry], generation: Int) async {
        await MainActor.run {
            let live = LiveUnused.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.files = f
        }
    }
    nonisolated private static func finish(generation: Int) async {
        await MainActor.run {
            let live = LiveUnused.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.scanning = false
            live.task = nil
            live.phase = "Done"
            live.progress = 1
        }
    }
}
