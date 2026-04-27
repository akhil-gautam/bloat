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
        scanning = true
        items = []
        scannedDirs = 0
        let roots = Self.scanRoots.filter { FileManager.default.fileExists(atPath: $0) }
        totalDirs = roots.count
        let threshold = Int64(thresholdMB) * 1_000_000
        task = Task.detached(priority: .userInitiated) {
            for (i, path) in roots.enumerated() {
                if Task.isCancelled { break }
                await Self.scanRoot(path: path, threshold: threshold)
                await MainActor.run { LiveLargeFiles.shared.scannedDirs = i + 1 }
            }
            await MainActor.run {
                LiveLargeFiles.shared.scanning = false
                LiveLargeFiles.shared.items.sort { $0.sizeBytes > $1.sizeBytes }
                if LiveLargeFiles.shared.items.count > 500 {
                    LiveLargeFiles.shared.items = Array(LiveLargeFiles.shared.items.prefix(500))
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scanning = false
    }

    func remove(_ ids: Set<URL>) {
        items.removeAll { ids.contains($0.id) }
    }

    // MARK: - Worker

    nonisolated private static func scanRoot(path: String, threshold: Int64) async {
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
                                     errorHandler: { _, _ in true }) else { return }

        var batch: [LargeFileItem] = []
        let flushEvery = 25
        var seen = 0

        for case let item as URL in en {
            if Task.isCancelled { break }
            seen += 1
            // Skip walking into bundles (.app, .photoslibrary etc.) — count them as one item
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isPackage == true {
                en.skipDescendants()
                if let entry = makeItem(at: item, values: v, threshold: threshold) {
                    batch.append(entry)
                    if batch.count >= flushEvery {
                        let toFlush = batch; batch = []
                        await MainActor.run { LiveLargeFiles.shared.items.append(contentsOf: toFlush) }
                    }
                }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            if let entry = makeItem(at: item, values: v, threshold: threshold) {
                batch.append(entry)
                if batch.count >= flushEvery {
                    let toFlush = batch; batch = []
                    await MainActor.run { LiveLargeFiles.shared.items.append(contentsOf: toFlush) }
                }
            }
        }
        if !batch.isEmpty {
            let toFlush = batch
            await MainActor.run { LiveLargeFiles.shared.items.append(contentsOf: toFlush) }
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
        var trashed = 0
        var bytes: Int64 = 0
        for id in ids {
            let size = items.first(where: { $0.id == id })?.sizeBytes ?? 0
            do {
                try fm.trashItem(at: id, resultingItemURL: nil)
                trashed += 1
                bytes += size
            } catch {
                lastError = "Could not trash \(id.lastPathComponent): \(error.localizedDescription)"
            }
        }
        items.removeAll { ids.contains($0.id) }
        if trashed > 0 { CleanupLog.record(module: .largeFiles, itemCount: trashed, bytes: bytes) }
        return trashed
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
