import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Combine

struct LargeFileItem: Identifiable, Hashable {
    let id: URL                  // file URL — guaranteed unique
    var url: URL { id }
    let name: String
    let parent: String
    let sizeBytes: Int64
    let kind: String
    let modified: Date?
    let accessed: Date?

    var sizeText: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: sizeBytes)
    }
    var ageText: String {
        guard let d = accessed ?? modified else { return "—" }
        let delta = Date().timeIntervalSince(d)
        let days = Int(delta / 86400)
        if days < 1   { return "today" }
        if days < 14  { return "\(days)d ago" }
        if days < 60  { return "\(days/7)w ago" }
        if days < 730 { return "\(days/30)mo ago" }
        return "\(days/365)y ago"
    }
    var ageDays: Int {
        guard let d = accessed ?? modified else { return 0 }
        return Int(Date().timeIntervalSince(d) / 86400)
    }
}

@MainActor
final class LiveLargeFiles: ObservableObject {
    static let shared = LiveLargeFiles()

    @Published private(set) var items: [LargeFileItem] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var scannedDirs: Int = 0
    @Published private(set) var totalDirs: Int = 0
    @Published var thresholdMB: Int = 100   // anything ≥ this counts as "large"
    @Published private(set) var lastError: String? = nil

    private var task: Task<Void, Never>? = nil
    private var scanGeneration = ScanGeneration()

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var totalSizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: totalBytes)
    }

    private static let scanRoots: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Movies",
            "\(home)/Pictures",
            "\(home)/Music",
            "\(home)/Developer",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "/Applications",
        ]
    }()

    private init() {}

    func startIfNeeded() {
        if items.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        let generation = scanGeneration.next()
        scanning = true
        items = []
        scannedDirs = 0
        let roots = Self.scanRoots.filter { FileManager.default.fileExists(atPath: $0) }
        totalDirs = roots.count
        let threshold = Int64(thresholdMB) * 1_000_000
        task = Task.detached(priority: .userInitiated) {
            for (i, path) in roots.enumerated() {
                if Task.isCancelled { return }
                await Self.scanRoot(path: path, threshold: threshold, generation: generation)
                await MainActor.run {
                    guard LiveLargeFiles.shared.scanGeneration.accepts(generation) else { return }
                    LiveLargeFiles.shared.scannedDirs = i + 1
                }
            }
            await MainActor.run {
                let live = LiveLargeFiles.shared
                guard live.scanGeneration.accepts(generation) else { return }
                live.scanning = false
                live.task = nil
                live.items.sort { $0.sizeBytes > $1.sizeBytes }
                if live.items.count > 500 {
                    live.items = Array(live.items.prefix(500))
                }
            }
        }
    }

    func cancel() {
        _ = scanGeneration.next()
        task?.cancel()
        task = nil
        scanning = false
    }

    // MARK: - Worker

    nonisolated private static func scanRoot(path: String, threshold: Int64, generation: Int) async {
        let items = scanRootItems(path: path, threshold: threshold)
        guard !Task.isCancelled, !items.isEmpty else { return }
        await publish(items, generation: generation)
    }

    nonisolated private static func scanRootItems(path: String, threshold: Int64) -> [LargeFileItem] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .isRegularFileKey, .isPackageKey,
            .contentModificationDateKey, .contentAccessDateKey,
            .typeIdentifierKey, .localizedTypeDescriptionKey, .nameKey,
        ]
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return [] }

        var items: [LargeFileItem] = []

        for case let item as URL in en {
            if Task.isCancelled { break }
            // Skip walking into bundles (.app, .photoslibrary etc.) — count them as one item
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isPackage == true {
                en.skipDescendants()
                if let entry = makeItem(at: item, values: v, threshold: threshold) {
                    items.append(entry)
                }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            if let entry = makeItem(at: item, values: v, threshold: threshold) {
                items.append(entry)
            }
        }
        return items
    }

    nonisolated private static func publish(_ items: [LargeFileItem], generation: Int) async {
        await MainActor.run {
            let live = LiveLargeFiles.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.items.append(contentsOf: items)
        }
    }

    nonisolated private static func makeItem(at url: URL, values: URLResourceValues?, threshold: Int64) -> LargeFileItem? {
        let bytes: Int64
        if let s = values?.totalFileAllocatedSize { bytes = Int64(s) }
        else if let s = values?.fileAllocatedSize { bytes = Int64(s) }
        else if let s = values?.fileSize          { bytes = Int64(s) }
        else { return nil }
        guard bytes >= threshold else { return nil }

        let name = values?.name ?? url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let kind: String
        if let desc = values?.localizedTypeDescription, !desc.isEmpty { kind = desc }
        else if let typeId = values?.typeIdentifier, let t = UTType(typeId), let l = t.localizedDescription { kind = l }
        else { kind = url.pathExtension.uppercased().isEmpty ? "File" : url.pathExtension.uppercased() }

        return LargeFileItem(
            id: url, name: name, parent: parent, sizeBytes: bytes, kind: kind,
            modified: values?.contentModificationDate,
            accessed: values?.contentAccessDate
        )
    }

    // MARK: - Actions

    @discardableResult
    func moveToTrash(_ ids: Set<URL>) -> Int {
        let fm = FileManager.default
        lastError = nil
        let candidates = items.filter { ids.contains($0.id) }
            .map { CleanupCandidate(id: $0.id, url: $0.url, bytes: $0.sizeBytes) }
        let outcome = CleanupSafety.performTrash(candidates) {
            try fm.trashItem(at: $0, resultingItemURL: nil)
        }
        items.removeAll { outcome.succeeded.contains($0.id) }
        if !outcome.failures.isEmpty { lastError = outcome.failures.joined(separator: "\n") }
        if !outcome.succeeded.isEmpty {
            CleanupLog.record(module: .largeFiles, itemCount: outcome.succeeded.count, bytes: outcome.bytes)
        }
        return outcome.succeeded.count
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
