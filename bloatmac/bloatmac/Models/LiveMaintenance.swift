import Foundation
import Combine
import AppKit

/// Periodic-maintenance launcher. Each `MaintenanceAction` describes one of
/// the routines CleanmyMac's "Performance" pane runs — DNS flush, RAM purge,
/// Spotlight reindex, Launch Services rebuild, etc.
///
/// Root-requiring actions escalate via NSAppleScript "with administrator
/// privileges" — pops a single OS password / TouchID prompt per click and
/// runs the command as root. No persistent helper needed; the alternative
/// (a full SMAppService daemon target with XPC) is overkill for four
/// rarely-run shell commands.
enum MaintenanceID: String, CaseIterable {
    case flushDNS, purgeRAM, periodic, reindexSpotlight, rebuildLSUser, rebuildLSSystem, verifyVolume
}

enum MaintenanceStatus { case idle, running, success, failed }

struct MaintenanceAction: Identifiable {
    let id: MaintenanceID
    let title: String
    let detail: String
    let impact: String
    let requiresHelper: Bool
    var status: MaintenanceStatus = .idle
    var output: String = ""
    var lastRunAt: Date? = nil
}

@MainActor
final class LiveMaintenance: ObservableObject {
    static let shared = LiveMaintenance()

    @Published var actions: [MaintenanceAction]
    private init() {
        actions = [
            .init(id: .flushDNS,         title: "Flush DNS cache",
                  detail: "Clear cached DNS lookups and restart name resolution.",
                  impact: "Network lookups may pause briefly while macOS rebuilds the cache.",
                  requiresHelper: true),
            .init(id: .purgeRAM,         title: "Purge inactive memory",
                  detail: "Ask macOS to discard inactive memory immediately.",
                  impact: "Apps may slow down temporarily as cached data is loaded again.",
                  requiresHelper: true),
            .init(id: .periodic,         title: "Run periodic scripts",
                  detail: "Run macOS daily, weekly, and monthly housekeeping scripts.",
                  impact: "This can take several minutes and may duplicate work macOS already schedules.",
                  requiresHelper: true),
            .init(id: .reindexSpotlight, title: "Reindex Spotlight",
                  detail: "Erase and rebuild the Spotlight index for the startup disk.",
                  impact: "Indexing can take hours and increase CPU, disk, and battery use.",
                  requiresHelper: true),
            .init(id: .rebuildLSUser,    title: "Rebuild Launch Services (user)",
                  detail: "Rebuild the current user's app and document-type registrations.",
                  impact: "Default-app associations and Open With menus may refresh.",
                  requiresHelper: false),
            .init(id: .rebuildLSSystem,  title: "Rebuild Launch Services (system)",
                  detail: "Rebuild local and system app registrations.",
                  impact: "Open With menus and app registrations may be temporarily incomplete.",
                  requiresHelper: true),
            .init(id: .verifyVolume,     title: "Verify startup disk",
                  detail: "Run a read-only filesystem verification on the startup volume.",
                  impact: "The check can take several minutes and may increase disk activity.",
                  requiresHelper: false),
        ]
    }

    func run(_ id: MaintenanceID) {
        guard let idx = actions.firstIndex(where: { $0.id == id }) else { return }
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
        // Root-required actions — escalate via AppleScript admin.
        case .flushDNS:
            return await runAsAdmin("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
        case .purgeRAM:
            return await runAsAdmin("/usr/sbin/purge")
        case .periodic:
            return await runAsAdmin("/usr/sbin/periodic daily weekly monthly")
        case .reindexSpotlight:
            return await runAsAdmin("/usr/bin/mdutil -E /")
        case .rebuildLSSystem:
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            return await runAsAdmin("\(lsregister) -kill -r -domain local -domain system")
        }
    }

    /// Run a shell command as root via AppleScript "with administrator
    /// privileges". macOS pops its native auth prompt (TouchID or
    /// password) showing BloatMac as the requester. Returns the combined
    /// stdout+stderr; success is determined by AppleScript not setting an
    /// error.
    @MainActor
    private static func runAsAdmin(_ shellCommand: String) async -> (Bool, String) {
        // AppleScript escaping: backslashes and double-quotes need to be
        // escaped inside the `do shell script` argument.
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "\(escaped) 2>&1" with administrator privileges
        """
        return await withCheckedContinuation { continuation in
            // NSAppleScript's executeAndReturnError isn't async, but it's
            // synchronous on the calling thread — wrap in a Task so we
            // don't block the caller.
            Task.detached {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: (false, "Couldn't compile AppleScript"))
                    return
                }
                var error: NSDictionary?
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
                    let msg  = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
                    // Code -128 is user-cancelled the auth prompt — treat as a
                    // soft failure with a friendlier message.
                    if code == -128 {
                        continuation.resume(returning: (false, "Cancelled — admin password not entered."))
                    } else {
                        continuation.resume(returning: (false, "AppleScript error \(code): \(msg)"))
                    }
                    return
                }
                let output = descriptor.stringValue ?? ""
                continuation.resume(returning: (true, output))
            }
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
