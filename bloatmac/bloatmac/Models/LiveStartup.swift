import Foundation
import SwiftUI
import Combine
import AppKit
import Darwin

enum StartupScope: String, CaseIterable, Identifiable {
    case userAgent      // ~/Library/LaunchAgents
    case adminAgent     // /Library/LaunchAgents
    case adminDaemon    // /Library/LaunchDaemons
    case systemAgent    // /System/Library/LaunchAgents
    case systemDaemon   // /System/Library/LaunchDaemons

    var id: String { rawValue }
    var path: String {
        switch self {
        case .userAgent:    return "\(NSHomeDirectory())/Library/LaunchAgents"
        case .adminAgent:   return "/Library/LaunchAgents"
        case .adminDaemon:  return "/Library/LaunchDaemons"
        case .systemAgent:  return "/System/Library/LaunchAgents"
        case .systemDaemon: return "/System/Library/LaunchDaemons"
        }
    }
    var label: String {
        switch self {
        case .userAgent:    return "User agents"
        case .adminAgent:   return "Admin agents"
        case .adminDaemon:  return "Admin daemons"
        case .systemAgent:  return "System agents"
        case .systemDaemon: return "System daemons"
        }
    }
    var shortLabel: String {
        switch self {
        case .userAgent:    return "User"
        case .adminAgent:   return "Admin"
        case .adminDaemon:  return "Daemon"
        case .systemAgent:  return "System"
        case .systemDaemon: return "Sys-D"
        }
    }
    var color: Color {
        switch self {
        case .userAgent:    return Tokens.catApps
        case .adminAgent:   return Tokens.purple
        case .adminDaemon:  return Tokens.pink
        case .systemAgent:  return Tokens.text3
        case .systemDaemon: return Tokens.text4
        }
    }
    var isWritable: Bool { self == .userAgent }
    var isDaemon: Bool   { self == .adminDaemon || self == .systemDaemon }
}

enum StartupRisk: Int { case known = 0, unknown = 1, flagged = 2
    var label: String {
        switch self { case .known: return "Known"; case .unknown: return "Unverified"; case .flagged: return "Review" }
    }
    var color: Color {
        switch self { case .known: return Tokens.good; case .unknown: return Tokens.warn; case .flagged: return Tokens.danger }
    }
}

struct LaunchAgentItem: Identifiable, Hashable {
    let id: URL                 // plist URL
    let label: String           // bundle id / Label key
    let scope: StartupScope
    let program: String?        // resolved executable
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let isLoaded: Bool          // appears in `launchctl list`
    let pid: Int?
    let exitCode: Int?
    let isDisabled: Bool        // appears in print-disabled
    let lastModified: Date?
    let appName: String?
    let appIcon: NSImage?
    let appBundleURL: URL?
    let publisher: String       // for AI risk classification
    let risk: StartupRisk

    var displayName: String { appName ?? label }
    var sourceLabel: String { scope.label }
    var canRemove: Bool { scope.isWritable }
    var statePill: String {
        if isLoaded { return "Loaded" }
        if isDisabled { return "Disabled" }
        return "Idle"
    }
    var stateColor: Color {
        if isLoaded { return Tokens.good }
        if isDisabled { return Tokens.text3 }
        return Tokens.warn
    }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: LaunchAgentItem, b: LaunchAgentItem) -> Bool { a.id == b.id }
}

enum StartupFilter: String, CaseIterable, Identifiable {
    case all, loaded, disabled, idle, writable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"; case .loaded: "Loaded"; case .disabled: "Disabled"
        case .idle: "Idle"; case .writable: "User-removable"
        }
    }
}

enum StartupSort: String, CaseIterable, Identifiable {
    case name = "Name", scope = "Scope", state = "State", risk = "Risk"
    var id: String { rawValue }
}

@MainActor
final class LiveStartup: ObservableObject {
    static let shared = LiveStartup()

    @Published private(set) var items: [LaunchAgentItem] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil
    @Published var search: String = ""
    @Published var filter: StartupFilter = .all
    @Published var sort: StartupSort = .name
    @Published var scopeFilter: Set<StartupScope> = Set(StartupScope.allCases)

    /// Memoized filtered+sorted view. Recomputed only when inputs change,
    /// not on every SwiftUI body evaluation.
    @Published private(set) var visible: [LaunchAgentItem] = []
    private var pipelineCancellables = Set<AnyCancellable>()

    var counts: [StartupScope: Int] {
        var d: [StartupScope: Int] = [:]
        for i in items { d[i.scope, default: 0] += 1 }
        return d
    }
    var loadedCount: Int { items.filter(\.isLoaded).count }
    var disabledCount: Int { items.filter(\.isDisabled).count }
    var unknownCount: Int { items.filter { $0.risk == .unknown }.count }


    private init() {
        // Recompute the visible list only when an input actually changes,
        // and debounce the search field so typing doesn't refilter on every keystroke.
        let inputs = Publishers.CombineLatest4(
            $items,
            $search.removeDuplicates().debounce(for: .milliseconds(120), scheduler: RunLoop.main),
            $filter.removeDuplicates(),
            $sort.removeDuplicates()
        ).combineLatest($scopeFilter)

        inputs
            .map { combined, scopes -> [LaunchAgentItem] in
                let (items, search, filter, sort) = combined
                return Self.applyPipeline(items: items, search: search, filter: filter, sort: sort, scopes: scopes)
            }
            .receive(on: RunLoop.main)
            .assign(to: &$visible)
    }

    func startIfNeeded() {
        if items.isEmpty && !scanning { rescan() }
    }

    nonisolated private static func applyPipeline(items: [LaunchAgentItem], search: String,
                                                  filter: StartupFilter, sort: StartupSort,
                                                  scopes: Set<StartupScope>) -> [LaunchAgentItem] {
        var rows = items.filter { scopes.contains($0.scope) }
        switch filter {
        case .all:      break
        case .loaded:   rows = rows.filter(\.isLoaded)
        case .disabled: rows = rows.filter(\.isDisabled)
        case .idle:     rows = rows.filter { !$0.isLoaded && !$0.isDisabled }
        case .writable: rows = rows.filter(\.canRemove)
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.label.lowercased().contains(q)
                    || ($0.appName ?? "").lowercased().contains(q)
                    || ($0.program ?? "").lowercased().contains(q)
                    || $0.publisher.lowercased().contains(q)
            }
        }
        switch sort {
        case .name:  rows.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .scope:
            rows.sort {
                if $0.scope.rawValue != $1.scope.rawValue { return $0.scope.rawValue < $1.scope.rawValue }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .state:
            rows.sort {
                let a = $0.isLoaded ? 0 : ($0.isDisabled ? 2 : 1)
                let b = $1.isLoaded ? 0 : ($1.isDisabled ? 2 : 1)
                if a != b { return a < b }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .risk:  rows.sort { $0.risk.rawValue > $1.risk.rawValue }
        }
        return rows
    }

    func rescan() {
        scanning = true
        items = []
        phase = "Reading directories…"
        progress = 0
        Task.detached(priority: .userInitiated) {
            await Self.publish(phase: "Reading directories…", progress: 0.05)
            let scoped = Self.scanAllScopes()

            await Self.publish(phase: "Querying launchctl list…", progress: 0.15)
            let loaded = Self.launchctlListed()

            await Self.publish(phase: "Querying disabled jobs…", progress: 0.25)
            let disabled = Self.launchctlDisabled()

            // First pass: build items WITHOUT touching NSWorkspace/Bundle (those
            // have main-thread affinity and can hang from a detached task).
            var all: [LaunchAgentItem] = []
            let totalScopes = max(scoped.count, 1)
            for (idx, pair) in scoped.enumerated() {
                let (scope, plists) = pair
                await Self.publish(phase: "Parsing \(scope.label)…",
                                   progress: 0.25 + 0.40 * Double(idx) / Double(totalScopes))
                for url in plists {
                    if let item = Self.makeItemFast(at: url, scope: scope, loaded: loaded, disabled: disabled) {
                        all.append(item)
                    }
                }
            }
            // Resolve enclosing .app names off-main (Bundle plist reads are safe on
            // a background executor; only NSWorkspace.icon has main affinity, and
            // we defer that to per-row lazy loading).
            await Self.publish(phase: "Resolving bundles…", progress: 0.75)
            for i in all.indices {
                if let prog = all[i].program {
                    var u = URL(fileURLWithPath: prog)
                    while u.path != "/" {
                        if u.pathExtension == "app" {
                            let bundle = Bundle(url: u)
                            let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                                    ?? bundle?.infoDictionary?["CFBundleName"] as? String
                                    ?? u.deletingPathExtension().lastPathComponent
                            all[i] = LaunchAgentItem(
                                id: all[i].id, label: all[i].label, scope: all[i].scope,
                                program: all[i].program, arguments: all[i].arguments,
                                runAtLoad: all[i].runAtLoad, keepAlive: all[i].keepAlive,
                                isLoaded: all[i].isLoaded, pid: all[i].pid, exitCode: all[i].exitCode,
                                isDisabled: all[i].isDisabled, lastModified: all[i].lastModified,
                                appName: name, appIcon: nil, appBundleURL: u,
                                publisher: all[i].publisher, risk: all[i].risk
                            )
                            break
                        }
                        u.deleteLastPathComponent()
                    }
                }
            }
            await MainActor.run {
                LiveStartup.shared.items = all
                LiveStartup.shared.scanning = false
                LiveStartup.shared.phase = "Done"
                LiveStartup.shared.progress = 1.0
            }
        }
    }

    nonisolated private static func publish(phase: String, progress: Double) async {
        await MainActor.run {
            LiveStartup.shared.phase = phase
            LiveStartup.shared.progress = progress
        }
    }

    /// Bootout the agent (if loaded) and trash the plist file.
    @discardableResult
    func remove(_ item: LaunchAgentItem) -> Bool {
        guard item.canRemove else {
            lastError = "Removing items in \(item.scope.label) requires admin rights. Edit them via Login Items in System Settings."
            return false
        }
        // bootout — best effort, may fail if not loaded
        let domain = "gui/\(getuid())"
        _ = Self.runShell("/bin/launchctl", ["bootout", domain, item.id.path])
        do {
            try FileManager.default.trashItem(at: item.id, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            return true
        } catch {
            lastError = "Trash failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setEnabled(_ item: LaunchAgentItem, enabled: Bool) -> Bool {
        guard item.canRemove else { return false }
        let domain = "gui/\(getuid())"
        let action = enabled ? "enable" : "disable"
        let ok = Self.runShell("/bin/launchctl", [action, "\(domain)/\(item.label)"]) != nil
        if !ok { lastError = "launchctl \(action) failed" }
        rescan()
        return ok
    }

    func revealInFinder(_ item: LaunchAgentItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.id])
    }

    func openPlist(_ item: LaunchAgentItem) {
        NSWorkspace.shared.open(item.id)
    }

    func openProgram(_ item: LaunchAgentItem) {
        guard let p = item.program else { return }
        let url = URL(fileURLWithPath: p)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Scanning

    nonisolated private static func scanAllScopes() -> [(StartupScope, [URL])] {
        let fm = FileManager.default
        var out: [(StartupScope, [URL])] = []
        for scope in StartupScope.allCases {
            let dir = scope.path
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let urls = entries
                .filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
                .map { URL(fileURLWithPath: "\(dir)/\($0)") }
            out.append((scope, urls))
        }
        return out
    }

    /// Build everything we can without touching NSWorkspace/Bundle (those have
    /// main-thread affinity and can hang from a detached executor).
    nonisolated private static func makeItemFast(at url: URL, scope: StartupScope,
                                                 loaded: [String: (Int?, Int?)],
                                                 disabled: Set<String>) -> LaunchAgentItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program = (plist["Program"] as? String)
        let progArgs = plist["ProgramArguments"] as? [String]
        let resolvedProgram = program ?? progArgs?.first
        let args = progArgs ?? []
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let keepAlive: Bool = {
            if let b = plist["KeepAlive"] as? Bool { return b }
            if plist["KeepAlive"] is [String: Any] { return true }
            return false
        }()
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path))
        let mod = attrs?[.modificationDate] as? Date

        let listed = loaded[label]
        let pid = listed?.0
        let exit = listed?.1
        let isLoaded = pid != nil && (pid ?? 0) > 0

        let publisher = inferPublisher(label: label, program: resolvedProgram)
        let risk = classifyRisk(label: label, publisher: publisher, scope: scope)

        return LaunchAgentItem(
            id: url,
            label: label,
            scope: scope,
            program: resolvedProgram,
            arguments: args,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isLoaded: isLoaded,
            pid: pid,
            exitCode: exit,
            isDisabled: disabled.contains(label),
            lastModified: mod,
            appName: nil,
            appIcon: nil,
            appBundleURL: nil,
            publisher: publisher,
            risk: risk
        )
    }

    nonisolated private static func inferPublisher(label: String, program: String?) -> String {
        // Use the second component of reverse-DNS labels, e.g. com.apple.foo → apple
        let parts = label.split(separator: ".")
        if parts.count >= 2 {
            let p = String(parts[1]).lowercased()
            if p.count <= 24 { return p }
        }
        if let prog = program, let appRange = prog.range(of: ".app/") {
            return String(prog[..<appRange.lowerBound]).split(separator: "/").last.map { $0.lowercased() } ?? ""
        }
        return ""
    }

    private static let knownPublishers: Set<String> = [
        "apple", "google", "microsoft", "homebrew", "docker", "jetbrains",
        "vmware", "parallels", "oracle", "amazon", "github", "gitlab",
        "1password", "dropbox", "slack", "zoom", "logitech", "elgato",
        "obs", "nvidia", "amd", "intel", "tailscale", "anthropic", "spotify",
        "adobe", "wacom", "valve", "steam", "logitechg", "razer", "corsair",
        "littlesnitch", "objectiveseelite", "bartender", "alfred", "raycast",
        "rectangle", "magnet", "cleanshot", "synology", "synergy",
    ]
    private static let flaggedPatterns: [String] = [
        "macupdater.helper", "macupgrade", "machelper", "supercleaner",
        "advancedmackeeper", "mackeeper", "yourmac", "youtubeunblocker",
        "mediadownloader", "torrent", "kuaiya", "rdmagent",
    ]

    nonisolated private static func classifyRisk(label: String, publisher: String, scope: StartupScope) -> StartupRisk {
        let lower = label.lowercased()
        if flaggedPatterns.contains(where: { lower.contains($0) }) { return .flagged }
        if knownPublishers.contains(publisher) { return .known }
        // System paths are inherently apple/system
        if scope == .systemAgent || scope == .systemDaemon { return .known }
        return .unknown
    }

    // MARK: - launchctl

    nonisolated private static func launchctlListed() -> [String: (Int?, Int?)] {
        guard let out = runShell("/bin/launchctl", ["list"]) else { return [:] }
        var result: [String: (Int?, Int?)] = [:]
        for line in out.split(separator: "\n").dropFirst() {  // first line is header
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let pidRaw = parts[0].trimmingCharacters(in: .whitespaces)
            let exitRaw = parts[1].trimmingCharacters(in: .whitespaces)
            let label = parts[2].trimmingCharacters(in: .whitespaces)
            let pid: Int? = pidRaw == "-" ? nil : Int(pidRaw)
            let exit: Int? = Int(exitRaw)
            result[label] = (pid, exit)
        }
        return result
    }

    nonisolated private static func launchctlDisabled() -> Set<String> {
        let domain = "gui/\(getuid())"
        guard let out = runShell("/bin/launchctl", ["print-disabled", domain]) else { return [] }
        var result = Set<String>()
        // Lines like:  "com.example.foo" => disabled
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("=>") else { continue }
            let parts = trimmed.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
            let state = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if state.contains("disabled") && !state.contains("enabled") { result.insert(label) }
        }
        return result
    }

    nonisolated private static func runShell(_ exec: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
