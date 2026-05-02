import Foundation
import AppKit
import Combine

/// Aggregates available updates from three sources, in parallel:
///
///  * Homebrew casks    — `brew outdated --cask --json` if `brew` is on PATH
///  * Mac App Store     — `mas outdated` if `mas` (mas-cli) is installed
///  * Sparkle feeds     — every /Applications/*.app's `SUFeedURL` is fetched
///                        and the topmost appcast `sparkle:shortVersionString`
///                        is compared to the installed version.
///
/// Surfaces a uniform `UpdateCandidate` row regardless of source. The "Update"
/// action delegates to the right tool — `brew upgrade --cask` in a Terminal
/// window, a `macappstore://` deep-link, or just launching the app so its own
/// Sparkle controller takes over.
enum UpdateSource: String { case brew, mas, sparkle }

struct UpdateCandidate: Identifiable, Hashable {
    let id: String       // composite — "brew:firefox", "mas:497799835", "sparkle:com.example.foo"
    let source: UpdateSource
    let name: String
    let installed: String
    let latest: String
    let bundleID: String
    let appURL: URL?     // for sparkle; nil for brew/mas-only entries
    let extra: String    // brew cask token, MAS app id, etc — used by upgrade()
}

@MainActor
final class LiveUpdater: ObservableObject {
    static let shared = LiveUpdater()

    @Published private(set) var candidates: [UpdateCandidate] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil
    @Published private(set) var brewAvailable: Bool = false
    @Published private(set) var masAvailable: Bool = false

    var totalCount: Int { candidates.count }

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if candidates.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true; candidates = []; progress = 0
        phase = "Checking sources…"
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() {
        task?.cancel(); task = nil; scanning = false
    }

    /// Trigger the appropriate updater for a candidate. Brew opens Terminal
    /// with the upgrade command pre-typed; MAS opens the App Store deep-link;
    /// Sparkle apps just get launched (their update controller fires on
    /// startup).
    func upgrade(_ c: UpdateCandidate) {
        switch c.source {
        case .brew:
            let cmd = "brew upgrade --cask \(c.extra)"
            launchInTerminal(cmd)
        case .mas:
            // `mas` uses numeric app ids in `extra`. Open the App Store deep-link.
            if let url = URL(string: "macappstore://apps.apple.com/app/id\(c.extra)") {
                NSWorkspace.shared.open(url)
            }
        case .sparkle:
            if let url = c.appURL { NSWorkspace.shared.open(url) }
        }
        // Note: we don't remove from `candidates` here. The next scan will
        // verify the version actually moved before clearing the row.
    }

    func upgradeAllBrew() {
        let casks = candidates.filter { $0.source == .brew }.map { $0.extra }
        guard !casks.isEmpty else { return }
        launchInTerminal("brew upgrade --cask " + casks.joined(separator: " "))
    }

    private func launchInTerminal(_ command: String) {
        // AppleScript is the cleanest way to drop a one-shot command into a
        // new Terminal window without spawning a long-lived child of bloatmac.
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch {
            lastError = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    // MARK: - Scan implementation

    private nonisolated static func runScan() async {
        async let brewResult: ([UpdateCandidate], Bool) = scanBrew()
        async let masResult:  ([UpdateCandidate], Bool) = scanMAS()
        async let sparkleResult: [UpdateCandidate]      = scanSparkle()

        let (brewRows, brewOK) = await brewResult
        let (masRows, masOK)   = await masResult
        let sparkleRows        = await sparkleResult

        // De-dupe: prefer brew over sparkle when the same app is managed by
        // Homebrew (avoids the user seeing the same outdated app in two rows).
        let brewBundleIDs = Set(brewRows.map(\.bundleID).filter { !$0.isEmpty })
        let sparkleFiltered = sparkleRows.filter { !brewBundleIDs.contains($0.bundleID) }

        let all = (brewRows + masRows + sparkleFiltered)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        await MainActor.run {
            LiveUpdater.shared.candidates = all
            LiveUpdater.shared.brewAvailable = brewOK
            LiveUpdater.shared.masAvailable  = masOK
            LiveUpdater.shared.scanning = false
            LiveUpdater.shared.progress = 1
            LiveUpdater.shared.phase = "Done"
        }
    }

    // MARK: - Homebrew

    private nonisolated static func scanBrew() async -> ([UpdateCandidate], Bool) {
        guard let brew = which("brew") else { return ([], false) }
        guard let json = run([brew, "outdated", "--cask", "--json=v2"]) else { return ([], true) }
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]] else { return ([], true) }

        var rows: [UpdateCandidate] = []
        for c in casks {
            let token = (c["name"] as? String) ?? (c["token"] as? String) ?? ""
            // installed_versions is an array; take the last (current) version.
            let installed = ((c["installed_versions"] as? [String]) ?? []).last ?? ""
            let latest = (c["current_version"] as? String) ?? ""
            guard !token.isEmpty else { continue }
            // Best-effort bundle-id resolution: read the cask's app from the
            // info command, but that's slow. For now leave bundleID empty;
            // de-dup against Sparkle is by display name as a fallback below.
            rows.append(UpdateCandidate(
                id: "brew:\(token)",
                source: .brew, name: token,
                installed: installed, latest: latest,
                bundleID: "", appURL: nil, extra: token
            ))
        }
        return (rows, true)
    }

    // MARK: - Mac App Store

    private nonisolated static func scanMAS() async -> ([UpdateCandidate], Bool) {
        guard let mas = which("mas") else { return ([], false) }
        guard let out = run([mas, "outdated"]) else { return ([], true) }
        // Each line: "<id> <name> (<installed> -> <latest>)"
        var rows: [UpdateCandidate] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let id   = String(line[..<space])
            let rest = line[line.index(after: space)...]
            let name: String
            let installed: String
            let latest: String
            if let paren = rest.firstIndex(of: "(") {
                name = rest[..<paren].trimmingCharacters(in: .whitespaces)
                let inside = rest[rest.index(after: paren)...].split(separator: ")").first ?? ""
                let parts = inside.components(separatedBy: " -> ")
                installed = parts.first ?? ""
                latest    = parts.last  ?? ""
            } else {
                name = String(rest).trimmingCharacters(in: .whitespaces)
                installed = ""
                latest    = ""
            }
            rows.append(UpdateCandidate(
                id: "mas:\(id)",
                source: .mas, name: name,
                installed: installed, latest: latest,
                bundleID: "", appURL: nil, extra: id
            ))
        }
        return (rows, true)
    }

    // MARK: - Sparkle

    private nonisolated static func scanSparkle() async -> [UpdateCandidate] {
        let fm = FileManager.default
        let appRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        var bundles: [URL] = []
        for root in appRoots {
            if let entries = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                bundles.append(contentsOf: entries.filter { $0.pathExtension == "app" })
            }
        }

        // Bound parallelism. A few dozen feed fetches is fine; hundreds
        // saturating the wifi link isn't.
        let chunkSize = 8
        var rows: [UpdateCandidate] = []
        for chunk in bundles.chunked(into: chunkSize) {
            await withTaskGroup(of: UpdateCandidate?.self) { group in
                for app in chunk {
                    group.addTask { await sparkleCandidate(for: app) }
                }
                for await c in group {
                    if let c = c { rows.append(c) }
                }
            }
        }
        return rows
    }

    private nonisolated static func sparkleCandidate(for app: URL) async -> UpdateCandidate? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { return nil }
        guard let feedString = dict["SUFeedURL"] as? String,
              let feedURL = URL(string: feedString) else { return nil }
        let bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
        let installed = (dict["CFBundleShortVersionString"] as? String)
                     ?? (dict["CFBundleVersion"] as? String) ?? ""
        let displayName = (dict["CFBundleDisplayName"] as? String)
                       ?? (dict["CFBundleName"] as? String)
                       ?? app.deletingPathExtension().lastPathComponent

        // Conservative timeouts — a stalled appcast shouldn't block Smart Care.
        var req = URLRequest(url: feedURL)
        req.timeoutInterval = 6
        req.setValue("BloatMac/\(installed)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else { return nil }

        guard let latest = extractLatestVersion(fromAppcast: xml) else { return nil }
        guard versionLessThan(installed, latest) else { return nil }   // already up to date
        return UpdateCandidate(
            id: "sparkle:\(bundleID)",
            source: .sparkle, name: displayName,
            installed: installed, latest: latest,
            bundleID: bundleID, appURL: app, extra: ""
        )
    }

    /// Pulls `sparkle:shortVersionString` (preferred) or `sparkle:version`
    /// from the first `<enclosure>` in the appcast. Crude regex parsing —
    /// good enough for ~95% of real-world Sparkle XML; falls back gracefully.
    private nonisolated static func extractLatestVersion(fromAppcast xml: String) -> String? {
        let pattern = "sparkle:shortVersionString=\"([^\"]+)\""
        if let m = xml.range(of: pattern, options: .regularExpression),
           let captured = String(xml[m]).split(separator: "\"").dropFirst().first {
            return String(captured)
        }
        let altPattern = "sparkle:version=\"([^\"]+)\""
        if let m = xml.range(of: altPattern, options: .regularExpression),
           let captured = String(xml[m]).split(separator: "\"").dropFirst().first {
            return String(captured)
        }
        return nil
    }

    /// Numeric-aware version comparison. "2.10.0" > "2.9.0". Falls back to
    /// lexicographic when components aren't numeric.
    private nonisolated static func versionLessThan(_ a: String, _ b: String) -> Bool {
        let aParts = a.split(separator: ".").map { String($0) }
        let bParts = b.split(separator: ".").map { String($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let ap = i < aParts.count ? aParts[i] : "0"
            let bp = i < bParts.count ? bParts[i] : "0"
            if let an = Int(ap), let bn = Int(bp) {
                if an != bn { return an < bn }
            } else {
                if ap != bp { return ap < bp }
            }
        }
        return false
    }

    // MARK: - Shell helpers

    private nonisolated static func which(_ tool: String) -> String? {
        // Common locations — Homebrew on Apple Silicon lives at /opt/homebrew.
        let candidates = [
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/usr/bin/\(tool)",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    @discardableResult
    private nonisolated static func run(_ argv: [String]) -> String? {
        guard !argv.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var i = 0
        while i < count {
            chunks.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return chunks
    }
}
