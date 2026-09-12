import Foundation

enum CheckFailure: Error {
    case expectedFailure
}

@main
struct CleanupSafetyCheck {
    static func main() throws {
        try fullHashesRejectOldSampleCollision()
        survivorPolicyNeverDeletesEveryCopy()
        missingKeptCopyRejectsDeletion()
        duplicatePotentialDoesNotDoubleCountPaths()
        nestedPathsAreRecognizedAsAlreadyCounted()
        failedTrashTargetsRemain()
        staleGenerationCannotPublish()
        ocrBoundsAreExplicit()
        managedDependenciesAreExcluded()
        try sqliteSidecarsStayGrouped()
        sharedContainersAreProtected()
        print("cleanup safety checks passed")
    }

    private static func fullHashesRejectOldSampleCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bloatmac-hash-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = root.appendingPathComponent("a.bin")
        let b = root.appendingPathComponent("b.bin")
        for url in [a, b] {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 52_000_000)
            try handle.close()
        }
        let handle = try FileHandle(forWritingTo: b)
        try handle.seek(toOffset: 2_000_000)
        try handle.write(contentsOf: Data([1]))
        try handle.close()

        let hashA = try CleanupSafety.fullFileSHA256(at: a)
        let hashB = try CleanupSafety.fullFileSHA256(at: b)
        precondition(hashA != hashB,
                     "full verification accepted files that differ outside the old sample windows")
    }

    private static func survivorPolicyNeverDeletesEveryCopy() {
        precondition(CleanupSafety.deletionIDs(from: [("a", false), ("b", false)]).isEmpty,
                     "a group with no survivor produced deletion candidates")
        precondition(CleanupSafety.deletionIDs(from: [("a", true), ("b", false)]) == Set(["b"]),
                     "a group with a survivor did not return only unkept copies")
    }

    private static func missingKeptCopyRejectsDeletion() {
        let choices = [("kept", true), ("remove", false)]
        precondition(!CleanupSafety.hasExistingSurvivor(in: choices) { $0 != "kept" },
                     "a missing kept file was accepted as the duplicate survivor")
        precondition(CleanupSafety.hasExistingSurvivor(in: choices) { $0 == "kept" },
                     "an existing kept file was rejected as the duplicate survivor")
    }

    private static func duplicatePotentialDoesNotDoubleCountPaths() {
        let copies: [(String, Int64)] = [("a", 10), ("b", 10), ("c", 10)]
        precondition(CleanupSafety.additionalDuplicateBytes(in: copies, excluding: []) == 20)
        precondition(CleanupSafety.additionalDuplicateBytes(in: copies, excluding: ["a"]) == 10,
                     "an old-download path was counted again as duplicate potential")
        precondition(CleanupSafety.additionalDuplicateBytes(in: copies, excluding: ["a", "b"]) == 0,
                     "duplicate potential failed to reserve one survivor")
    }

    private static func nestedPathsAreRecognizedAsAlreadyCounted() {
        let folder = URL(fileURLWithPath: "/tmp/Downloads/archive")
        let nested = folder.appendingPathComponent("copy.bin")
        let sibling = URL(fileURLWithPath: "/tmp/Downloads/archive-old/copy.bin")
        precondition(CleanupSafety.isSameOrDescendant(nested, of: [folder]))
        precondition(!CleanupSafety.isSameOrDescendant(sibling, of: [folder]),
                     "a similarly prefixed path was treated as a descendant")
    }

    private static func failedTrashTargetsRemain() {
        let candidates = [
            CleanupCandidate(id: "ok", url: URL(fileURLWithPath: "/tmp/ok"), bytes: 10),
            CleanupCandidate(id: "failed", url: URL(fileURLWithPath: "/tmp/failed"), bytes: 20),
        ]
        let result = CleanupSafety.performTrash(candidates) { url in
            if url.lastPathComponent == "failed" { throw CheckFailure.expectedFailure }
        }
        precondition(result.succeeded == Set(["ok"]) && result.bytes == 10 && result.failures.count == 1,
                     "trash outcome counted or removed a failed target")
    }

    private static func staleGenerationCannotPublish() {
        var generation = ScanGeneration()
        let stale = generation.next()
        let current = generation.next()
        precondition(!generation.accepts(stale) && generation.accepts(current),
                     "a stale worker still owns publication")
    }

    private static func ocrBoundsAreExplicit() {
        precondition(OCRPolicy.supports(fileExtension: "HEIC", sizeBytes: 30_000_000))
        precondition(!OCRPolicy.supports(fileExtension: "heic", sizeBytes: 30_000_001))
        precondition(!OCRPolicy.supports(fileExtension: "pdf", sizeBytes: 1_000))
    }

    private static func managedDependenciesAreExcluded() {
        precondition(CleanupSafety.isManagedDependencyDirectory(
            URL(fileURLWithPath: "/tmp/project/node_modules")))
        precondition(CleanupSafety.isManagedDependencyDirectory(
            URL(fileURLWithPath: "/tmp/project/vendor/bundle")))
        precondition(!CleanupSafety.isManagedDependencyDirectory(
            URL(fileURLWithPath: "/tmp/project/Documents")))
    }

    private static func sqliteSidecarsStayGrouped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bloatmac-sidecar-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("History")
        for url in [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm")] {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        }
        let grouped = CleanupSafety.sqliteFiles(for: database)
        precondition(grouped == [database,
                                 URL(fileURLWithPath: database.path + "-wal"),
                                 URL(fileURLWithPath: database.path + "-shm")],
                     "SQLite journal files were separated from their database or ordered before it")
    }

    private static func sharedContainersAreProtected() {
        precondition(CleanupSafety.isSharedContainer(
            URL(fileURLWithPath: "/Users/me/Library/Group Containers/TEAM.shared")))
        precondition(!CleanupSafety.isSharedContainer(
            URL(fileURLWithPath: "/Users/me/Library/Containers/com.example.app")))
    }
}
