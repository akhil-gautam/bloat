import Foundation
import AppKit
import Combine

/// Lists every installed `.app` bundle the current user can see and computes
/// the disk footprint of each app's leftover files in well-known
/// `~/Library/...` locations. Uninstall trashes the app + all detected
/// leftover paths after the app bundle has safely moved to Trash.
///
/// We deliberately key the leftover sweep off the bundle identifier rather than
/// the display name. Group containers are excluded because another app from the
/// same developer may still own their contents.
struct InstalledApp: Identifiable, Hashable {
    let id: URL                  // /Applications/Foo.app
    let bundleID: String         // com.example.foo  (or "" if the bundle had no Info.plist)
    let teamID: String           // 7KNZMS52WD       (parsed from codesign; "" when unsigned/ad-hoc)
    let displayName: String
    let version: String
    let appBytes: Int64
    let leftoverBytes: Int64
    let leftovers: [URL]         // paths we'd sweep on uninstall — surfaced for transparency
    let isSandboxed: Bool        // contains ~/Library/Containers/<bundle-id>

    nonisolated var totalBytes: Int64 { appBytes + leftoverBytes }
}

@MainActor
final class LiveUninstaller: ObservableObject {
    static let shared = LiveUninstaller()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil

    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.totalBytes } }

    private var task: Task<Void, Never>? = nil
    private var scanGeneration = ScanGeneration()
    private init() {}

    func startIfNeeded() {
        if apps.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        let generation = scanGeneration.next()
        scanning = true; apps = []
        phase = "Enumerating installed apps…"; progress = 0
        task = Task.detached(priority: .userInitiated) { await Self.runScan(generation: generation) }
    }

    func cancel() {
        _ = scanGeneration.next()
        task?.cancel(); task = nil; scanning = false
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Trash the listed apps along with every detected leftover path. Returns
    /// (apps trashed, total bytes moved to Trash). Failures are surfaced via
    /// `lastError`; partial successes still write a CleanupLog entry.
    @discardableResult
    func uninstall(_ ids: Set<URL>) -> (Int, Int64) {
        let fm = FileManager.default
        var appCount = 0
        var bytes: Int64 = 0
        var failed: [String] = []
        var removed: Set<URL> = []
        lastError = nil
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for id in ids {
            guard let app = self.apps.first(where: { $0.id == id }) else { continue }
            guard !runningBundles.contains(app.bundleID) else {
                failed.append("\(app.displayName): quit the app before uninstalling")
                continue
            }

            let appOutcome = CleanupSafety.performTrash([
                CleanupCandidate(id: app.id, url: app.id, bytes: app.appBytes),
            ]) { try fm.trashItem(at: $0, resultingItemURL: nil) }
            guard appOutcome.failures.isEmpty else {
                failed.append(contentsOf: appOutcome.failures.map { "\(app.displayName): \($0)" })
                continue
            }
            appCount += 1
            bytes += appOutcome.bytes
            removed.insert(app.id)

            let leftovers = app.leftovers.filter { !CleanupSafety.isSharedContainer($0) }.map {
                CleanupCandidate(id: $0, url: $0, bytes: Self.directorySize($0))
            }
            let leftoverOutcome = CleanupSafety.performTrash(leftovers) {
                try fm.trashItem(at: $0, resultingItemURL: nil)
            }
            bytes += leftoverOutcome.bytes
            failed.append(contentsOf: leftoverOutcome.failures.map { "\(app.displayName): \($0)" })
        }
        if !failed.isEmpty { lastError = failed.joined(separator: "\n") }
        self.apps.removeAll { removed.contains($0.id) }
        if appCount > 0 {
            CleanupLog.record(module: .uninstaller, itemCount: appCount, bytes: bytes)
        }
        return (appCount, bytes)
    }

    // MARK: - Scan implementation

    private nonisolated static func runScan(generation: Int) async {
        let fm = FileManager.default
        let appRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        var bundles: [URL] = []
        for root in appRoots {
            guard let entries = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            bundles.append(contentsOf: entries.filter { $0.pathExtension == "app" })
        }

        let bundleCount = bundles.count
        await MainActor.run {
            let live = LiveUninstaller.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.phase = "Inspecting \(bundleCount) apps…"
        }

        var collected: [InstalledApp] = []
        for (i, app) in bundles.enumerated() {
            if Task.isCancelled { return }
            if let row = inspect(app: app) { collected.append(row) }
            if i % 5 == 0 {
                let p = Double(i + 1) / Double(max(bundleCount, 1))
                let appName = app.lastPathComponent
                await MainActor.run {
                    let live = LiveUninstaller.shared
                    guard live.scanGeneration.accepts(generation) else { return }
                    live.progress = p
                    live.phase = "Inspecting \(appName)…"
                }
            }
        }

        // Sort largest-first by combined bytes so the screen has the
        // most-actionable rows up top.
        collected.sort { $0.totalBytes > $1.totalBytes }
        let finalRows = collected

        await MainActor.run {
            let live = LiveUninstaller.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.apps = finalRows
            live.scanning = false
            live.task = nil
            live.progress = 1
            live.phase = "Done"
        }
    }

    private nonisolated static func inspect(app: URL) -> InstalledApp? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else { return nil }
        let bundleID    = (info["CFBundleIdentifier"]   as? String) ?? ""
        let displayName = (info["CFBundleDisplayName"]  as? String)
                       ?? (info["CFBundleName"]         as? String)
                       ?? app.deletingPathExtension().lastPathComponent
        let version     = (info["CFBundleShortVersionString"] as? String)
                       ?? (info["CFBundleVersion"]            as? String)
                       ?? ""

        guard !bundleID.isEmpty else { return nil }
        let teamID = teamIdentifier(for: app)

        let appBytes = directorySize(app)
        var leftovers = leftoverPaths(bundleID: bundleID, teamID: teamID)

        // Filter to ones that actually exist; sum sizes.
        let fm = FileManager.default
        leftovers = leftovers.filter { fm.fileExists(atPath: $0.path) }
        let leftoverBytes = leftovers.reduce(Int64(0)) { $0 + directorySize($1) }

        let isSandboxed = leftovers.contains { $0.path.contains("/Library/Containers/") }

        return InstalledApp(
            id: app, bundleID: bundleID, teamID: teamID,
            displayName: displayName, version: version,
            appBytes: appBytes, leftoverBytes: leftoverBytes,
            leftovers: leftovers, isSandboxed: isSandboxed
        )
    }

    /// Best-effort team-ID extraction from the bundle's signature. Uses the
    /// `codesign` CLI because parsing CodeResources directly skips re-signed
    /// or unsigned bundles. Returns "" if the binary isn't signed in a way
    /// we can parse.
    private nonisolated static func teamIdentifier(for app: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", "--", app.path]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return "" }
        // Lines look like: "TeamIdentifier=7KNZMS52WD" or "TeamIdentifier=not set"
        for line in out.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let v = line.dropFirst("TeamIdentifier=".count)
                if v == "not set" { return "" }
                return String(v)
            }
        }
        return ""
    }

    /// Well-known leftover-path patterns keyed by bundle id. Shared group
    /// containers are deliberately excluded.
    private nonisolated static func leftoverPaths(bundleID: String, teamID _: String) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let lib  = home.appendingPathComponent("Library")
        var paths: [URL] = [
            lib.appendingPathComponent("Application Support/\(bundleID)"),
            lib.appendingPathComponent("Caches/\(bundleID)"),
            lib.appendingPathComponent("Preferences/\(bundleID).plist"),
            lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            lib.appendingPathComponent("Logs/\(bundleID)"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID)"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            lib.appendingPathComponent("WebKit/\(bundleID)"),
            lib.appendingPathComponent("Containers/\(bundleID)"),
        ]
        // Group Containers may be shared by multiple apps from the same team.
        // Never include them in automatic removal.
        // LaunchAgents named after the bundle (vendor-installed startup helpers).
        let agents = lib.appendingPathComponent("LaunchAgents")
        if let entries = try? FileManager.default.contentsOfDirectory(at: agents,
            includingPropertiesForKeys: nil) {
            for e in entries where e.lastPathComponent.hasPrefix(bundleID) && e.pathExtension == "plist" {
                paths.append(e)
            }
        }
        return paths
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
        for case let item as URL in enumerator {
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
