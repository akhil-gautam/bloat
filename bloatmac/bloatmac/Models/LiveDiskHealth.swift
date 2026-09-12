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
    let smartStatus: DiskSMARTStatus
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
    @Published private(set) var hasCompletedScan: Bool = false

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
        scanning = true; lastError = nil
        if volumes.isEmpty { hasCompletedScan = false }
        task = Task.detached(priority: .userInitiated) { await Self.runScan(generation: scanGeneration) }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil; scanning = false
    }

    // MARK: - Scan

    private nonisolated static func runScan(generation: Int) async {
        let result = scanVolumes()
        let snaps = countLocalSnapshots()
        await MainActor.run {
            let model = LiveDiskHealth.shared
            guard model.generation == generation, !Task.isCancelled else { return }
            model.volumes = result.volumes
            model.localSnapshotCount = snaps
            model.lastError = result.error
            model.hasCompletedScan = true
            model.scanning = false
        }
    }

    private nonisolated static func scanVolumes() -> (volumes: [DiskVolume], error: String?) {
        guard let plistData = run(["/usr/sbin/diskutil", "list", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any]
        else { return ([], "Disk information could not be read. Try re-scanning after reconnecting the volume.") }

        var rows: [DiskVolume] = []
        for bsd in SystemStatusPolicy.volumeDeviceIdentifiers(in: plist) {
            if let row = inspect(bsd: bsd) { rows.append(row) }
        }
        // De-dupe by BSD name; sort system volume first.
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.id).inserted }
        return (unique.sorted { ($0.isSystem ? 0 : 1) < ($1.isSystem ? 0 : 1) }, nil)
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
        guard info["VolumeName"] != nil || !mountPoint.isEmpty else { return nil }
        let capacity = SystemStatusPolicy.diskCapacity(info)
        let totalBytes = capacity.total
        let freeBytes = capacity.free
        let smart = SystemStatusPolicy.diskSMARTStatus(info["SMARTStatus"] as? String)
        let encrypted  = (info["Encryption"]        as? Bool)  ?? false
        let isInt      = (info["Internal"]          as? Bool)  ?? false
        let isSystem   = mountPoint == "/"
        if (info["OSInternal"] as? Bool) == true
            || (isInt && (mountPoint.isEmpty || mountPoint.hasPrefix("/System/Volumes/"))) {
            return nil
        }

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
        return SystemStatusPolicy.timeMachineSnapshotIdentifiers(in: out).count
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
