import SwiftUI
import Foundation
import Combine

struct LiveCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let size: Double  // GB (decimal, matching System Settings / Finder)
    var status: Status = .calculated
    var incomplete: Bool = false
    enum Status { case calculating, calculated, denied }
}

struct CategorySpec: Sendable {
    let id: String
    let name: String
    let hex: Int
    let paths: [String]
    var color: Color { Color(hex: hex) }
}

@MainActor
final class LiveStorage: ObservableObject {
    static let shared = LiveStorage()

    @Published var totalGB: Double = 0
    @Published var freeGB: Double = 0
    @Published var purgeableGB: Double = 0
    @Published var volumeName: String = "Macintosh HD"
    @Published var format: String = "APFS"
    @Published var categories: [LiveCategory] = []
    @Published var apps: [LiveCategory] = []
    @Published var calculating: Bool = true
    @Published var lastError: String? = nil
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    var usedGB: Double { max(0, totalGB - freeGB) }
    var usedPctText: String { totalGB > 0 ? "\(Int((usedGB / totalGB * 100).rounded()))%" : "—" }
    var displayCategories: [LiveCategory] {
        let measured = categories.reduce(0) { $0 + $1.size }
        let remainder = max(0, usedGB - measured)
        guard remainder > 0.01 else { return categories }
        return categories + [LiveCategory(id: "other", name: "Other & unscanned", color: Tokens.catOther, size: remainder)]
    }
    var cleanableGB: Double {
        categories.filter { ["caches", "downloads", "trash"].contains($0.id) && $0.status == .calculated }
                  .reduce(0) { $0 + $1.size }
    }

    nonisolated static let categorySpec: [CategorySpec] = {
        let home = NSHomeDirectory()
        return [
            CategorySpec(id: "apps",      name: "Applications",  hex: 0x4D8DFF, paths: ["/Applications", "\(home)/Applications"]),
            CategorySpec(id: "docs",      name: "Documents",     hex: 0x34D399, paths: ["\(home)/Documents"]),
            CategorySpec(id: "photos",    name: "Photos",        hex: 0xFBBF24, paths: ["\(home)/Pictures"]),
            CategorySpec(id: "videos",    name: "Movies",        hex: 0xC084FC, paths: ["\(home)/Movies"]),
            CategorySpec(id: "music",     name: "Music",         hex: 0xF472B6, paths: ["\(home)/Music"]),
            CategorySpec(id: "mail",      name: "Mail",          hex: 0x67E8F9, paths: ["\(home)/Library/Mail"]),
            CategorySpec(id: "caches",    name: "Caches & Logs", hex: 0xA5C9FF, paths: ["\(home)/Library/Caches", "\(home)/Library/Logs"]),
            CategorySpec(id: "downloads", name: "Downloads",     hex: 0xFFD479, paths: ["\(home)/Downloads"]),
            CategorySpec(id: "trash",     name: "Trash",         hex: 0xC4A47C, paths: ["\(home)/.Trash"]),
        ]
    }()

    private init() {
        readVolume()
        categories = Self.categorySpec.map { LiveCategory(id: $0.id, name: $0.name, color: $0.color, size: 0, status: .calculating) }
        kickScan()
    }

    func refresh() {
        lastError = nil
        readVolume()
        categories = Self.categorySpec.map { LiveCategory(id: $0.id, name: $0.name, color: $0.color, size: 0, status: .calculating) }
        apps = []
        calculating = true
        kickScan()
    }

    private func kickScan() {
        scanTask?.cancel()
        scanID = UUID()
        let id = scanID
        scanTask = Task.detached(priority: .userInitiated) {
            await Self.scanAll(id: id)
        }
    }

    // MARK: - Volume stats

    private func readVolume() {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else {
            lastError = "Could not read volume capacity. Try refreshing Storage."
            return
        }
        if let total = v.volumeTotalCapacity {
            totalGB = Double(total) / 1_000_000_000
        }
        // System Settings shows the iCloud-aware "important usage" free value.
        if let imp = v.volumeAvailableCapacityForImportantUsage {
            freeGB = Double(imp) / 1_000_000_000
        } else if let avail = v.volumeAvailableCapacity {
            freeGB = Double(avail) / 1_000_000_000
        }
        if let n = v.volumeName, !n.isEmpty { volumeName = n }
        if let f = v.volumeLocalizedFormatDescription, !f.isEmpty { format = f }
    }

    // MARK: - Category walks

    nonisolated private static func scanAll(id: UUID) async {
        for spec in categorySpec {
            guard !Task.isCancelled else { return }
            let result = directoryMeasurement(at: spec.paths)
            let gb = Double(result.bytes) / 1_000_000_000
            await MainActor.run {
                let store = LiveStorage.shared
                guard store.scanID == id else { return }
                if let i = store.categories.firstIndex(where: { $0.id == spec.id }) {
                    store.categories[i] = LiveCategory(id: spec.id, name: spec.name, color: spec.color, size: gb, status: .calculated, incomplete: result.incomplete)
                }
            }
        }
        let appsList = applicationsBreakdown()
        await MainActor.run {
            guard LiveStorage.shared.scanID == id else { return }
            LiveStorage.shared.apps = appsList
            LiveStorage.shared.calculating = false
        }
    }

    nonisolated private static func directoryBytes(at paths: [String]) -> Int64 {
        directoryMeasurement(at: paths).bytes
    }

    nonisolated private static func directoryMeasurement(at paths: [String]) -> (bytes: Int64, incomplete: Bool) {
        var total: Int64 = 0
        var incomplete = false
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in incomplete = true; return true }) else { incomplete = true; continue }
            for case let item as URL in en {
                if Task.isCancelled { return (total, true) }
                let v = try? item.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile != true { continue }
                if let s = v?.totalFileAllocatedSize { total += Int64(s); continue }
                if let s = v?.fileAllocatedSize       { total += Int64(s); continue }
                if let s = v?.fileSize                { total += Int64(s) }
            }
        }
        return (total, incomplete)
    }

    nonisolated private static func applicationsBreakdown() -> [LiveCategory] {
        let fm = FileManager.default
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        var apps: [(name: String, bytes: Int64)] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in items where entry.hasSuffix(".app") {
                let path = "\(root)/\(entry)"
                let bytes = directoryBytes(at: [path])
                if bytes > 0 {
                    apps.append((name: entry.replacingOccurrences(of: ".app", with: ""), bytes: bytes))
                }
            }
        }
        apps.sort { $0.bytes > $1.bytes }
        let palette: [Color] = [
            Color(hex: 0x147EFB), Color(hex: 0x1B1B1B), Color(hex: 0x001E36),
            Color(hex: 0xFF6B35), Color(hex: 0x2496ED), Color(hex: 0xFDB300),
            Color(hex: 0x4A154B), Color(hex: 0x0ACF83), Color(hex: 0x1DB954),
            Color(hex: 0x4285F4), Color(hex: 0x007ACC), Color(hex: 0x5865F2),
        ]
        let top = apps.prefix(20)
        let topBytes = top.reduce(Int64(0)) { $0 + $1.bytes }
        let totalBytes = apps.reduce(Int64(0)) { $0 + $1.bytes }
        var result: [LiveCategory] = top.enumerated().map { idx, a in
            LiveCategory(id: "app-\(idx)", name: a.name, color: palette[idx % palette.count], size: Double(a.bytes) / 1_000_000_000)
        }
        let rest = totalBytes - topBytes
        if rest > 0 {
            result.append(LiveCategory(id: "app-rest",
                                       name: "Other apps (\(apps.count - top.count))",
                                       color: Color(hex: 0x94A0B8),
                                       size: Double(rest) / 1_000_000_000))
        }
        return result
    }
}
