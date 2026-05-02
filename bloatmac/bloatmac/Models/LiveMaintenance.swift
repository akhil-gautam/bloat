import Foundation
import Combine

/// Periodic-maintenance launcher. Each `MaintenanceAction` describes one of
/// the routines CleanmyMac's "Performance" pane runs — DNS flush, RAM purge,
/// Spotlight reindex, Launch Services rebuild, etc.
///
/// Most of these poke system-owned files and require root. Those rows are
/// currently disabled and tagged "needs privileged helper" — they'll come
/// alive when Phase 8.2 lands. The rows that genuinely don't need root
/// (volume verify, user-domain Launch Services rebuild) run today.
enum MaintenanceID: String, CaseIterable {
    case flushDNS, purgeRAM, periodic, reindexSpotlight, rebuildLSUser, rebuildLSSystem, verifyVolume, repairPermissions
}

enum MaintenanceStatus { case idle, running, success, failed }

struct MaintenanceAction: Identifiable {
    let id: MaintenanceID
    let title: String
    let detail: String
    let requiresHelper: Bool
    var status: MaintenanceStatus = .idle
    var output: String = ""
    var lastRunAt: Date? = nil
}

@MainActor
final class LiveMaintenance: ObservableObject {
    static let shared = LiveMaintenance()

    @Published var actions: [MaintenanceAction]
    @Published private(set) var helperAvailable: Bool = false   // becomes true when Phase 8.2 ships

    private init() {
        actions = [
            .init(id: .flushDNS,         title: "Flush DNS cache",
                  detail: "dscacheutil -flushcache && killall -HUP mDNSResponder",
                  requiresHelper: true),
            .init(id: .purgeRAM,         title: "Purge inactive memory",
                  detail: "/usr/sbin/purge",
                  requiresHelper: true),
            .init(id: .periodic,         title: "Run periodic scripts",
                  detail: "/usr/sbin/periodic daily weekly monthly",
                  requiresHelper: true),
            .init(id: .reindexSpotlight, title: "Reindex Spotlight",
                  detail: "mdutil -E /",
                  requiresHelper: true),
            .init(id: .rebuildLSUser,    title: "Rebuild Launch Services (user)",
                  detail: "lsregister -kill -r -domain user",
                  requiresHelper: false),
            .init(id: .rebuildLSSystem,  title: "Rebuild Launch Services (system)",
                  detail: "lsregister -kill -r -domain local -domain system",
                  requiresHelper: true),
            .init(id: .verifyVolume,     title: "Verify startup disk",
                  detail: "diskutil verifyVolume /",
                  requiresHelper: false),
            .init(id: .repairPermissions,title: "Repair disk permissions",
                  detail: "Deprecated since macOS 10.11 — system installer handles this now.",
                  requiresHelper: false),
        ]
    }

    func run(_ id: MaintenanceID) {
        guard let idx = actions.firstIndex(where: { $0.id == id }) else { return }
        if actions[idx].requiresHelper && !helperAvailable {
            actions[idx].status = .failed
            actions[idx].output = "Privileged helper not installed. Install BloatMac v1.0 with Developer ID signing to enable."
            return
        }
        actions[idx].status = .running
        actions[idx].output = ""
        let action = actions[idx]
        Task.detached(priority: .userInitiated) {
            let (ok, output) = await Self.execute(action)
            await MainActor.run {
                guard let i = LiveMaintenance.shared.actions.firstIndex(where: { $0.id == id }) else { return }
                LiveMaintenance.shared.actions[i].status = ok ? .success : .failed
                LiveMaintenance.shared.actions[i].output = output
                LiveMaintenance.shared.actions[i].lastRunAt = Date()
                if ok {
                    CleanupLog.record(module: .maintenance, itemCount: 1, bytes: 0)
                }
            }
        }
    }

    func runAll() {
        for action in actions where !action.requiresHelper || helperAvailable {
            run(action.id)
        }
    }

    // MARK: - Execution

    private nonisolated static func execute(_ action: MaintenanceAction) async -> (Bool, String) {
        switch action.id {
        case .verifyVolume:
            return shell(["/usr/sbin/diskutil", "verifyVolume", "/"])
        case .rebuildLSUser:
            // lsregister at the well-known path. -domain user requires no
            // privilege escalation.
            let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            return shell([path, "-kill", "-r", "-domain", "user"])
        case .repairPermissions:
            // No-op — surface the educational note and call it a success.
            return (true, "Skipped: macOS handles this automatically since 10.11 El Capitan.")
        default:
            return (false, "Privileged helper not installed.")
        }
    }

    @discardableResult
    private nonisolated static func shell(_ argv: [String]) -> (Bool, String) {
        guard !argv.isEmpty else { return (false, "empty argv") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch {
            return (false, "Couldn't launch \(argv[0]): \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, text)
    }
}
