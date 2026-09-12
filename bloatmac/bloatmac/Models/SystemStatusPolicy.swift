import Foundation

enum DiskSMARTStatus: String, Hashable {
    case verified = "Verified"
    case failing = "Failing"
    case unsupported = "Not Supported"
    case unknown = "Unknown"
}

enum SystemStatusPolicy {
    nonisolated static func volumeDeviceIdentifiers(in value: Any) -> [String] {
        var identifiers: [String] = []

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let identifier = dictionary["DeviceIdentifier"] as? String {
                    identifiers.append(identifier)
                }
                dictionary.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }

        visit(value)
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    nonisolated static func cloudInventoryID(provider: String, root: URL) -> String {
        "\(provider):\(root.standardizedFileURL.path)"
    }

    nonisolated static func diskSMARTStatus(_ rawValue: String?) -> DiskSMARTStatus {
        switch rawValue?.lowercased() {
        case "verified": return .verified
        case "failing", "fail": return .failing
        case "not supported": return .unsupported
        default: return .unknown
        }
    }

    nonisolated static func diskCapacity(_ info: [String: Any]) -> (total: Int64, free: Int64) {
        func bytes(_ key: String) -> Int64? {
            if let value = info[key] as? NSNumber { return value.int64Value }
            if let value = info[key] as? Int64 { return value }
            if let value = info[key] as? Int { return Int64(value) }
            return nil
        }
        return (
            bytes("APFSContainerSize") ?? bytes("TotalSize") ?? 0,
            bytes("APFSContainerFree") ?? bytes("FreeSpace") ?? 0
        )
    }

    nonisolated static func succeededIDs(requested: Set<String>, failed: Set<String>) -> Set<String> {
        requested.subtracting(failed)
    }

    nonisolated static func photosCleanupAllowed(runningBundleIdentifiers: Set<String>) -> Bool {
        !runningBundleIdentifiers.contains("com.apple.Photos")
    }

    nonisolated static func timeMachineSnapshotIdentifiers(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let identifier = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return identifier.hasPrefix("com.apple.TimeMachine.") ? identifier : nil
        }
    }

    nonisolated static func normalizedScheduleThreshold(_ bytes: Int64) -> Int64 {
        switch bytes {
        case 1_073_741_824: return 1_000_000_000
        case 5_368_709_120: return 5_000_000_000
        default: return bytes
        }
    }
}
