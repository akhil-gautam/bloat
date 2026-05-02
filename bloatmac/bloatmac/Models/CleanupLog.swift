import Foundation
import SQLite3

enum CleanupModule: String {
    case duplicates, largeFiles, unused, downloads, caches
    case uninstaller, updater, systemJunk, privacy, cloud, maintenance, malware
    var label: String {
        switch self {
        case .duplicates:  "Duplicates"
        case .largeFiles:  "Large files"
        case .unused:      "Unused & old"
        case .downloads:   "Downloads"
        case .caches:      "Caches"
        case .uninstaller: "Uninstaller"
        case .updater:     "Updater"
        case .systemJunk:  "System junk"
        case .privacy:     "Privacy"
        case .cloud:       "Cloud"
        case .maintenance: "Maintenance"
        case .malware:     "Malware"
        }
    }
}

struct CleanupRecord: Identifiable {
    let id: TimeInterval
    let t: Date
    let module: CleanupModule
    let itemCount: Int
    let bytes: Int64
}

/// Tiny actor-isolated logger — writes to the same `dashboard.sqlite` LiveDashboard owns.
/// Opens its own connection so it doesn't fight with the LiveDashboard one.
enum CleanupLog {
    nonisolated(unsafe) private static var db: OpaquePointer? = nil
    private static let lock = NSLock()

    private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dashboard.sqlite")
    }()

    private static func ensureOpen() {
        if db != nil { return }
        sqlite3_open(dbURL.path, &db)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS cleanups(
                t REAL PRIMARY KEY,
                module TEXT, item_count INTEGER, bytes INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_cleanups_t ON cleanups(t);
        """, nil, nil, nil)
    }

    static func record(module: CleanupModule, itemCount: Int, bytes: Int64) {
        guard itemCount > 0, bytes >= 0 else { return }
        DispatchQueue.global(qos: .background).async {
            lock.lock(); defer { lock.unlock() }
            ensureOpen()
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db,
                "INSERT OR REPLACE INTO cleanups(t,module,item_count,bytes) VALUES (?,?,?,?)",
                -1, &stmt, nil) != SQLITE_OK { return }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            module.rawValue.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
            sqlite3_bind_int(stmt, 3, Int32(itemCount))
            sqlite3_bind_int64(stmt, 4, bytes)
            sqlite3_step(stmt)
        }
    }

    /// Read all rows in [from, now]. Synchronous — caller should be off-main.
    static func read(since cutoff: TimeInterval) -> [CleanupRecord] {
        lock.lock(); defer { lock.unlock() }
        ensureOpen()
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT t,module,item_count,bytes FROM cleanups WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, cutoff)
        var rows: [CleanupRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let t = sqlite3_column_double(stmt, 0)
            let modRaw = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(stmt, 2))
            let bytes = sqlite3_column_int64(stmt, 3)
            guard let mod = CleanupModule(rawValue: modRaw) else { continue }
            rows.append(CleanupRecord(id: t, t: Date(timeIntervalSince1970: t), module: mod, itemCount: count, bytes: bytes))
        }
        return rows
    }
}
