import SwiftUI
import Foundation
import CoreServices
import UniformTypeIdentifiers
import AppKit
import Combine
import Vision
import ImageIO

// MARK: - Models

enum DownloadCategory: String, CaseIterable {
    case installer    // .dmg .pkg .xip
    case archive      // .zip .tar .gz .7z
    case media        // images, video, audio
    case document     // pdf, docx, xls, key
    case code         // ipynb, swift, py, ts, json
    case other

    var label: String {
        switch self {
        case .installer: return "Installers"
        case .archive:   return "Archives"
        case .media:     return "Media"
        case .document:  return "Documents"
        case .code:      return "Code"
        case .other:     return "Other"
        }
    }
    var icon: String {
        switch self {
        case .installer: return "shippingbox"
        case .archive:   return "doc.zipper"
        case .media:     return "photo.on.rectangle"
        case .document:  return "doc.richtext"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .other:     return "doc"
        }
    }
    var color: Color {
        switch self {
        case .installer: return Color(hex: 0x4D8DFF)
        case .archive:   return Color(hex: 0xC4A47C)
        case .media:     return Color(hex: 0xC084FC)
        case .document:  return Color(hex: 0x34D399)
        case .code:      return Color(hex: 0x67E8F9)
        case .other:     return Color(hex: 0x94A0B8)
        }
    }
}

struct DLEntry: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    let name: String
    let sizeBytes: Int64
    let modified: Date?
    let category: DownloadCategory
    let kind: String
    let sourceDomain: String?

    var ageDays: Int { Int(Date().timeIntervalSince(modified ?? Date()) / 86400) }
    var ageText: String {
        guard let d = modified else { return "—" }
        let days = Int(Date().timeIntervalSince(d) / 86400)
        if days < 1   { return "today" }
        if days < 14  { return "\(days)d ago" }
        if days < 60  { return "\(days/7)w ago" }
        if days < 730 { return "\(days/30)mo ago" }
        return "\(days/365)y ago"
    }
    var sizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB, .useKB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: sizeBytes)
    }
}

struct AppCacheEntry: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    let bundleID: String              // dir name under ~/Library/Caches
    let displayName: String           // human-friendly resolved via LSRegistry
    let sizeBytes: Int64
    let modified: Date?
    let safeToClean: Bool
    let cleanReason: String?          // e.g. "Xcode rebuilds DerivedData on next build"

    var sizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB, .useKB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: sizeBytes)
    }
    var ageText: String {
        guard let d = modified else { return "—" }
        let days = Int(Date().timeIntervalSince(d) / 86400)
        if days < 1   { return "today" }
        if days < 14  { return "\(days)d ago" }
        if days < 60  { return "\(days/7)w ago" }
        return "\(days/30)mo ago"
    }
}

nonisolated enum DownloadOCRState: Equatable {
    case unsupported
    case idle
    case loading
    case text(String)
    case noText
    case failed(String)
}

// MARK: - Singleton

@MainActor
final class LiveDownloadsCache: ObservableObject {
    static let shared = LiveDownloadsCache()

    @Published private(set) var downloads: [DLEntry] = []
    @Published private(set) var caches: [AppCacheEntry] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var phase: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String? = nil
    /// Per-URL OCR result for image downloads. Empty string = ran but no text found.
    @Published private(set) var ocr: [URL: String] = [:]
    @Published private(set) var ocrStates: [URL: DownloadOCRState] = [:]
    private var ocrInFlight: Set<URL> = []
    private var ocrTokens: [URL: UUID] = [:]

    var totalCount: Int { downloads.count + caches.count }
    var totalCacheBytes: Int64 { caches.reduce(0) { $0 + $1.sizeBytes } }
    var safeCleanBytes: Int64 { caches.filter(\.safeToClean).reduce(0) { $0 + $1.sizeBytes } }
    var totalDownloadsBytes: Int64 { downloads.reduce(0) { $0 + $1.sizeBytes } }

    var safeCleanText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: safeCleanBytes)
    }
    var totalDownloadsText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: totalDownloadsBytes)
    }

    private var task: Task<Void, Never>? = nil
    private var scanGeneration = ScanGeneration()

    private init() {}

    func startIfNeeded() {
        if downloads.isEmpty && caches.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        let generation = scanGeneration.next()
        scanning = true; downloads = []; caches = []
        ocr = [:]; ocrStates = [:]; ocrInFlight = []; ocrTokens = [:]
        phase = "Scanning Downloads…"; progress = 0
        task = Task.detached(priority: .userInitiated) { await Self.runScan(generation: generation) }
    }

    func cancel() {
        _ = scanGeneration.next()
        task?.cancel(); task = nil; scanning = false
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openInFinder(_ url: URL)   { NSWorkspace.shared.open(url) }

    // MARK: - Vision OCR (on-demand, cached)

    static let ocrEligibleExtensions = OCRPolicy.eligibleExtensions

    func ocrState(for entry: DLEntry) -> DownloadOCRState {
        guard entry.category == .media,
              OCRPolicy.supports(fileExtension: entry.url.pathExtension, sizeBytes: entry.sizeBytes)
        else { return .unsupported }
        return ocrStates[entry.url] ?? .idle
    }

    func ocrIfEligible(for entry: DLEntry) {
        guard ocrStates[entry.url] == nil, !ocrInFlight.contains(entry.url) else { return }
        guard entry.category == .media else { return }
        guard OCRPolicy.supports(fileExtension: entry.url.pathExtension, sizeBytes: entry.sizeBytes) else {
            ocrStates[entry.url] = .unsupported
            return
        }
        ocrInFlight.insert(entry.url)
        ocrStates[entry.url] = .loading
        let url = entry.url
        let token = UUID()
        ocrTokens[url] = token
        Task.detached(priority: .utility) {
            let state = Self.recognizeText(at: url)
            await MainActor.run {
                let live = LiveDownloadsCache.shared
                guard live.ocrTokens[url] == token else { return }
                live.ocrInFlight.remove(url)
                live.ocrTokens[url] = nil
                live.ocrStates[url] = state
                switch state {
                case .text(let text): live.ocr[url] = text
                case .noText, .failed: live.ocr[url] = ""
                default: break
                }
            }
        }
    }

    nonisolated private static func recognizeText(at url: URL) -> DownloadOCRState {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return .failed("Could not read this image.") }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
            let lines = req.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let joined = lines.joined(separator: " ")
            // Collapse whitespace
            let text = joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .noText : .text(text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func trashDownloads(_ ids: Set<URL>) -> Int {
        let fm = FileManager.default
        lastError = nil
        let candidates = downloads.filter { ids.contains($0.id) }
            .map { CleanupCandidate(id: $0.id, url: $0.url, bytes: $0.sizeBytes) }
        let outcome = CleanupSafety.performTrash(candidates) {
            try fm.trashItem(at: $0, resultingItemURL: nil)
        }
        downloads.removeAll { outcome.succeeded.contains($0.id) }
        if !outcome.failures.isEmpty { lastError = outcome.failures.joined(separator: "\n") }
        if !outcome.succeeded.isEmpty {
            CleanupLog.record(module: .downloads, itemCount: outcome.succeeded.count, bytes: outcome.bytes)
        }
        return outcome.succeeded.count
    }

    /// Empties the contents of the chosen cache directories (keeps the dir itself so apps don't break).
    @discardableResult
    func cleanCaches(_ ids: Set<URL>) -> Int {
        let fm = FileManager.default
        var trashed = 0
        var bytes: Int64 = 0
        var completed: Set<URL> = []
        var failures: [String] = []
        lastError = nil
        for id in ids {
            guard let entry = caches.first(where: { $0.id == id }) else { continue }
            guard entry.safeToClean else {
                failures.append("\(entry.displayName): this cache is marked Keep")
                continue
            }
            let inside: [URL]
            do {
                inside = try fm.contentsOfDirectory(at: id, includingPropertiesForKeys: nil)
            } catch {
                failures.append("\(entry.displayName): \(error.localizedDescription)")
                continue
            }
            let candidates = inside.map {
                CleanupCandidate(id: $0, url: $0, bytes: Self.directorySize(at: $0))
            }
            let outcome = CleanupSafety.performTrash(candidates) {
                try fm.trashItem(at: $0, resultingItemURL: nil)
            }
            trashed += outcome.succeeded.count
            bytes += outcome.bytes
            failures.append(contentsOf: outcome.failures)
            if outcome.failures.isEmpty { completed.insert(id) }
        }
        caches.removeAll { completed.contains($0.id) }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
        if trashed > 0 { CleanupLog.record(module: .caches, itemCount: trashed, bytes: bytes) }
        return trashed
    }

    // MARK: - Scan worker

    nonisolated private static func runScan(generation: Int) async {
        await update(phase: "Scanning Downloads…", progress: 0.05, generation: generation)

        // 1. Downloads folder
        let dl = await scanDownloads()
        guard !Task.isCancelled else { return }
        await publishDownloads(dl, generation: generation)
        await update(phase: "Scanning app caches…", progress: 0.5, generation: generation)

        // 2. ~/Library/Caches subdirectories
        let ch = await scanCaches()
        guard !Task.isCancelled else { return }
        await publishCaches(ch, generation: generation)

        await finish(generation: generation)
    }

    nonisolated private static func scanDownloads() async -> [DLEntry] {
        let path = "\(NSHomeDirectory())/Downloads"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        var out: [DLEntry] = []
        for entry in entries where !entry.hasPrefix(".") {
            let url = URL(fileURLWithPath: "\(path)/\(entry)")
            let v = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                .totalFileAllocatedSizeKey, .contentModificationDateKey,
                .typeIdentifierKey, .localizedTypeDescriptionKey, .isPackageKey,
            ])
            let isDir = (v?.isDirectory ?? false) && (v?.isPackage != true)
            let bytes: Int64
            if isDir { bytes = directorySize(at: url) }
            else if let s = v?.totalFileAllocatedSize { bytes = Int64(s) }
            else if let s = v?.fileSize               { bytes = Int64(s) }
            else { continue }
            if bytes < 1024 { continue }

            let ext = url.pathExtension.lowercased()
            let utType = v?.typeIdentifier.flatMap { UTType($0) } ?? UTType(filenameExtension: ext)
            let category = classify(ext: ext, type: utType)
            let kind = v?.localizedTypeDescription
                ?? utType?.localizedDescription
                ?? (ext.isEmpty ? "File" : ext.uppercased())
            let where_ = whereFrom(at: url)

            out.append(DLEntry(
                id: url, name: entry,
                sizeBytes: bytes,
                modified: v?.contentModificationDate,
                category: category,
                kind: kind,
                sourceDomain: where_
            ))
        }
        out.sort { $0.sizeBytes > $1.sizeBytes }
        return out
    }

    nonisolated private static func scanCaches() async -> [AppCacheEntry] {
        let root = "\(NSHomeDirectory())/Library/Caches"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [AppCacheEntry] = []
        for entry in entries where !entry.hasPrefix(".") {
            let url = URL(fileURLWithPath: "\(root)/\(entry)")
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard v?.isDirectory == true else { continue }
            let size = directorySize(at: url)
            if size < 1_000_000 { continue } // skip <1MB

            let safe = SafeCacheRegistry.match(bundleID: entry)
            let display = SafeCacheRegistry.displayName(for: entry) ?? entry

            out.append(AppCacheEntry(
                id: url, bundleID: entry, displayName: display,
                sizeBytes: size, modified: v?.contentModificationDate,
                safeToClean: safe.safe, cleanReason: safe.reason
            ))
        }
        out.sort { $0.sizeBytes > $1.sizeBytes }
        return out
    }

    // MARK: - Helpers

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let en = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }) else { return 0 }
        for case let item as URL in en {
            if Task.isCancelled { break }
            let v = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true {
                if let s = v?.totalFileAllocatedSize { total += Int64(s) }
                else if let s = v?.fileSize { total += Int64(s) }
            }
        }
        return total
    }

    nonisolated private static func whereFrom(at url: URL) -> String? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        guard let arr = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return nil }
        for raw in arr where !raw.isEmpty {
            if let u = URL(string: raw), let host = u.host { return host }
            return raw
        }
        return nil
    }

    nonisolated private static func classify(ext: String, type: UTType?) -> DownloadCategory {
        switch ext {
        case "dmg", "pkg", "xip", "mpkg": return .installer
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz": return .archive
        case "swift", "py", "js", "ts", "tsx", "go", "rs", "java", "kt", "rb", "ipynb", "json", "xml", "yaml", "yml", "sh": return .code
        default: break
        }
        guard let t = type else { return .other }
        if t.conforms(to: .image) || t.conforms(to: .audio) || t.conforms(to: .audiovisualContent) || t.conforms(to: .movie) { return .media }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .spreadsheet) || t.conforms(to: .presentation) || t.conforms(to: .compositeContent) { return .document }
        if t.conforms(to: .archive) { return .archive }
        if t.conforms(to: .application) || t.conforms(to: .applicationBundle) { return .installer }
        if t.conforms(to: .sourceCode) { return .code }
        return .other
    }

    nonisolated private static func update(phase: String, progress: Double, generation: Int) async {
        await MainActor.run {
            let live = LiveDownloadsCache.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.phase = phase
            live.progress = progress
        }
    }
    nonisolated private static func publishDownloads(_ d: [DLEntry], generation: Int) async {
        await MainActor.run {
            let live = LiveDownloadsCache.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.downloads = d
        }
    }
    nonisolated private static func publishCaches(_ c: [AppCacheEntry], generation: Int) async {
        await MainActor.run {
            let live = LiveDownloadsCache.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.caches = c
        }
    }
    nonisolated private static func finish(generation: Int) async {
        await MainActor.run {
            let live = LiveDownloadsCache.shared
            guard live.scanGeneration.accepts(generation) else { return }
            live.scanning = false
            live.task = nil
            live.phase = "Done"
            live.progress = 1
        }
    }
}

// MARK: - Curated registry of caches that are safe to wipe

nonisolated enum SafeCacheRegistry {
    nonisolated struct Match { let safe: Bool; let reason: String? }

    /// Patterns matched against the cache subdirectory name.
    /// Each entry: (matcher, displayName, safe-to-clean, reason).
    private nonisolated static let entries: [(prefix: String, name: String, safe: Bool, reason: String?)] = [
        ("com.apple.dt.Xcode",       "Xcode (DerivedData)", true,  "Xcode rebuilds these on the next build."),
        ("Homebrew",                 "Homebrew downloads",  true,  "Brew re-downloads bottles when needed."),
        ("Yarn",                     "Yarn",                 true,  "Yarn re-downloads packages on the next install."),
        ("com.electron",             "Electron",             true,  "Re-fetched by Electron apps on demand."),
        ("com.docker.docker",        "Docker Desktop",       false, "Removing may force re-pulling images."),
        ("com.spotify.client",       "Spotify",              true,  "Spotify re-streams tracks; offline playlists need re-download."),
        ("com.tinyspeck.slackmacgap","Slack",                true,  "Slack repopulates this on next launch."),
        ("com.google.Chrome",        "Google Chrome",        true,  "Chrome rebuilds page caches; sign-ins remain."),
        ("com.brave.Browser",        "Brave",                true,  "Browser caches; logins remain."),
        ("org.mozilla.firefox",      "Firefox",              true,  "Browser caches; logins remain."),
        ("com.microsoft.VSCode",     "VS Code",              true,  "Extensions cache, rebuilt as needed."),
        ("com.figma.Desktop",        "Figma",                true,  "Figma re-downloads document thumbnails."),
        ("com.tinyapps.TablePlus",   "TablePlus",            true,  "Just thumbnails and recent metadata."),
        ("Adobe",                    "Adobe Creative Cloud", false, "Some installs cache assets here."),
        ("com.apple.iCloud",         "iCloud",               false, "iCloud manages this; do not touch."),
        ("CloudKit",                 "CloudKit",             false, "System CloudKit cache."),
        ("com.apple",                "System (Apple)",       false, "Managed by macOS — let the system clean it."),
    ]

    nonisolated static func match(bundleID: String) -> Match {
        for e in entries where bundleID.lowercased().contains(e.prefix.lowercased()) {
            return Match(safe: e.safe, reason: e.reason)
        }
        return Match(safe: false, reason: "Not in the curated safe-cache list; review before removing.")
    }

    nonisolated static func displayName(for bundleID: String) -> String? {
        for e in entries where bundleID.lowercased().contains(e.prefix.lowercased()) { return e.name }
        return nil
    }
}
