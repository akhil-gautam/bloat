import SwiftUI
import Foundation
import Combine

struct LiveCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let size: Double  // GB (decimal, matching System Settings / Finder)
    var status: Status = .calculated
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

    var usedGB: Double { max(0, totalGB - freeGB) }
    var usedPctText: String { totalGB > 0 ? "\(Int((usedGB / totalGB * 100).rounded()))%" : "—" }
    var cleanableGB: Double {
        categories.filter { ["caches", "downloads", "trash"].contains($0.id) && $0.status == .calculated }
                  .reduce(0) { $0 + $1.size }
    }

    nonisolated static let categorySpec: [CategorySpec] = {
        let home = NSHomeDirectory()
        return [
            CategorySpec(id: "apps",      name: "Applications",  hex: 0x0A84FF, paths: ["/Applications"]),
            CategorySpec(id: "docs",      name: "Documents",     hex: 0x30D158, paths: ["\(home)/Documents"]),
            CategorySpec(id: "photos",    name: "Photos",        hex: 0xFF9F0A, paths: ["\(home)/Pictures"]),
            CategorySpec(id: "videos",    name: "Movies",        hex: 0xBF5AF2, paths: ["\(home)/Movies"]),
            CategorySpec(id: "music",     name: "Music",         hex: 0xFF375F, paths: ["\(home)/Music"]),
            CategorySpec(id: "mail",      name: "Mail",          hex: 0x64D2FF, paths: ["\(home)/Library/Mail"]),
            CategorySpec(id: "caches",    name: "Caches & Logs", hex: 0xA5C9FF, paths: ["\(home)/Library/Caches", "\(home)/Library/Logs"]),
            CategorySpec(id: "downloads", name: "Downloads",     hex: 0xFFD479, paths: ["\(home)/Downloads"]),
            CategorySpec(id: "trash",     name: "Trash",         hex: 0xAC8E68, paths: ["\(home)/.Trash"]),
        ]
    }()

    private init() {
        readVolume()
        categories = Self.categorySpec.map { LiveCategory(id: $0.id, name: $0.name, color: $0.color, size: 0, status: .calculating) }
        kickScan()
    }

    func refresh() {
        readVolume()
        categories = Self.categorySpec.map { LiveCategory(id: $0.id, name: $0.name, color: $0.color, size: 0, status: .calculating) }
        apps = []
        calculating = true
        kickScan()
    }

    private func kickScan() {
        Task.detached(priority: .userInitiated) {
            await Self.scanAll()
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
        guard let v = try? url.resourceValues(forKeys: keys) else { return }
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

    nonisolated private static func scanAll() async {
        for spec in categorySpec {
            let bytes = directoryBytes(at: spec.paths)
            let gb = Double(bytes) / 1_000_000_000
            await MainActor.run {
                let store = LiveStorage.shared
                if let i = store.categories.firstIndex(where: { $0.id == spec.id }) {
                    store.categories[i] = LiveCategory(id: spec.id, name: spec.name, color: spec.color, size: gb, status: .calculated)
                }
            }
        }
        let appsList = applicationsBreakdown()
        await MainActor.run {
            LiveStorage.shared.apps = appsList
            LiveStorage.shared.calculating = false
        }
    }

    nonisolated private static func directoryBytes(at paths: [String]) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let item as URL in en {
                let v = try? item.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile != true { continue }
                if let s = v?.totalFileAllocatedSize { total += Int64(s); continue }
                if let s = v?.fileAllocatedSize       { total += Int64(s); continue }
                if let s = v?.fileSize                { total += Int64(s) }
            }
        }
        return total
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
                                       color: Color(hex: 0x8E8E93),
                                       size: Double(rest) / 1_000_000_000))
        }
        return result
    }
}
