import SwiftUI

final class MockData {
    static let shared = MockData()

    let totalGB: Double = 1024

    let categories: [CategoryEntry] = [
        .init(id: "apps",      name: "Applications", size: 142.4, color: Tokens.catApps,    count: 287),
        .init(id: "system",    name: "System",       size: 96.2,  color: Tokens.catSystem,  count: 1, locked: true),
        .init(id: "photos",    name: "Photos",       size: 178.6, color: Tokens.catPhotos,  count: 24812),
        .init(id: "videos",    name: "Movies",       size: 124.0, color: Tokens.catVideos,  count: 312),
        .init(id: "music",     name: "Music",        size: 38.1,  color: Tokens.catMusic,   count: 6420),
        .init(id: "docs",      name: "Documents",    size: 64.8,  color: Tokens.catDocs,    count: 8932),
        .init(id: "mail",      name: "Mail",         size: 22.7,  color: Tokens.catMail,    count: 18420),
        .init(id: "caches",    name: "Caches & Logs",size: 41.3,  color: Color(hex: 0xA5C9FF), count: 14209, cleanable: true),
        .init(id: "downloads", name: "Downloads",    size: 28.4,  color: Color(hex: 0xFFD479), count: 612, cleanable: true),
        .init(id: "trash",     name: "Trash",        size: 7.9,   color: Tokens.catTrash,   count: 421, cleanable: true),
        .init(id: "other",     name: "Other",        size: 23.4,  color: Tokens.catOther,   count: 0),
    ]

    var usedGB: Double { categories.reduce(0) { $0 + $1.size } }
    var freeGB: Double { totalGB - usedGB }
    var cleanableGB: Double { categories.filter(\.cleanable).reduce(0) { $0 + $1.size } }

    let apps: [AppEntry] = [
        .init(name: "Xcode",            size: 28.4, icon: "X",  color: Color(hex: 0x147EFB)),
        .init(name: "Final Cut Pro",    size: 16.2, icon: "F",  color: Color(hex: 0x1B1B1B)),
        .init(name: "Adobe Photoshop",  size: 12.8, icon: "Ps", color: Color(hex: 0x001E36)),
        .init(name: "Adobe Premiere",   size: 11.4, icon: "Pr", color: Color(hex: 0x00005B)),
        .init(name: "Logic Pro",        size: 9.8,  icon: "L",  color: Color(hex: 0xFF6B35)),
        .init(name: "Docker Desktop",   size: 8.9,  icon: "D",  color: Color(hex: 0x2496ED)),
        .init(name: "Sketch",           size: 4.6,  icon: "S",  color: Color(hex: 0xFDB300)),
        .init(name: "Slack",            size: 4.1,  icon: "Sl", color: Color(hex: 0x4A154B)),
        .init(name: "Figma",            size: 3.7,  icon: "Fi", color: Color(hex: 0x0ACF83)),
        .init(name: "Notion",           size: 3.2,  icon: "N",  color: Color(hex: 0x000000)),
        .init(name: "Spotify",          size: 2.9,  icon: "Sp", color: Color(hex: 0x1DB954)),
        .init(name: "Discord",          size: 2.6,  icon: "Ds", color: Color(hex: 0x5865F2)),
        .init(name: "Chrome",           size: 2.5,  icon: "C",  color: Color(hex: 0x4285F4)),
        .init(name: "VS Code",          size: 2.4,  icon: "Vc", color: Color(hex: 0x007ACC)),
        .init(name: "Other apps (273)", size: 28.9, icon: "·",  color: Color(hex: 0x8E8E93)),
    ]

    let largeFiles: [LargeFile] = [
        .init(name: "IMG_2024_BTS_4K.mov",      path: "~/Movies/Projects/Wedding",     size: 18.4, kind: "Video",   age: 412, last: "2 yr ago"),
        .init(name: "master.psd",                path: "~/Documents/Design/Pitch",      size: 12.1, kind: "Image",   age: 281, last: "9 mo ago"),
        .init(name: "iOS-15.4.simruntime",       path: "/Library/Developer/CoreSim",    size: 9.8,  kind: "Bundle",  age: 720, last: "2 yr ago", flag: "unused"),
        .init(name: "node_modules.zip",          path: "~/Downloads",                   size: 8.7,  kind: "Archive", age: 92,  last: "3 mo ago", flag: "duplicate"),
        .init(name: "macOS_Ventura_Installer",   path: "/Applications",                 size: 7.4,  kind: "App",     age: 540, last: "1 yr ago", flag: "unused"),
        .init(name: "Final Render v17.mov",      path: "~/Movies/Client",               size: 6.9,  kind: "Video",   age: 14,  last: "2 wk ago"),
        .init(name: "Backup_Jan2024.dmg",        path: "~/Documents/Archive",           size: 6.2,  kind: "Archive", age: 380, last: "1 yr ago", flag: "unused"),
        .init(name: "Adobe-Cache.bundle",        path: "~/Library/Caches",              size: 5.8,  kind: "Cache",   age: 30,  last: "1 mo ago", flag: "cleanable"),
        .init(name: "session_recordings_q3.zip", path: "~/Downloads",                   size: 5.4,  kind: "Archive", age: 180, last: "6 mo ago"),
        .init(name: "training_data_v2.parquet",  path: "~/dev/ml/data",                 size: 4.8,  kind: "Data",    age: 60,  last: "2 mo ago"),
        .init(name: "iPhone Backup",             path: "~/Library/Application Support", size: 4.6,  kind: "Bundle",  age: 240, last: "8 mo ago"),
        .init(name: "pitch_deck_v23_FINAL.key",  path: "~/Documents",                   size: 3.9,  kind: "Doc",     age: 21,  last: "3 wk ago"),
    ]

    let duplicates: [DuplicateGroup] = [
        .init(name: "IMG_2391.HEIC",              count: 4, total: 14.8, locations: ["~/Pictures","~/Downloads","~/Desktop","iCloud"]),
        .init(name: "invoice_oct_2025.pdf",       count: 3, total: 0.9,  locations: ["~/Downloads","~/Documents/Invoices","Mail Attachments"]),
        .init(name: "screenshot_team_q4.png",     count: 6, total: 12.3, locations: ["~/Desktop","~/Pictures","~/Documents"]),
        .init(name: "master.psd",                  count: 2, total: 24.2, locations: ["~/Documents/Design","~/Backup"]),
        .init(name: "logo_v_final_FINAL.ai",      count: 5, total: 4.1,  locations: ["~/Documents","~/Downloads"]),
        .init(name: "meeting_recording_aug.m4a",  count: 2, total: 1.8,  locations: ["~/Music","~/Downloads"]),
        .init(name: "Resume_2024.docx",           count: 4, total: 0.4,  locations: ["~/Documents","~/Desktop","~/Downloads"]),
    ]

    let unused: [UnusedItem] = [
        .init(name: "GarageBand",            kind: "app",    last: "847 days ago", size: 1.4),
        .init(name: "iMovie",                kind: "app",    last: "612 days ago", size: 2.8),
        .init(name: "Keynote",               kind: "app",    last: "410 days ago", size: 0.8),
        .init(name: "Project_Q1_2023",       kind: "folder", last: "720 days ago", size: 14.2),
        .init(name: "old_resume_drafts",     kind: "folder", last: "900 days ago", size: 0.06),
        .init(name: "Untitled.numbers (12 files)", kind: "file", last: "500 days ago", size: 0.4),
    ]

    let downloads: [DownloadEntry] = [
        .init(name: "macOS-Sequoia-15.4.dmg",    size: 14.2, age: 24),
        .init(name: "Xcode_16_beta_2.xip",       size: 9.6,  age: 41),
        .init(name: "node_modules.zip",          size: 8.7,  age: 92),
        .init(name: "figma-export-2025-q3.zip",  size: 1.4,  age: 12),
        .init(name: "sample_video_4k.mp4",       size: 1.1,  age: 4),
        .init(name: "asset-pack-v3.zip",         size: 0.9,  age: 60),
        .init(name: "Slack-installer.dmg",       size: 0.18, age: 3),
        .init(name: "+ 604 more downloads…",     size: 14.4, age: 0, more: true),
    ]

    let caches: [CacheEntry] = [
        .init(name: "Safari", size: 6.8),
        .init(name: "Google Chrome", size: 9.2),
        .init(name: "Slack", size: 5.4),
        .init(name: "Adobe (Creative Cloud)", size: 8.7),
        .init(name: "Xcode DerivedData", size: 6.1),
        .init(name: "npm / yarn cache", size: 3.2),
        .init(name: "Spotify offline", size: 1.9),
        .init(name: "System logs", size: 0.8),
    ]

    let startup: [StartupItem] = [
        .init(name: "Docker Desktop",         dev: "Docker Inc.",       impact: "High",   loaded: true,  ms: 4200),
        .init(name: "Adobe Creative Cloud",   dev: "Adobe",             impact: "High",   loaded: true,  ms: 3100),
        .init(name: "Spotify",                dev: "Spotify AB",        impact: "Medium", loaded: true,  ms: 1800),
        .init(name: "Slack",                  dev: "Slack Tech.",       impact: "Medium", loaded: true,  ms: 1450),
        .init(name: "Microsoft AutoUpdate",   dev: "Microsoft",         impact: "Low",    loaded: true,  ms: 620),
        .init(name: "Rectangle",              dev: "Ryan Hanson",       impact: "Low",    loaded: true,  ms: 240),
        .init(name: "BetterTouchTool",        dev: "Andreas Hegenberg", impact: "Low",    loaded: false, ms: 380),
        .init(name: "Logi Options+",          dev: "Logitech",          impact: "Medium", loaded: true,  ms: 1100),
        .init(name: "Zoom Auto Update",       dev: "Zoom",              impact: "Low",    loaded: true,  ms: 540),
    ]

    let memProcesses: [ProcessEntry] = [
        .init(name: "Google Chrome Helper (Renderer)", mem: 1840, cpu: 12.4, energy: "High",   icon: "C",  color: Color(hex: 0x4285F4), pid: 4291),
        .init(name: "kernel_task",                     mem: 1620, cpu: 4.2,  energy: "Low",    icon: "K",  color: Color(hex: 0x8E8E93), pid: 1, locked: true),
        .init(name: "Xcode",                           mem: 1480, cpu: 18.6, energy: "High",   icon: "X",  color: Color(hex: 0x147EFB), pid: 9821),
        .init(name: "Slack Helper",                    mem: 1240, cpu: 8.1,  energy: "Medium", icon: "Sl", color: Color(hex: 0x4A154B), pid: 6021),
        .init(name: "WindowServer",                    mem: 980,  cpu: 6.4,  energy: "Medium", icon: "W",  color: Color(hex: 0x34C759), pid: 178),
        .init(name: "Figma Helper",                    mem: 920,  cpu: 4.1,  energy: "Low",    icon: "Fi", color: Color(hex: 0x0ACF83), pid: 8412),
        .init(name: "Spotify",                         mem: 740,  cpu: 2.8,  energy: "Low",    icon: "Sp", color: Color(hex: 0x1DB954), pid: 5210),
        .init(name: "Notion",                          mem: 620,  cpu: 1.9,  energy: "Low",    icon: "N",  color: Color(hex: 0x0a0a0a), pid: 3104),
        .init(name: "Docker Desktop",                  mem: 540,  cpu: 6.2,  energy: "Medium", icon: "D",  color: Color(hex: 0x2496ED), pid: 2210),
        .init(name: "mds_stores",                      mem: 410,  cpu: 0.4,  energy: "Low",    icon: "M",  color: Color(hex: 0xAC8E68), pid: 422),
        .init(name: "Mail",                            mem: 380,  cpu: 0.9,  energy: "Low",    icon: "✉",  color: Color(hex: 0x0A84FF), pid: 7104),
        .init(name: "Photos",                          mem: 340,  cpu: 12.1, energy: "High",   icon: "P",  color: Color(hex: 0xFF9F0A), pid: 6821, indexing: true),
    ]

    let memory = MemoryStats(total: 24576, appUsed: 11240, wired: 4180, compressed: 2640, cached: 4980, free: 1536, swap: 2480, pressure: 0.62)

    let network: [NetworkApp] = [
        .init(name: "Google Chrome", up: 412,  down: 14820, total: 8.4,  color: Color(hex: 0x4285F4)),
        .init(name: "Slack",         up: 280,  down: 4120,  total: 2.1,  color: Color(hex: 0x4A154B)),
        .init(name: "Spotify",       up: 12,   down: 3210,  total: 1.4,  color: Color(hex: 0x1DB954)),
        .init(name: "Dropbox",       up: 1820, down: 92,    total: 0.6,  color: Color(hex: 0x0061FF)),
        .init(name: "Zoom",          up: 0,    down: 0,     total: 0.4,  color: Color(hex: 0x2D8CFF)),
        .init(name: "Mail",          up: 18,   down: 240,   total: 0.2,  color: Color(hex: 0x0A84FF)),
        .init(name: "Backblaze",     up: 940,  down: 8,     total: 0.18, color: Color(hex: 0xE22424)),
    ]

    let trends: Trends = {
        var rng = SystemRandomNumberGenerator()
        let days = 30
        var used: [Double] = []
        var ramP: [Double] = []
        var scans: [Int] = []
        var u: Double = 712
        for _ in 0..<days {
            u += (Double.random(in: 0...1) - 0.35) * 4
            u = max(700, min(800, u))
            used.append((u * 10).rounded() / 10)
            ramP.append(((0.45 + Double.random(in: 0...0.4)) * 100).rounded() / 100)
            scans.append(Double.random(in: 0...1) > 0.7 ? 1 : 0)
        }
        return Trends(used: used, ramP: ramP, scans: scans, days: days)
    }()

    let notifications: [AppNotification] = [
        .init(id: 1, kind: "danger", icon: "!", title: "Storage running low",  body: "75% used. Cleaning Caches & Trash will free 49.2 GB.", time: "2m ago",  actionable: true),
        .init(id: 2, kind: "warn",   icon: "D", title: "Duplicates detected",  body: "7 groups, 56.7 GB recoverable.",                       time: "14m ago", actionable: true),
        .init(id: 3, kind: "good",   icon: "✓", title: "Memory freed",         body: "Released 2.4 GB inactive memory.",                     time: "1h ago"),
        .init(id: 4, kind: "info",   icon: "i", title: "Weekly scan complete", body: "No new threats. 14,209 cache files indexed.",          time: "6h ago"),
        .init(id: 5, kind: "warn",   icon: "B", title: "Battery: high impact apps", body: "Chrome and Xcode are using significant energy.",  time: "1d ago"),
    ]

    private init() {}
}

// MARK: - Formatters
enum Fmt {
    static func size(_ gb: Double) -> String {
        gb >= 1 ? String(format: "%.1f GB", gb) : "\(Int(gb * 1024)) MB"
    }
    static func mb(_ m: Int) -> String {
        m >= 1024 ? String(format: "%.1f GB", Double(m) / 1024) : "\(m) MB"
    }
    static func net(_ kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f MB/s", Double(kbps) / 1000) : "\(kbps) KB/s"
    }
}
