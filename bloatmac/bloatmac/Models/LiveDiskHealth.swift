import Foundation
import Combine

/// Read-only disk-health inventory: per-volume capacity, format, SMART
/// status, encryption, mount state, and a snapshot count for the boot
/// volume. All data sourced from `diskutil` and `tmutil` — no third-party
/// dependencies, no privileged access required.
struct DiskVolume: Identifiable, Hashable {
    let id: String           // BSDName, e.g. "disk3s1s1"
    let mountPoint: String   // "/" or "/Volumes/Foo" — empty when unmounted
    let name: String
    let format: String       // APFS, HFS+, ExFAT, …
    let totalBytes: Int64
    let freeBytes:  Int64
    let smartStatus: String  // "Verified" / "Failing" / "Not Supported"
    let isEncrypted: Bool
    let isInternal: Bool
    let isSystem: Bool       // is the boot volume

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedPct: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

@MainActor
final class LiveDiskHealth: ObservableObject {
    static let shared = LiveDiskHealth()

    @Published private(set) var volumes: [DiskVolume] = []
    @Published private(set) var localSnapshotCount: Int = 0
    @Published private(set) var scanning: Bool = false
    @Published private(set) var lastError: String? = nil

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if volumes.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() {
        task?.cancel(); task = nil; scanning = false
    }

    // MARK: - Scan

    private nonisolated static func runScan() async {
        let volumes = scanVolumes()
        let snaps = countLocalSnapshots()
        await MainActor.run {
            LiveDiskHealth.shared.volumes = volumes
            LiveDiskHealth.shared.localSnapshotCount = snaps
            LiveDiskHealth.shared.scanning = false
        }
    }

    private nonisolated static func scanVolumes() -> [DiskVolume] {
        guard let plistData = run(["/usr/sbin/diskutil", "list", "-plist", "external", "internal"]),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        var rows: [DiskVolume] = []
        for disk in allDisks {
            // Each entry has Partitions and/or APFSVolumes. We surface
            // every mountable volume, not the containers themselves.
            let partitions = (disk["Partitions"] as? [[String: Any]]) ?? []
            let apfsVols   = (disk["APFSVolumes"] as? [[String: Any]]) ?? []
            for vol in (partitions + apfsVols) {
                guard let bsd = vol["DeviceIdentifier"] as? String else { continue }
                if let row = inspect(bsd: bsd) { rows.append(row) }
            }
        }
        // De-dupe by BSD name; sort system volume first.
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.id).inserted }
        return unique.sorted { ($0.isSystem ? 0 : 1) < ($1.isSystem ? 0 : 1) }
    }

    private nonisolated static func inspect(bsd: String) -> DiskVolume? {
        guard let data = run(["/usr/sbin/diskutil", "info", "-plist", bsd]),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let mountPoint = (info["MountPoint"] as? String) ?? ""
        let name       = (info["VolumeName"] as? String) ?? bsd
        let format     = (info["FilesystemName"] as? String)
                      ?? (info["FilesystemType"] as? String) ?? "—"
        let totalBytes = Int64((info["TotalSize"]   as? Int) ?? 0)
        let freeBytes  = Int64((info["FreeSpace"]   as? Int) ?? 0)
        let smart      = (info["SMARTStatus"]       as? String) ?? "Not Supported"
        let encrypted  = (info["Encryption"]        as? Bool)  ?? false
        let isInt      = (info["Internal"]          as? Bool)  ?? false
        let isSystem   = mountPoint == "/"

        return DiskVolume(
            id: bsd, mountPoint: mountPoint,
            name: name, format: format,
            totalBytes: totalBytes, freeBytes: freeBytes,
            smartStatus: smart, isEncrypted: encrypted,
            isInternal: isInt, isSystem: isSystem
        )
    }

    private nonisolated static func countLocalSnapshots() -> Int {
        guard let out = run(["/usr/bin/tmutil", "listlocalsnapshots", "/"])
              .flatMap({ String(data: $0, encoding: .utf8) }) else { return 0 }
        return out.split(separator: "\n").count
    }

    // MARK: - Shell

    private nonisolated static func run(_ argv: [String]) -> Data? {
        guard !argv.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? pipe.fileHandleForReading.readToEnd()
    }
}
