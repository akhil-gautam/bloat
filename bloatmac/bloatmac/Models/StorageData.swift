import SwiftUI

struct CategoryEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Double          // GB
    let color: Color
    let count: Int
    var locked: Bool = false
    var cleanable: Bool = false
}

struct AppEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let size: Double
    let icon: String
    let color: Color
}

struct LargeFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Double
    let kind: String
    let age: Int          // days
    let last: String
    var flag: String? = nil
}

struct DuplicateGroup: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let count: Int
    let total: Double
    let locations: [String]
}

struct UnusedItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let kind: String
    let last: String
    let size: Double
}

struct DownloadEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let size: Double
    let age: Int
    var more: Bool = false
}

struct CacheEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let size: Double
}

struct StartupItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dev: String
    let impact: String  // High/Medium/Low
    var loaded: Bool
    let ms: Int
}

struct ProcessEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let mem: Int     // MB
    let cpu: Double
    let energy: String
    let icon: String
    let color: Color
    let pid: Int
    var locked: Bool = false
    var indexing: Bool = false
}

struct MemoryStats {
    let total: Int        // MB
    let appUsed: Int
    let wired: Int
    let compressed: Int
    let cached: Int
    let free: Int
    let swap: Int
    let pressure: Double  // 0..1
}

struct NetworkApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let up: Int          // KB/s
    let down: Int
    let total: Double    // GB
    let color: Color
}

struct Trends {
    let used: [Double]
    let ramP: [Double]
    let scans: [Int]
    let days: Int
}

struct AppNotification: Identifiable, Hashable {
    let id: Int
    let kind: String     // danger/warn/good/info
    let icon: String
    let title: String
    let body: String
    let time: String
    var actionable: Bool = false
}
