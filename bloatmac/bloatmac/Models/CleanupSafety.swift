import CryptoKit
import Foundation

nonisolated struct CleanupCandidate<ID: Hashable> {
    let id: ID
    let url: URL
    let bytes: Int64
}

nonisolated struct TrashOutcome<ID: Hashable> {
    var succeeded: Set<ID> = []
    var bytes: Int64 = 0
    var failures: [String] = []
}

nonisolated struct ScanGeneration {
    private var value = 0

    mutating func next() -> Int {
        value &+= 1
        return value
    }

    func accepts(_ candidate: Int) -> Bool { candidate == value }
}

nonisolated enum OCRPolicy {
    nonisolated static let eligibleExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "webp", "gif",
    ]
    nonisolated static let maximumBytes: Int64 = 30_000_000

    nonisolated static func supports(fileExtension: String, sizeBytes: Int64) -> Bool {
        eligibleExtensions.contains(fileExtension.lowercased()) && sizeBytes <= maximumBytes
    }
}

nonisolated enum CleanupSafety {
    nonisolated static func fullFileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func deletionIDs<ID: Hashable>(from choices: [(ID, Bool)]) -> Set<ID> {
        guard choices.contains(where: { $0.1 }) else { return [] }
        return Set(choices.compactMap { $0.1 ? nil : $0.0 })
    }

    nonisolated static func hasExistingSurvivor<ID>(
        in choices: [(ID, Bool)],
        exists: (ID) -> Bool
    ) -> Bool {
        choices.contains { id, keep in keep && exists(id) }
    }

    /// Extra exact-duplicate opportunity after paths already represented by
    /// another category have been counted, while still reserving one copy.
    nonisolated static func additionalDuplicateBytes<ID: Hashable>(
        in items: [(ID, Int64)],
        excluding excluded: Set<ID>
    ) -> Int64 {
        let excludedCount = items.reduce(0) { $0 + (excluded.contains($1.0) ? 1 : 0) }
        let remainingSlots = max(0, items.count - 1 - excludedCount)
        return items.lazy
            .filter { !excluded.contains($0.0) }
            .prefix(remainingSlots)
            .reduce(Int64(0)) { $0 + $1.1 }
    }

    nonisolated static func isSameOrDescendant(_ url: URL, of roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    nonisolated static func performTrash<ID: Hashable>(
        _ candidates: [CleanupCandidate<ID>],
        using trash: (URL) throws -> Void
    ) -> TrashOutcome<ID> {
        var outcome = TrashOutcome<ID>()
        for candidate in candidates {
            do {
                try trash(candidate.url)
                outcome.succeeded.insert(candidate.id)
                outcome.bytes += candidate.bytes
            } catch {
                outcome.failures.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    nonisolated static func isManagedDependencyDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ["node_modules", "Pods", "Carthage", ".build", ".venv", "venv", ".git"].contains(name) {
            return true
        }
        return name == "bundle" && url.deletingLastPathComponent().lastPathComponent == "vendor"
    }

    nonisolated static func sqliteFiles(for database: URL) -> [URL] {
        let fm = FileManager.default
        return [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm")]
            .filter { fm.fileExists(atPath: $0.path) }
    }

    nonisolated static func isSharedContainer(_ url: URL) -> Bool {
        url.pathComponents.contains("Group Containers")
    }
}
