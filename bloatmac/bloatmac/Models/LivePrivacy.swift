import Foundation
import AppKit
import Combine

/// Browser & chat-app privacy data inventory. For each detected target we
/// list the on-disk artefacts (cookies, history, cache, login data, etc.)
/// the user might want to wipe. Cleaning trashes the files; the host app
/// re-creates a fresh DB on next launch.
///
/// Hard requirement: the target app must be quit before we touch its DBs.
/// Modifying SQLite while the owner has it open silently corrupts the
/// journal. We refuse to clean a running target and surface a Quit hint in
/// the UI.
enum PrivacyDataKind: String, CaseIterable {
    case cookies, history, cache, loginData, webData, downloads, sessions

    var label: String {
        switch self {
        case .cookies:    return "Cookies"
        case .history:    return "History"
        case .cache:      return "Cache"
        case .loginData:  return "Saved logins"
        case .webData:    return "Web data"
        case .downloads:  return "Downloads list"
        case .sessions:   return "Sessions"
        }
    }
}

struct PrivacyDataItem: Identifiable, Hashable {
    let id: String              // path
    let kind: PrivacyDataKind
    let path: URL
    let bytes: Int64
}

struct PrivacyTarget: Identifiable {
    let id: String              // bundle id
    let displayName: String
    let appURL: URL?
    let bundleID: String
    let icon: String            // SF symbol fallback
    let isRunning: Bool
    let items: [PrivacyDataItem]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

@MainActor
final class LivePrivacy: ObservableObject {
    static let shared = LivePrivacy()

    @Published private(set) var targets: [PrivacyTarget] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var lastError: String? = nil

    var totalBytes: Int64 { targets.reduce(0) { $0 + $1.totalBytes } }

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if targets.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true; targets = []
        phase = "Detecting browsers & chat apps…"
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() { task?.cancel(); task = nil; scanning = false }

    /// Trash all selected items. Refuses to clean items belonging to a target
    /// whose host app is currently running.
    @discardableResult
    func clean(_ ids: Set<String>) -> Int64 {
        var bytes: Int64 = 0
        var trashed = 0
        var blocked: [String] = []
        let fm = FileManager.default
        for target in targets {
            if target.isRunning {
                if target.items.contains(where: { ids.contains($0.id) }) {
                    blocked.append(target.displayName)
                }
                continue
            }
            for item in target.items where ids.contains(item.id) {
                if (try? fm.trashItem(at: item.path, resultingItemURL: nil)) != nil {
                    bytes += item.bytes
                    trashed += 1
                }
            }
        }
        if !blocked.isEmpty {
            lastError = "Skipped while running: " + blocked.joined(separator: ", ") + ". Quit and try again."
        }
        // Re-scan after a clean so the UI reflects what's actually on disk.
        scan()
        if trashed > 0 { CleanupLog.record(module: .privacy, itemCount: trashed, bytes: bytes) }
        return bytes
    }

    // MARK: - Scan implementation

    private nonisolated static func runScan() async {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let lib = home.appendingPathComponent("Library")
        let appSupport = lib.appendingPathComponent("Application Support")
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var rows: [PrivacyTarget] = []

        // Helper closure — DRY across the chromium-family browsers.
        func chromium(_ id: String, _ name: String, _ supportPath: String, _ profileDirs: [String] = ["Default"]) -> PrivacyTarget? {
            let appURL = locateApp(bundleID: id)
            let root = appSupport.appendingPathComponent(supportPath)
            guard FileManager.default.fileExists(atPath: root.path) else {
                if let appURL = appURL {
                    return PrivacyTarget(id: id, displayName: name, appURL: appURL,
                                         bundleID: id, icon: "globe",
                                         isRunning: runningBundles.contains(id), items: [])
                }
                return nil
            }
            var items: [PrivacyDataItem] = []
            for profile in profileDirs {
                let p = root.appendingPathComponent(profile)
                items.append(contentsOf: addIfPresent([
                    (.cookies,   p.appendingPathComponent("Cookies")),
                    (.history,   p.appendingPathComponent("History")),
                    (.loginData, p.appendingPathComponent("Login Data")),
                    (.webData,   p.appendingPathComponent("Web Data")),
                    (.cache,     p.appendingPathComponent("Cache")),
                    (.cache,     p.appendingPathComponent("Code Cache")),
                    (.cache,     p.appendingPathComponent("GPUCache")),
                    (.sessions,  p.appendingPathComponent("Sessions")),
                ]))
            }
            return PrivacyTarget(id: id, displayName: name, appURL: appURL,
                                 bundleID: id, icon: "globe",
                                 isRunning: runningBundles.contains(id),
                                 items: items)
        }

        // Browsers
        if let t = chromium("com.google.Chrome",        "Google Chrome",  "Google/Chrome") { rows.append(t) }
        if let t = chromium("com.microsoft.edgemac",    "Microsoft Edge", "Microsoft Edge") { rows.append(t) }
        if let t = chromium("com.brave.Browser",        "Brave",          "BraveSoftware/Brave-Browser") { rows.append(t) }
        if let t = chromium("company.thebrowser.Browser","Arc",           "Arc/User Data") { rows.append(t) }

        // Safari — different layout. We probe ~/Library/Safari directly,
        // and only attempt to read cookies if FDA grants us access.
        let safari = lib.appendingPathComponent("Safari")
        if FileManager.default.fileExists(atPath: safari.path) {
            var items: [PrivacyDataItem] = addIfPresent([
                (.history,   safari.appendingPathComponent("History.db")),
                (.history,   safari.appendingPathComponent("History.db-wal")),
                (.history,   safari.appendingPathComponent("History.db-shm")),
                (.downloads, safari.appendingPathComponent("Downloads.plist")),
                (.cache,     safari.appendingPathComponent("LocalStorage")),
                (.cache,     safari.appendingPathComponent("Databases")),
            ])
            // Cookies live at ~/Library/Cookies for Safari historically.
            let safCookies = lib.appendingPathComponent("Cookies/Cookies.binarycookies")
            items.append(contentsOf: addIfPresent([(.cookies, safCookies)]))
            rows.append(PrivacyTarget(
                id: "com.apple.Safari", displayName: "Safari",
                appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                bundleID: "com.apple.Safari", icon: "safari",
                isRunning: runningBundles.contains("com.apple.Safari"),
                items: items
            ))
        }

        // Firefox — every profile under ~/Library/Application Support/Firefox/Profiles/<random>.<name>
        let fxRoot = appSupport.appendingPathComponent("Firefox/Profiles")
        if let profiles = try? FileManager.default.contentsOfDirectory(at: fxRoot, includingPropertiesForKeys: nil) {
            var items: [PrivacyDataItem] = []
            for p in profiles {
                items.append(contentsOf: addIfPresent([
                    (.cookies,   p.appendingPathComponent("cookies.sqlite")),
                    (.history,   p.appendingPathComponent("places.sqlite")),
                    (.loginData, p.appendingPathComponent("logins.json")),
                    (.cache,     p.appendingPathComponent("cache2")),
                    (.cache,     p.appendingPathComponent("startupCache")),
                    (.sessions,  p.appendingPathComponent("sessionstore.jsonlz4")),
                ]))
            }
            rows.append(PrivacyTarget(
                id: "org.mozilla.firefox", displayName: "Firefox",
                appURL: locateApp(bundleID: "org.mozilla.firefox"),
                bundleID: "org.mozilla.firefox", icon: "globe",
                isRunning: runningBundles.contains("org.mozilla.firefox"),
                items: items
            ))
        }

        // Chat apps — cache wipes only.
        for chat in [
            (id: "com.tinyspeck.slackmacgap",  name: "Slack",
             paths: [(PrivacyDataKind.cache, "Slack/Cache"),
                     (.cache, "Slack/Code Cache"),
                     (.cache, "Slack/GPUCache")]),
            (id: "com.hnc.Discord", name: "Discord",
             paths: [(.cache, "discord/Cache"), (.cache, "discord/Code Cache")]),
            (id: "ru.keepcoder.Telegram", name: "Telegram",
             paths: [(.cache, "Telegram/Caches")]),
            (id: "net.whatsapp.WhatsApp", name: "WhatsApp",
             paths: [(.cache, "WhatsApp/Cache")]),
        ] {
            var items: [PrivacyDataItem] = []
            for (kind, sub) in chat.paths {
                let p = appSupport.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: p.path) {
                    items.append(PrivacyDataItem(id: p.path, kind: kind, path: p, bytes: directorySize(p)))
                }
            }
            if !items.isEmpty || locateApp(bundleID: chat.id) != nil {
                rows.append(PrivacyTarget(
                    id: chat.id, displayName: chat.name,
                    appURL: locateApp(bundleID: chat.id),
                    bundleID: chat.id, icon: "bubble.left.and.bubble.right",
                    isRunning: runningBundles.contains(chat.id),
                    items: items
                ))
            }
        }

        let final = rows
            .filter { !$0.items.isEmpty }
            .sorted { $0.totalBytes > $1.totalBytes }

        await MainActor.run {
            LivePrivacy.shared.targets = final
            LivePrivacy.shared.scanning = false
            LivePrivacy.shared.phase = "Done"
        }
    }

    // MARK: - Helpers

    private nonisolated static func addIfPresent(_ entries: [(PrivacyDataKind, URL)]) -> [PrivacyDataItem] {
        let fm = FileManager.default
        var out: [PrivacyDataItem] = []
        for (kind, url) in entries where fm.fileExists(atPath: url.path) {
            out.append(PrivacyDataItem(id: url.path, kind: kind, path: url, bytes: directorySize(url)))
        }
        return out
    }

    private nonisolated static func locateApp(bundleID: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return nil
    }

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
        let urls = (enumerator.allObjects as? [URL]) ?? []
        for url in urls {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
