import Foundation
import AppKit
import Combine

/// Inventories the user's cloud-storage providers and surfaces what's
/// actually consuming local disk. We avoid `NSMetadataQuery` and walk the
/// filesystem directly — iCloud's placeholder convention (`.<name>.icloud`
/// stub files) lets us tell cloud-only from downloaded with a regular
/// directory enumeration.
///
/// Eviction (giving back local disk while keeping the cloud copy) is only
/// available on iCloud — `brctl evict <path>`. Other providers (Drive,
/// Dropbox, OneDrive) have provider-specific online-only mechanics that
/// macOS doesn't expose a uniform CLI for; for those we surface the
/// largest items + reveal-in-Finder so the user can offload manually.
enum CloudProvider: String, CaseIterable {
    case iCloud, googleDrive, dropbox, oneDrive, box

    var displayName: String {
        switch self {
        case .iCloud:      return "iCloud Drive"
        case .googleDrive: return "Google Drive"
        case .dropbox:     return "Dropbox"
        case .oneDrive:    return "OneDrive"
        case .box:         return "Box"
        }
    }

    var icon: String {
        switch self {
        case .iCloud:      return "icloud"
        case .googleDrive: return "g.circle"
        case .dropbox:     return "shippingbox"
        case .oneDrive:    return "cloud"
        case .box:         return "cube.box"
        }
    }

    var supportsEviction: Bool { self == .iCloud }
}

enum CloudItemState { case downloaded, cloudOnly, partial }

struct CloudItem: Identifiable, Hashable {
    let id: String           // path
    let url: URL
    let displayName: String
    let bytes: Int64
    let state: CloudItemState
    let provider: CloudProvider
    let modifiedAt: Date?
}

struct CloudInventory: Identifiable {
    let id: CloudProvider
    let provider: CloudProvider
    let root: URL
    let items: [CloudItem]
    var downloadedBytes: Int64 { items.filter { $0.state == .downloaded }.reduce(0) { $0 + $1.bytes } }
    var cloudOnlyBytes:  Int64 { items.filter { $0.state == .cloudOnly  }.reduce(0) { $0 + $1.bytes } }
}

@MainActor
final class LiveCloud: ObservableObject {
    static let shared = LiveCloud()

    @Published private(set) var inventories: [CloudInventory] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var lastError: String? = nil

    var totalDownloadedBytes: Int64 { inventories.reduce(0) { $0 + $1.downloadedBytes } }

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if inventories.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true; inventories = []
        phase = "Detecting providers…"
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() { task?.cancel(); task = nil; scanning = false }

    /// Evict downloaded-but-also-in-cloud items. iCloud paths route through
    /// `brctl evict`; other providers fall back to no-op + a clear error.
    @discardableResult
    func evict(_ ids: Set<String>) -> Int64 {
        var bytes: Int64 = 0
        var evicted = 0
        var failed: [String] = []
        for inv in inventories {
            for item in inv.items where ids.contains(item.id) && item.state == .downloaded {
                if item.provider.supportsEviction {
                    if brctlEvict(item.url) {
                        bytes += item.bytes; evicted += 1
                    } else {
                        failed.append(item.displayName)
                    }
                } else {
                    failed.append("\(item.displayName) (\(item.provider.displayName) eviction not supported)")
                }
            }
        }
        if !failed.isEmpty { lastError = failed.joined(separator: "\n") }
        if evicted > 0 { CleanupLog.record(module: .cloud, itemCount: evicted, bytes: bytes) }
        scan()      // refresh state — evicted items flip downloaded → cloudOnly
        return bytes
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: - Eviction

    private func brctlEvict(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        p.arguments = ["evict", url.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Scan

    private nonisolated static func runScan() async {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [CloudInventory] = []

        // iCloud Drive — canonical path is ~/Library/Mobile Documents/com~apple~CloudDocs
        let iCloudRoot = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloudRoot.path) {
            let items = enumerateProvider(root: iCloudRoot, provider: .iCloud, maxItems: 500)
            found.append(CloudInventory(id: .iCloud, provider: .iCloud, root: iCloudRoot, items: items))
        }

        // Other providers via ~/Library/CloudStorage/<provider>-<account>/
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? FileManager.default.contentsOfDirectory(at: cloudStorage,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for entry in entries {
                let name = entry.lastPathComponent
                let provider: CloudProvider
                if      name.hasPrefix("GoogleDrive") { provider = .googleDrive }
                else if name.hasPrefix("Dropbox")     { provider = .dropbox }
                else if name.hasPrefix("OneDrive")    { provider = .oneDrive }
                else if name.hasPrefix("Box")         { provider = .box }
                else { continue }
                let items = enumerateProvider(root: entry, provider: provider, maxItems: 200)
                found.append(CloudInventory(id: provider, provider: provider, root: entry, items: items))
            }
        }

        let finalInventories = found
        await MainActor.run {
            LiveCloud.shared.inventories = finalInventories
            LiveCloud.shared.scanning = false
            LiveCloud.shared.phase = "Done"
        }
    }

    /// Walk a provider root, classify items, return the top-`maxItems`
    /// largest entries (downloaded items first, then cloud-only).
    private nonisolated static func enumerateProvider(root: URL, provider: CloudProvider, maxItems: Int) -> [CloudItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
            includingPropertiesForKeys: [
                .totalFileAllocatedSizeKey, .fileSizeKey,
                .isRegularFileKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]) else { return [] }
        var rows: [CloudItem] = []
        let urls = (enumerator.allObjects as? [URL]) ?? []
        for url in urls {
            let v = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileSizeKey,
                .isRegularFileKey, .contentModificationDateKey,
            ])
            guard v?.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            let isCloudPlaceholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
            let displayName = isCloudPlaceholder
                ? String(name.dropFirst().dropLast(".icloud".count))
                : name
            let state: CloudItemState = isCloudPlaceholder ? .cloudOnly : .downloaded
            // For cloud-only placeholders the on-disk size is tiny, but the
            // metadata in the placeholder includes the real size. We can't
            // read that without parsing — fall back to allocated size.
            let bytes = Int64((v?.totalFileAllocatedSize) ?? (v?.fileSize ?? 0))
            // Skip noise — we want a meaningful list, not every README.
            if state == .downloaded && bytes < 5_000_000 { continue }   // <5MB
            if state == .cloudOnly  && bytes < 100      { continue }   // empty placeholders

            rows.append(CloudItem(
                id: url.path, url: url,
                displayName: displayName, bytes: bytes, state: state,
                provider: provider,
                modifiedAt: v?.contentModificationDate
            ))
        }
        rows.sort { (a, b) in
            if a.state != b.state {
                // Downloaded items rank above cloud-only — that's the actionable bucket.
                return a.state == .downloaded
            }
            return a.bytes > b.bytes
        }
        return Array(rows.prefix(maxItems))
    }
}
