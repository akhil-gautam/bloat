import Foundation
import AppKit
import Combine

/// Heuristic threat-hygiene scan. macOS isn't Windows — the threat model is
/// supply-chain (dodgy LaunchAgents, sketchy browser extensions, malicious
/// Developer-ID-revoked apps, payloads dropped in Downloads but not yet
/// opened) rather than disk-resident PE viruses. Apple's XProtect already
/// handles signature-based detection; this module surfaces the heuristic
/// signals XProtect can't.
///
/// Four scan categories:
///
///  1. **Codesign audit** — `spctl -a -vvv` every /Applications/*.app and
///     classify by signing tier (Notarized → Developer-ID → self-signed →
///     unsigned → revoked).
///  2. **Persistence audit** — reuse `LiveStartup.items`, flag entries with
///     paths outside standard locations, hidden plist names, recent
///     creation, or risk-flagged publishers.
///  3. **Browser extensions** — list extensions for each detected
///     Chromium-family browser (and Firefox), surfacing the permission set.
///  4. **Quarantine residue** — executables in ~/Downloads and ~/Desktop
///     that still carry `com.apple.quarantine` (downloaded but not yet
///     opened — a common state for delivered-but-pending payloads).
enum HygieneCategory: String, CaseIterable {
    case codesign, persistence, browserExtensions, quarantine
    var label: String {
        switch self {
        case .codesign:          return "Codesign audit"
        case .persistence:       return "Persistence audit"
        case .browserExtensions: return "Browser extensions"
        case .quarantine:        return "Quarantine residue"
        }
    }
    var icon: String {
        switch self {
        case .codesign:          return "checkmark.seal"
        case .persistence:       return "powerplug"
        case .browserExtensions: return "puzzlepiece.extension"
        case .quarantine:        return "shippingbox"
        }
    }
}

enum HygieneSeverity: String { case ok, info, warning, critical
    var rank: Int {
        switch self { case .critical: 3; case .warning: 2; case .info: 1; case .ok: 0 }
    }
}

struct HygieneFinding: Identifiable, Hashable {
    let id: String              // path or composite key
    let category: HygieneCategory
    let severity: HygieneSeverity
    let title: String
    let detail: String
    let path: URL?              // tappable; nil for non-file findings
    let recommendation: String  // short user-facing next-step
}

@MainActor
final class LiveThreatHygiene: ObservableObject {
    static let shared = LiveThreatHygiene()

    @Published private(set) var findings: [HygieneFinding] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil

    var byCategory: [HygieneCategory: [HygieneFinding]] {
        Dictionary(grouping: findings, by: \.category)
    }

    /// Findings worth bothering the user with — drops the .ok rows that
    /// just confirm "X looks fine", to avoid burying the actionable ones.
    var actionable: [HygieneFinding] {
        findings.filter { $0.severity != .ok }
    }

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if findings.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true; findings = []; progress = 0
        phase = "Auditing /Applications…"
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() { task?.cancel(); task = nil; scanning = false }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: - Scan

    private nonisolated static func runScan() async {
        async let codesign        = scanCodesign()
        async let browser         = scanBrowserExtensions()
        async let quarantine      = scanQuarantineResidue()
        let persistence           = await scanPersistence()
        let collected             = await codesign + persistence + browser + quarantine
        // Sort: critical first, then warning, then info; within tier alphabetise by title.
        let sorted = collected.sorted { a, b in
            if a.severity.rank != b.severity.rank { return a.severity.rank > b.severity.rank }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        await MainActor.run {
            LiveThreatHygiene.shared.findings = sorted
            LiveThreatHygiene.shared.scanning = false
            LiveThreatHygiene.shared.progress = 1
            LiveThreatHygiene.shared.phase = "Done"
        }
    }

    // MARK: - 1. Codesign audit

    private nonisolated static func scanCodesign() async -> [HygieneFinding] {
        let fm = FileManager.default
        let appRoots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        var apps: [URL] = []
        for root in appRoots {
            if let entries = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                apps.append(contentsOf: entries.filter { $0.pathExtension == "app" })
            }
        }
        // Cap at first 80 apps to keep total scan time bounded — spctl
        // averages ~200 ms per call.
        let sample = Array(apps.prefix(80))
        var findings: [HygieneFinding] = []
        for app in sample {
            let (status, source, _) = spctlClassify(app)
            switch (status, source) {
            case (.accepted, .notarized):
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .ok,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Notarized · Developer ID",
                    path: app,
                    recommendation: ""))
            case (.accepted, .developerID):
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .info,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Developer ID, but not notarized",
                    path: app,
                    recommendation: "Older signed apps that predate notarization. Verify the developer is reputable before keeping."))
            case (.accepted, .appleSystem):
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .ok,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Apple System",
                    path: app,
                    recommendation: ""))
            case (.rejected, .unsigned):
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .warning,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Unsigned binary",
                    path: app,
                    recommendation: "App is not code-signed. Open only if you trust the source — anything could have modified the binary on disk."))
            case (.rejected, .revoked):
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .critical,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Revoked Developer ID",
                    path: app,
                    recommendation: "Apple has revoked this developer's signing certificate. Common reason: malware. Consider removing."))
            default:
                findings.append(HygieneFinding(
                    id: "codesign:\(app.path)",
                    category: .codesign, severity: .info,
                    title: app.deletingPathExtension().lastPathComponent,
                    detail: "Signed (other / non-Developer-ID)",
                    path: app,
                    recommendation: "Custom signing — usually fine for in-house tools, but worth verifying."))
            }
        }
        return findings
    }

    private enum SpctlStatus { case accepted, rejected }
    private enum SpctlSource { case notarized, developerID, appleSystem, unsigned, revoked, other }

    /// Run `spctl -a -vvv <app>` and classify the response. spctl prints
    /// to stderr and returns 0 on accept, non-zero on reject; the source
    /// classification is in the second line (e.g. `source=Notarized
    /// Developer ID`, `source=Developer ID`, `source=Apple System`).
    private nonisolated static func spctlClassify(_ app: URL) -> (SpctlStatus, SpctlSource, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        p.arguments = ["--assess", "--verbose=4", app.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (.rejected, .other, "spawn failed") }
        p.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data, encoding: .utf8) ?? ""
        let status: SpctlStatus = (p.terminationStatus == 0) ? .accepted : .rejected
        let source: SpctlSource
        if out.localizedCaseInsensitiveContains("revoked")           { source = .revoked }
        else if out.localizedCaseInsensitiveContains("notarized")    { source = .notarized }
        else if out.localizedCaseInsensitiveContains("apple system") { source = .appleSystem }
        else if out.localizedCaseInsensitiveContains("developer id") { source = .developerID }
        else if out.localizedCaseInsensitiveContains("unsigned")     { source = .unsigned }
        else if out.localizedCaseInsensitiveContains("not signed")   { source = .unsigned }
        else                                                         { source = .other }
        return (status, source, out)
    }

    // MARK: - 2. Persistence audit

    /// Standard launchd binary directories. Anything pointing OUTSIDE these
    /// gets a warning.
    private static let standardProgramRoots = [
        "/Applications/", "/usr/bin/", "/usr/sbin/", "/usr/local/", "/opt/",
        "/System/", "/Library/", "/bin/", "/sbin/",
    ]

    private static func scanPersistence() async -> [HygieneFinding] {
        // Pull the current LaunchAgent list from LiveStartup. If it hasn't
        // scanned yet, wait briefly for it.
        await MainActor.run {
            if LiveStartup.shared.items.isEmpty && !LiveStartup.shared.scanning {
                LiveStartup.shared.rescan()
            }
        }
        for _ in 0..<40 {
            let (done, count) = await MainActor.run { (!LiveStartup.shared.scanning, LiveStartup.shared.items.count) }
            if done && count > 0 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let items = await MainActor.run { LiveStartup.shared.items }

        var findings: [HygieneFinding] = []
        for item in items {
            var severity: HygieneSeverity = .ok
            var detail: String = item.scope.label
            var recommendation: String = ""

            if let prog = item.program, !prog.isEmpty {
                let inStandard = standardProgramRoots.contains { prog.hasPrefix($0) }
                let inHomeNonStandard = prog.hasPrefix(NSHomeDirectory()) && !prog.contains("/Library/")
                if !inStandard && (inHomeNonStandard || prog.hasPrefix("/private/tmp") || prog.hasPrefix("/tmp")) {
                    severity = .critical
                    detail   = "Program in non-standard path: \(prog)"
                    recommendation = "LaunchAgents that run binaries from temp / home is a classic persistence trick. Inspect the plist before keeping."
                } else if !inStandard {
                    severity = .warning
                    detail   = "Program: \(prog)"
                    recommendation = "Outside the usual install locations. Verify the app is something you knowingly installed."
                }
            }
            // Risk flag from LiveStartup's own classifier.
            if item.risk == .flagged && severity.rank < HygieneSeverity.critical.rank {
                severity = .critical
                detail = "Flagged publisher: \(item.publisher) · \(detail)"
                recommendation = "Publisher matches the bundled flagged-software list (MacKeeper, MacUpdater, etc)."
            } else if item.risk == .unknown && severity.rank < HygieneSeverity.warning.rank {
                severity = .warning
                detail = "Unknown publisher · \(detail)"
                recommendation = "Couldn't classify the publisher. Open the plist to check."
            }
            // Hidden plist names — leading-dot files are sometimes used to
            // hide LaunchAgents in casual ls.
            if item.id.lastPathComponent.hasPrefix(".") {
                severity = .critical
                detail = "Hidden plist filename · \(detail)"
                recommendation = "Persistence with a leading-dot filename is uncommon for legitimate software."
            }
            // Skip noise — only surface non-ok findings.
            guard severity != .ok else { continue }
            findings.append(HygieneFinding(
                id: "persistence:\(item.id.path)",
                category: .persistence, severity: severity,
                title: item.label,
                detail: detail,
                path: item.id,
                recommendation: recommendation))
        }
        return findings
    }

    // MARK: - 3. Browser extensions

    private nonisolated static func scanBrowserExtensions() async -> [HygieneFinding] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let appSupport = home.appendingPathComponent("Library/Application Support")
        var findings: [HygieneFinding] = []

        // Chromium-family — Chrome / Edge / Brave / Arc all share the same
        // Default/Extensions/<extId>/<version>/manifest.json layout.
        let chromiumRoots: [(String, String)] = [
            ("Google Chrome",  "Google/Chrome/Default/Extensions"),
            ("Microsoft Edge", "Microsoft Edge/Default/Extensions"),
            ("Brave",          "BraveSoftware/Brave-Browser/Default/Extensions"),
            ("Arc",            "Arc/User Data/Default/Extensions"),
        ]
        for (browser, sub) in chromiumRoots {
            let root = appSupport.appendingPathComponent(sub)
            findings.append(contentsOf: chromiumExtensions(at: root, browser: browser))
        }

        // Firefox — extensions.json under each profile, with .xpi files in
        // a sibling extensions/ dir. Lightweight read of the manifest is
        // enough for the audit.
        let fxProfiles = appSupport.appendingPathComponent("Firefox/Profiles")
        if let profiles = try? FileManager.default.contentsOfDirectory(at: fxProfiles,
            includingPropertiesForKeys: nil) {
            for profile in profiles {
                findings.append(contentsOf: firefoxExtensions(at: profile))
            }
        }

        return findings
    }

    private nonisolated static func chromiumExtensions(at root: URL, browser: String) -> [HygieneFinding] {
        guard let extDirs = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil) else { return [] }
        var findings: [HygieneFinding] = []
        for extDir in extDirs {
            // Each ext has a version subdirectory — pick the first/only one.
            guard let versions = try? FileManager.default.contentsOfDirectory(at: extDir,
                includingPropertiesForKeys: nil), let v = versions.first else { continue }
            let manifest = v.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Prefer default_locale + nested name resolution; fall back to raw name.
            let name = (json["name"] as? String) ?? extDir.lastPathComponent
            let permissions = (json["permissions"] as? [Any]) ?? []
            let hostPerms   = (json["host_permissions"] as? [String]) ?? []
            let permString  = (permissions.compactMap { $0 as? String } + hostPerms).joined(separator: ", ")

            // Severity heuristic — broad host permissions ("<all_urls>",
            // "*://*/*") get a warning; everything else is informational.
            var sev: HygieneSeverity = .info
            let perms = (permissions.compactMap { $0 as? String } + hostPerms).joined()
            if perms.contains("<all_urls>") || perms.contains("*://*/*") {
                sev = .warning
            }

            findings.append(HygieneFinding(
                id: "browserExt:\(browser):\(extDir.lastPathComponent)",
                category: .browserExtensions, severity: sev,
                title: "\(browser) · \(name)",
                detail: permString.isEmpty ? "No declared permissions" : permString,
                path: manifest,
                recommendation: sev == .warning
                    ? "Extension can read and modify any web page. Verify you actually use it."
                    : ""
            ))
        }
        return findings
    }

    private nonisolated static func firefoxExtensions(at profile: URL) -> [HygieneFinding] {
        let extJson = profile.appendingPathComponent("extensions.json")
        guard let data = try? Data(contentsOf: extJson),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = json["addons"] as? [[String: Any]] else { return [] }
        var findings: [HygieneFinding] = []
        for addon in addons {
            guard let active = addon["active"] as? Bool, active,
                  let type = addon["type"] as? String, type == "extension" else { continue }
            let nameField = (addon["defaultLocale"] as? [String: Any])?["name"] as? String
                         ?? (addon["name"] as? String) ?? "(unknown)"
            let id = (addon["id"] as? String) ?? UUID().uuidString
            let perms = (addon["userPermissions"] as? [String: Any])?["permissions"] as? [String] ?? []
            let permString = perms.joined(separator: ", ")
            findings.append(HygieneFinding(
                id: "browserExt:Firefox:\(id)",
                category: .browserExtensions, severity: .info,
                title: "Firefox · \(nameField)",
                detail: permString.isEmpty ? "No declared permissions" : permString,
                path: nil,
                recommendation: ""))
        }
        return findings
    }

    // MARK: - 4. Quarantine residue

    private nonisolated static func scanQuarantineResidue() async -> [HygieneFinding] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let roots = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
        ]
        let fm = FileManager.default
        var findings: [HygieneFinding] = []
        for root in roots {
            guard let urls = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in urls {
                // Only consider executables / disk images / installers.
                let ext = url.pathExtension.lowercased()
                let isInteresting = ext == "dmg" || ext == "pkg" || ext == "app"
                                 || ext == "zip" || ext == "tar" || ext == "gz"
                                 || (try? url.resourceValues(forKeys: [.isExecutableKey])
                                     .isExecutable) == true
                guard isInteresting else { continue }
                guard let qStr = quarantineXattr(url) else { continue }
                let parts = qStr.split(separator: ";")
                let from  = parts.dropFirst(2).first.map(String.init) ?? "unknown source"
                findings.append(HygieneFinding(
                    id: "quarantine:\(url.path)",
                    category: .quarantine, severity: .warning,
                    title: url.lastPathComponent,
                    detail: "Downloaded from \(from), still quarantined",
                    path: url,
                    recommendation: "If you don't recognise the source, delete instead of opening. The xattr clears on first launch."))
            }
        }
        return findings
    }

    private nonisolated static func quarantineXattr(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-p", "com.apple.quarantine", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
