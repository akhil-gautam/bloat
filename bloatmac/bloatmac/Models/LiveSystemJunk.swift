import Foundation
import AppKit
import Combine

/// Umbrella scanner for the assorted "junk" categories CleanMyMac surfaces
/// under "System Junk". Each category is enumerated independently and rolls
/// up to a single `LiveSystemJunk.shared.categories` array the screen
/// renders. Categories with kind `.risky` are not auto-selected and require
/// explicit opt-in (currently only language-pack pruning, which can break
/// app code signatures).
enum JunkKind: String { case xcode, xcodeArchives, iosBackup, mailAttachments, photoThumbs, tmSnapshots, brokenLogin, lproj }

enum JunkRisk { case safe, caution, risky }

struct JunkItem: Identifiable, Hashable {
    let id: String           // path or snapshot date — must be unique within category
    let label: String        // human-readable
    let detail: String       // sub-line, e.g. timestamps or file count
    let path: URL?           // nil for things like TM snapshots that aren't files
    let bytes: Int64
    let extra: String        // category-specific payload (TM snapshot date, etc.)
}

struct JunkCategory: Identifiable {
    let id: JunkKind
    let title: String
    let icon: String
    let risk: JunkRisk
    let summary: String
    let items: [JunkItem]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

@MainActor
final class LiveSystemJunk: ObservableObject {
    static let shared = LiveSystemJunk()

    @Published private(set) var categories: [JunkCategory] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil
    @Published private(set) var hasCompletedScan: Bool = false

    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }

    private var task: Task<Void, Never>? = nil
    private var generation = 0
    private init() {}

    func startIfNeeded() {
        if !hasCompletedScan && !scanning { scan() }
    }

    func scan() {
        cancel()
        generation += 1
        let scanGeneration = generation
        scanning = true; categories = []; progress = 0; phase = "Scanning…"; lastError = nil; hasCompletedScan = false
        task = Task.detached(priority: .userInitiated) { await Self.runScan(generation: scanGeneration) }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil; scanning = false
    }

    /// Trash the union of ids across categories. Snapshot ids are dispatched
    /// to `tmutil deletelocalsnapshots` instead of FileManager.trashItem.
    @discardableResult
    func clean(_ ids: Set<String>) -> Int64 {
        var bytes: Int64 = 0
        var count = 0
        var failed = Set<String>()
        var failures: [String] = []
        let runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let photosRunning = !SystemStatusPolicy.photosCleanupAllowed(
            runningBundleIdentifiers: runningBundleIdentifiers
        )
        for cat in categories {
            for item in cat.items where ids.contains(item.id) {
                if cat.id == .photoThumbs && photosRunning {
                    failed.insert(item.id)
                    failures.append("\(item.label): quit Photos before cleaning its thumbnails.")
                    continue
                }
                if cat.id == .tmSnapshots {
                    if deleteLocalSnapshot(date: item.extra) {
                        bytes += item.bytes; count += 1
                    } else {
                        failed.insert(item.id)
                        failures.append("\(item.label): Time Machine snapshot could not be deleted.")
                    }
                } else if let url = item.path {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        bytes += item.bytes; count += 1
                    } catch {
                        failed.insert(item.id)
                        failures.append("\(item.label): \(error.localizedDescription)")
                    }
                }
            }
        }
        let succeeded = SystemStatusPolicy.succeededIDs(requested: ids, failed: failed)
        categories = categories.compactMap { cat in
            let remaining = cat.items.filter { !succeeded.contains($0.id) }
            guard !remaining.isEmpty else { return nil }
            return JunkCategory(id: cat.id, title: cat.title, icon: cat.icon, risk: cat.risk,
                                summary: cat.summary, items: remaining)
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if count > 0 { CleanupLog.record(module: .systemJunk, itemCount: count, bytes: bytes) }
        return bytes
    }

    private func deleteLocalSnapshot(date: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["deletelocalsnapshots", date]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Scan

    private nonisolated static func runScan(generation: Int) async {
        async let xcode      = scanXcode()
        async let backups    = scanIOSBackups()
        async let mail       = scanMailAttachments()
        async let photos     = scanPhotoThumbs()
        async let snapshots  = scanTimeMachineSnapshots()
        async let broken     = scanBrokenLoginItems()
        let xcodeCategories = await xcode
        let collected = xcodeCategories + [
            await backups, await mail, await photos, await snapshots, await broken
        ].compactMap { $0 }
        await MainActor.run {
            let model = LiveSystemJunk.shared
            guard model.generation == generation, !Task.isCancelled else { return }
            model.categories = collected
            model.hasCompletedScan = true
            model.scanning = false
            model.progress = 1
            model.phase = "Done"
        }
    }

    // MARK: - Xcode

    private nonisolated static func scanXcode() async -> [JunkCategory] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dev = home.appendingPathComponent("Library/Developer/Xcode")
        let fm = FileManager.default
        guard fm.fileExists(atPath: dev.path) else { return [] }

        var items: [JunkItem] = []
        var archiveItems: [JunkItem] = []
        let derived = dev.appendingPathComponent("DerivedData")
        if let entries = try? fm.contentsOfDirectory(at: derived,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in entries {
                let bytes = directorySize(url)
                if bytes > 0 {
                    items.append(JunkItem(id: url.path,
                                          label: url.lastPathComponent,
                                          detail: "DerivedData",
                                          path: url, bytes: bytes, extra: ""))
                }
            }
        }
        let iosSupport = dev.appendingPathComponent("iOS DeviceSupport")
        if let entries = try? fm.contentsOfDirectory(at: iosSupport,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in entries {
                let bytes = directorySize(url)
                if bytes > 0 {
                    items.append(JunkItem(id: url.path,
                                          label: url.lastPathComponent,
                                          detail: "iOS DeviceSupport",
                                          path: url, bytes: bytes, extra: ""))
                }
            }
        }
        let archives = dev.appendingPathComponent("Archives")
        if let enumerator = fm.enumerator(at: archives,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) {
            let urls = (enumerator.allObjects as? [URL]) ?? []
            for url in urls where url.pathExtension == "xcarchive" {
                let bytes = directorySize(url)
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                                  .contentModificationDate) ?? Date.distantPast
                let age = Int(Date().timeIntervalSince(mod) / 86400)
                if age > 30 && bytes > 0 {
                    archiveItems.append(JunkItem(id: url.path,
                                          label: url.lastPathComponent,
                                          detail: "Archive · \(age)d old",
                                          path: url, bytes: bytes, extra: ""))
                }
            }
        }
        items.sort { $0.bytes > $1.bytes }
        archiveItems.sort { $0.bytes > $1.bytes }
        var categories: [JunkCategory] = []
        if !items.isEmpty {
            categories.append(JunkCategory(id: .xcode, title: "Xcode generated data", icon: "hammer",
                            risk: .safe,
                            summary: "DerivedData and downloaded iOS DeviceSupport can be rebuilt.",
                            items: items))
        }
        if !archiveItems.isEmpty {
            categories.append(JunkCategory(id: .xcodeArchives, title: "Xcode archives", icon: "archivebox",
                            risk: .caution,
                            summary: "Archives may be the only copy of a signed release. Verify each one before removal.",
                            items: archiveItems))
        }
        return categories
    }

    // MARK: - iOS backups

    private nonisolated static func scanIOSBackups() async -> JunkCategory? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let root = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let entries = try? fm.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return nil }
        var items: [JunkItem] = []
        for url in entries {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                              .contentModificationDate) ?? Date.distantPast
            let bytes = directorySize(url)
            if bytes > 0 {
                items.append(JunkItem(id: url.path,
                                      label: url.lastPathComponent,
                                      detail: ISO8601DateFormatter().string(from: mod),
                                      path: url, bytes: bytes, extra: ""))
            }
        }
        guard !items.isEmpty else { return nil }
        return JunkCategory(id: .iosBackup, title: "iOS device backups", icon: "iphone",
                            risk: .caution,
                            summary: "Each backup can be tens of GB. Verify with iTunes/Finder if you might still need them.",
                            items: items.sorted { $0.bytes > $1.bytes })
    }

    // MARK: - Mail attachments

    private nonisolated static func scanMailAttachments() async -> JunkCategory? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let mail = home.appendingPathComponent("Library/Mail")
        let fm = FileManager.default
        guard fm.fileExists(atPath: mail.path) else { return nil }
        var items: [JunkItem] = []
        // Walk Library/Mail/V*/MailData/<account>/Attachments
        if let versions = try? fm.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil, options: []) {
            for v in versions where v.lastPathComponent.hasPrefix("V") {
                let mailData = v.appendingPathComponent("MailData")
                guard let accounts = try? fm.contentsOfDirectory(at: mailData,
                    includingPropertiesForKeys: nil, options: []) else { continue }
                for acc in accounts {
                    let attach = acc.appendingPathComponent("Attachments")
                    guard fm.fileExists(atPath: attach.path) else { continue }
                    let bytes = directorySize(attach)
                    if bytes > 50_000_000 {
                        items.append(JunkItem(id: attach.path,
                                              label: acc.lastPathComponent,
                                              detail: "Attachments · \(v.lastPathComponent)",
                                              path: attach, bytes: bytes, extra: ""))
                    }
                }
            }
        }
        guard !items.isEmpty else { return nil }
        return JunkCategory(id: .mailAttachments, title: "Mail attachments", icon: "envelope",
                            risk: .caution,
                            summary: "Cached attachments — Mail re-downloads on demand.",
                            items: items.sorted { $0.bytes > $1.bytes })
    }

    // MARK: - Photos thumbnails

    private nonisolated static func scanPhotoThumbs() async -> JunkCategory? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let pictures = home.appendingPathComponent("Pictures")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil, options: []) else {
            return nil
        }
        var items: [JunkItem] = []
        for lib in entries where lib.pathExtension == "photoslibrary" {
            let derivatives = lib.appendingPathComponent("resources/derivatives")
            let cachesNoindex = lib.appendingPathComponent("Caches.noindex")
            for sub in [derivatives, cachesNoindex] {
                guard fm.fileExists(atPath: sub.path) else { continue }
                let bytes = directorySize(sub)
                if bytes > 100_000_000 {
                    items.append(JunkItem(id: sub.path,
                                          label: lib.deletingPathExtension().lastPathComponent,
                                          detail: sub.lastPathComponent,
                                          path: sub, bytes: bytes, extra: ""))
                }
            }
        }
        guard !items.isEmpty else { return nil }
        return JunkCategory(id: .photoThumbs, title: "Photos thumbnails", icon: "photo.on.rectangle",
                            risk: .caution,
                            summary: "Photos rebuilds these on demand. Quit Photos before cleaning.",
                            items: items.sorted { $0.bytes > $1.bytes })
    }

    // MARK: - Time Machine local snapshots

    private nonisolated static func scanTimeMachineSnapshots() async -> JunkCategory? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? out.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var items: [JunkItem] = []
        for line in text.split(separator: "\n") {
            // com.apple.TimeMachine.2026-04-30-153000.local
            let l = String(line).trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("com.apple.TimeMachine.") else { continue }
            let dateField = l
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
            // No size from `tmutil` directly — best-effort bytes via APFS
            // delta would need diskutil; we mark size as 0 and surface count.
            items.append(JunkItem(id: l, label: dateField, detail: "Local APFS snapshot",
                                  path: nil, bytes: 0, extra: dateField))
        }
        guard !items.isEmpty else { return nil }
        return JunkCategory(id: .tmSnapshots, title: "Time Machine local snapshots",
                            icon: "clock.arrow.circlepath",
                            risk: .safe,
                            summary: "macOS auto-deletes when space is needed; manual purge frees space immediately.",
                            items: items)
    }

    // MARK: - Broken login items

    private nonisolated static func scanBrokenLoginItems() async -> JunkCategory? {
        let items = await MainActor.run { LiveStartup.shared.items }
        let fm = FileManager.default
        var broken: [JunkItem] = []
        for item in items {
            // Treat the launch-agent plist as "broken" when its target program
            // path is missing. Plist itself becomes the trash candidate.
            guard let prog = item.program, !prog.isEmpty,
                  !fm.fileExists(atPath: prog) else { continue }
            let plistURL = item.id      // LaunchAgentItem.id IS the plist URL
            let bytes = (try? fm.attributesOfItem(atPath: plistURL.path)[.size] as? Int) ?? 0
            broken.append(JunkItem(id: plistURL.path,
                                   label: item.label,
                                   detail: "Missing: \(prog)",
                                   path: plistURL,
                                   bytes: Int64(bytes),
                                   extra: ""))
        }
        guard !broken.isEmpty else { return nil }
        return JunkCategory(id: .brokenLogin, title: "Broken login items",
                            icon: "exclamationmark.triangle",
                            risk: .safe,
                            summary: "LaunchAgents pointing at apps that no longer exist.",
                            items: broken)
    }

    // MARK: - Helpers

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
