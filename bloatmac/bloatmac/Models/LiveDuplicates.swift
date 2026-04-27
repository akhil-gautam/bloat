import SwiftUI
import Foundation
import CryptoKit
import Vision
import UniformTypeIdentifiers
import QuickLookThumbnailing
import AppKit
import Combine

// MARK: - Models

enum DupKind: String { case exact, similarImage }

struct DupItem: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    let name: String
    let parent: String
    let sizeBytes: Int64
    let modified: Date?
    var keep: Bool = true
    /// For visual matches only: distance from the cluster representative (0 = identical, ~0.2 ≈ near-dup)
    var visualDistance: Float? = nil
}

struct DupGroup: Identifiable, Hashable {
    let id: String
    let kind: DupKind
    var items: [DupItem]
    /// Bytes that would be freed if all unkept items in this group are trashed.
    var recoverableBytes: Int64 {
        items.filter { !$0.keep }.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
    var totalBytes: Int64 { items.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

// MARK: - Singleton

@MainActor
final class LiveDuplicates: ObservableObject {
    static let shared = LiveDuplicates()

    @Published private(set) var exact: [DupGroup] = []
    @Published private(set) var similar: [DupGroup] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil

    var totalGroups: Int { exact.count + similar.count }
    var totalRecoverable: Int64 {
        (exact + similar).reduce(0) { $0 + $1.recoverableBytes }
    }
    var totalRecoverableText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: totalRecoverable)
    }

    private var task: Task<Void, Never>? = nil

    private static let scanRoots: [String] = {
        let h = NSHomeDirectory()
        return ["\(h)/Documents", "\(h)/Downloads", "\(h)/Desktop",
                "\(h)/Pictures", "\(h)/Movies", "\(h)/Music"]
    }()

    private init() {}

    func startIfNeeded() {
        if exact.isEmpty && similar.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true
        phase = "Indexing files…"
        progress = 0
        exact = []
        similar = []
        task = Task.detached(priority: .userInitiated) {
            await Self.runScan()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scanning = false
    }

    // MARK: - Resolution

    func toggleKeep(groupID: String, itemID: URL) {
        if let gi = exact.firstIndex(where: { $0.id == groupID }),
           let ii = exact[gi].items.firstIndex(where: { $0.id == itemID }) {
            exact[gi].items[ii].keep.toggle()
            return
        }
        if let gi = similar.firstIndex(where: { $0.id == groupID }),
           let ii = similar[gi].items.firstIndex(where: { $0.id == itemID }) {
            similar[gi].items[ii].keep.toggle()
        }
    }

    /// "Smart pick" — uses heuristics tuned to each duplicate kind.
    func smartPick() {
        for gi in exact.indices {
            // Exact: keep the most-recently modified copy (likely the "current" file)
            let newestID = exact[gi].items
                .max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }?.id
            for ii in exact[gi].items.indices {
                exact[gi].items[ii].keep = (exact[gi].items[ii].id == newestID)
            }
        }
        for gi in similar.indices {
            // Similar images: keep the largest file (highest fidelity / resolution)
            let largestID = similar[gi].items.max { $0.sizeBytes < $1.sizeBytes }?.id
            for ii in similar[gi].items.indices {
                similar[gi].items[ii].keep = (similar[gi].items[ii].id == largestID)
            }
        }
    }

    /// Trash every item with `keep == false` and prune now-empty groups.
    @discardableResult
    func resolveAll() -> Int {
        let fm = FileManager.default
        var trashed = 0
        var bytes: Int64 = 0
        var failures: [String] = []
        let candidates: [(URL, Int64)] = (exact + similar).flatMap { g in
            g.items.filter { !$0.keep }.map { ($0.id, $0.sizeBytes) }
        }
        for (url, size) in candidates {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
                bytes += size
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        exact = prune(exact)
        similar = prune(similar)
        if !failures.isEmpty { lastError = failures.first }
        if trashed > 0 { CleanupLog.record(module: .duplicates, itemCount: trashed, bytes: bytes) }
        return trashed
    }

    private func prune(_ groups: [DupGroup]) -> [DupGroup] {
        groups.compactMap { g in
            let remaining = g.items.filter { _ in true }
                .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            return remaining.count >= 2 ? DupGroup(id: g.id, kind: g.kind, items: remaining) : nil
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Scan implementation (background actor-isolated to nonisolated workers)

    nonisolated private static func runScan() async {
        // 1. Walk all roots
        await Self.update(phase: "Indexing files…", progress: 0)
        var allFiles: [(URL, Int64)] = []
        for path in scanRoots where FileManager.default.fileExists(atPath: path) {
            if Task.isCancelled { return }
            allFiles.append(contentsOf: walk(path: path))
        }

        // 2. Bucket by exact byte size — only buckets with ≥2 entries are duplicate candidates.
        await Self.update(phase: "Hashing candidates…", progress: 0.05)
        var byBytes: [Int64: [URL]] = [:]
        for (u, s) in allFiles where s >= 4096 {
            byBytes[s, default: []].append(u)
        }
        let candidates: [URL] = byBytes.values.filter { $0.count > 1 }.flatMap { $0 }

        // 3. Hash each candidate, group by hash → exact-duplicate groups.
        var byHash: [String: [URL]] = [:]
        let total = max(1, candidates.count)
        for (i, url) in candidates.enumerated() {
            if Task.isCancelled { return }
            if let h = quickHash(url: url) {
                byHash[h, default: []].append(url)
            }
            if i % 20 == 0 {
                await Self.update(phase: "Hashing candidates…", progress: 0.05 + Double(i) / Double(total) * 0.45)
            }
        }
        let exactGroups: [DupGroup] = byHash.compactMap { (hash, urls) -> DupGroup? in
            guard urls.count > 1 else { return nil }
            var items = urls.map { url -> DupItem in
                DupItem(id: url, name: url.lastPathComponent,
                        parent: prettyParent(url),
                        sizeBytes: fileSize(at: url),
                        modified: modDate(at: url))
            }
            if let newestIdx = items.indices.max(by: { (items[$0].modified ?? .distantPast) < (items[$1].modified ?? .distantPast) }) {
                for i in items.indices { items[i].keep = (i == newestIdx) }
            }
            return DupGroup(id: "ex-\(hash)", kind: .exact, items: items)
        }.sorted { $0.recoverableBytes > $1.recoverableBytes }

        await Self.publishExact(exactGroups)

        // 4. Find visually-similar images via Vision feature prints.
        if Task.isCancelled { return }
        await Self.update(phase: "Analyzing images with Vision…", progress: 0.55)
        let imageURLs: [URL] = allFiles.compactMap { (u, _) -> URL? in
            guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return nil }
            return t.conforms(to: .image) ? u : nil
        }
        let imageGroups = await clusterSimilarImages(urls: imageURLs)

        await Self.publishSimilar(imageGroups)
        await Self.finishScan()
    }

    nonisolated private static func walk(path: String) -> [(URL, Int64)] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isPackageKey]
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return [] }
        var out: [(URL, Int64)] = []
        for case let item as URL in en {
            if Task.isCancelled { break }
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile != true { continue }
            if let s = v?.fileSize, s > 0 {
                out.append((item, Int64(s)))
            }
        }
        return out
    }

    /// SHA-256 over the whole file (small files) or first/middle/last 1 MB sample (large files).
    /// Sampling protects throughput on multi-GB videos at a negligible false-positive risk.
    nonisolated private static func quickHash(url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let total = try? fh.seekToEnd() else { return nil }
        try? fh.seek(toOffset: 0)
        var hasher = SHA256()
        var sizeLE = total.littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(data: Data($0)) }

        let chunk = 1_048_576
        if total <= 50_000_000 {
            while let data = try? fh.read(upToCount: chunk), !data.isEmpty {
                hasher.update(data: data)
            }
        } else {
            // first MB
            try? fh.seek(toOffset: 0)
            if let d = try? fh.read(upToCount: chunk) { hasher.update(data: d) }
            // middle MB
            try? fh.seek(toOffset: total / 2)
            if let d = try? fh.read(upToCount: chunk) { hasher.update(data: d) }
            // last MB
            try? fh.seek(toOffset: max(0, total - UInt64(chunk)))
            if let d = try? fh.read(upToCount: chunk) { hasher.update(data: d) }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func clusterSimilarImages(urls: [URL]) async -> [DupGroup] {
        var prints: [(URL, VNFeaturePrintObservation)] = []
        let total = max(1, urls.count)
        for (i, url) in urls.enumerated() {
            if Task.isCancelled { break }
            if let fp = featurePrint(for: url) {
                prints.append((url, fp))
            }
            if i % 10 == 0 {
                await Self.update(phase: "Analyzing images with Vision… (\(i + 1)/\(urls.count))",
                                  progress: 0.55 + Double(i) / Double(total) * 0.4)
            }
        }
        if Task.isCancelled { return [] }

        // Greedy single-link clustering against cluster representatives.
        // Threshold tuned for "very similar" — Vision distances usually run 0.0 (identical) → 1.5 (unrelated).
        let threshold: Float = 0.18
        struct Cluster { var rep: VNFeaturePrintObservation; var entries: [(URL, Float)] }
        var clusters: [Cluster] = []
        for (url, fp) in prints {
            var attached = false
            for ci in clusters.indices {
                var d: Float = 0
                if (try? clusters[ci].rep.computeDistance(&d, to: fp)) != nil, d < threshold {
                    clusters[ci].entries.append((url, d))
                    attached = true
                    break
                }
            }
            if !attached {
                clusters.append(Cluster(rep: fp, entries: [(url, 0)]))
            }
        }
        let groups: [DupGroup] = clusters.compactMap { c in
            guard c.entries.count > 1 else { return nil }
            var items = c.entries.map { (url, dist) -> DupItem in
                var it = DupItem(id: url, name: url.lastPathComponent,
                                 parent: prettyParent(url),
                                 sizeBytes: fileSize(at: url),
                                 modified: modDate(at: url))
                it.visualDistance = dist
                return it
            }
            // Default: keep the largest file (likely highest fidelity)
            if let largestIdx = items.indices.max(by: { items[$0].sizeBytes < items[$1].sizeBytes }) {
                for i in items.indices { items[i].keep = (i == largestIdx) }
            }
            items.sort { $0.sizeBytes > $1.sizeBytes }
            let id = "sim-" + (c.entries.first?.0.path ?? UUID().uuidString)
            return DupGroup(id: id, kind: .similarImage, items: items)
        }.sorted { $0.recoverableBytes > $1.recoverableBytes }
        return groups
    }

    nonisolated private static func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 224,
              ] as CFDictionary)
        else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
            return req.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    nonisolated private static func modDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    nonisolated private static func prettyParent(_ url: URL) -> String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    nonisolated private static func update(phase: String, progress: Double) async {
        await MainActor.run {
            LiveDuplicates.shared.phase = phase
            LiveDuplicates.shared.progress = progress
        }
    }
    nonisolated private static func publishExact(_ groups: [DupGroup]) async {
        await MainActor.run { LiveDuplicates.shared.exact = groups }
    }
    nonisolated private static func publishSimilar(_ groups: [DupGroup]) async {
        await MainActor.run { LiveDuplicates.shared.similar = groups }
    }
    nonisolated private static func finishScan() async {
        await MainActor.run {
            LiveDuplicates.shared.scanning = false
            LiveDuplicates.shared.phase = "Done"
            LiveDuplicates.shared.progress = 1
        }
    }
}

// MARK: - QuickLook thumbnail view

struct QLThumb: View {
    let url: URL
    var size: CGFloat = 56
    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(Tokens.text3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            let req = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .all
            )
            do {
                let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
                await MainActor.run { self.image = rep.nsImage }
            } catch {
                // swallow — fall back to placeholder
            }
        }
    }
}
