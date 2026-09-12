import Foundation

@main
enum SystemStatusPolicyCheck {
    static func main() {
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [[
                "DeviceIdentifier": "disk0",
                "Partitions": [[
                    "DeviceIdentifier": "disk0s2",
                    "APFSVolumes": [
                        ["DeviceIdentifier": "disk3s1"],
                        ["DeviceIdentifier": "disk3s2"],
                    ],
                ]],
            ]],
        ]
        precondition(SystemStatusPolicy.volumeDeviceIdentifiers(in: plist) == ["disk0", "disk0s2", "disk3s1", "disk3s2"])
        precondition(SystemStatusPolicy.diskSMARTStatus("Verified") == .verified)
        precondition(SystemStatusPolicy.diskSMARTStatus("Failing") == .failing)
        precondition(SystemStatusPolicy.diskSMARTStatus("Not Supported") == .unsupported)
        precondition(SystemStatusPolicy.diskSMARTStatus(nil) == .unknown)
        let capacity = SystemStatusPolicy.diskCapacity([
            "TotalSize": 494_384_795_648,
            "FreeSpace": 0,
            "APFSContainerSize": 494_384_795_648,
            "APFSContainerFree": 39_321_137_152,
        ])
        precondition(capacity.total == 494_384_795_648 && capacity.free == 39_321_137_152)

        let first = SystemStatusPolicy.cloudInventoryID(provider: "dropbox", root: URL(fileURLWithPath: "/Cloud/Dropbox-a"))
        let second = SystemStatusPolicy.cloudInventoryID(provider: "dropbox", root: URL(fileURLWithPath: "/Cloud/Dropbox-b"))
        precondition(first != second)

        precondition(SystemStatusPolicy.succeededIDs(requested: ["ok", "failed"], failed: ["failed"]) == ["ok"])
        precondition(!SystemStatusPolicy.photosCleanupAllowed(runningBundleIdentifiers: ["com.apple.Photos"]))
        precondition(SystemStatusPolicy.photosCleanupAllowed(runningBundleIdentifiers: ["com.apple.Safari"]))
        let snapshots = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-11-120000.local
          com.apple.TimeMachine.2026-09-12-083000.local

        """
        precondition(SystemStatusPolicy.timeMachineSnapshotIdentifiers(in: snapshots) == [
            "com.apple.TimeMachine.2026-09-11-120000.local",
            "com.apple.TimeMachine.2026-09-12-083000.local",
        ])
        precondition(SystemStatusPolicy.timeMachineSnapshotIdentifiers(in: "Snapshots for disk /:\n").isEmpty)
        precondition(SystemStatusPolicy.normalizedScheduleThreshold(1_073_741_824) == 1_000_000_000)
        print("SystemStatusPolicyCheck passed")
    }
}
