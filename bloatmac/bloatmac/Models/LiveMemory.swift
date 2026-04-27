import Foundation
import SwiftUI
import Combine
import Darwin
import AppKit

enum MemoryPressure: Int, Codable { case normal = 1, warning = 2, critical = 4
    var label: String {
        switch self { case .normal: return "Normal"; case .warning: return "Warning"; case .critical: return "Critical" }
    }
    var color: Color {
        switch self { case .normal: return Tokens.good; case .warning: return Tokens.warn; case .critical: return Tokens.danger }
    }
}

struct ProcMem: Identifiable, Hashable {
    let id: Int32        // pid
    let name: String
    let bytes: UInt64
    let cpu: Double      // percent
    let isApp: Bool
    let bundlePath: String?      // resolved lazily by the view via LazyAppIcon
    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: ProcMem, b: ProcMem) -> Bool { a.id == b.id }
}

struct MemorySample: Codable {
    let t: TimeInterval
    let u: Float          // memory used fraction
    let p: Int            // pressure raw
    let g: Float          // gpu util fraction (0 if unknown)
    let s: Float          // swap used fraction
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case m5 = "5m", h1 = "1h", h6 = "6h", d1 = "1d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .m5: return 300; case .h1: return 3600; case .h6: return 21600; case .d1: return 86400 }
    }
    var label: String { rawValue }
}

enum ProcSort: String, CaseIterable, Identifiable {
    case memory = "Memory", cpu = "CPU", name = "Name"
    var id: String { rawValue }
}

@MainActor
final class LiveMemory: ObservableObject {
    static let shared = LiveMemory()

    // VM
    @Published private(set) var totalBytes: UInt64 = 0
    @Published private(set) var appBytes: UInt64 = 0
    @Published private(set) var wiredBytes: UInt64 = 0
    @Published private(set) var compressedBytes: UInt64 = 0
    @Published private(set) var cachedBytes: UInt64 = 0
    @Published private(set) var freeBytes: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var pressure: MemoryPressure = .normal
    @Published private(set) var pageIns: UInt64 = 0
    @Published private(set) var pageOuts: UInt64 = 0
    @Published private(set) var compressions: UInt64 = 0
    @Published private(set) var decompressions: UInt64 = 0

    // GPU
    @Published private(set) var gpuName: String = "—"
    @Published private(set) var gpuCores: Int = 0
    @Published private(set) var gpuUtilization: Double = 0           // 0...1
    @Published private(set) var gpuInUseBytes: UInt64 = 0
    @Published private(set) var gpuAllocBytes: UInt64 = 0
    @Published private(set) var gpuRecoveryCount: Int = 0

    // History
    @Published private(set) var history: [MemorySample] = []
    @Published var range: HistoryRange = .m5

    // Processes
    @Published private(set) var topProcesses: [ProcMem] = []
    @Published var procSearch: String = ""
    @Published var procSort: ProcSort = .memory
    @Published var procIncludeHelpers: Bool = true

    @Published private(set) var lastUpdate: Date = .distantPast
    @Published private(set) var lastError: String? = nil

    var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }
    var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }

    var filteredProcesses: [ProcMem] {
        let q = procSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = topProcesses
        if !procIncludeHelpers {
            rows = rows.filter { !$0.name.lowercased().contains("helper") }
        }
        if !q.isEmpty {
            rows = rows.filter { $0.name.lowercased().contains(q) || String($0.id).contains(q) }
        }
        switch procSort {
        case .memory: rows.sort { $0.bytes > $1.bytes }
        case .cpu:    rows.sort { $0.cpu   > $1.cpu   }
        case .name:   rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return rows
    }

    var historyInRange: [MemorySample] {
        let cutoff = Date().timeIntervalSince1970 - range.seconds
        return history.filter { $0.t >= cutoff }
    }

    private var timer: Timer?
    private var procTick = 0
    private var saveTick = 0
    nonisolated private static let historyURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("memory_history.json")
    }()

    private init() {
        totalBytes = Self.physicalMemory()
        swapTotal = Self.swap().total
        let g = Self.gpuInfoStatic()
        gpuName = g.name; gpuCores = g.cores
        loadHistory()
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func killProcess(_ pid: Int32, force: Bool = false) {
        let signal = force ? SIGKILL : SIGTERM
        let r = kill(pid, signal)
        if r != 0 {
            lastError = "Failed to send signal to PID \(pid): \(String(cString: strerror(errno)))"
        } else {
            topProcesses.removeAll { $0.id == pid }
        }
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    // MARK: - Sampling

    private func sample() {
        let vm = Self.vmStats()
        let sw = Self.swap()
        let pl = Self.pressureLevel()

        appBytes        = vm.app
        wiredBytes      = vm.wired
        compressedBytes = vm.compressed
        cachedBytes     = vm.cached
        freeBytes       = vm.free
        swapUsed        = sw.used
        swapTotal       = sw.total
        pressure        = pl
        pageIns         = vm.pageIns
        pageOuts        = vm.pageOuts
        compressions    = vm.compressions
        decompressions = vm.decompressions

        let s = MemorySample(
            t: Date().timeIntervalSince1970,
            u: Float(usedFraction),
            p: pl.rawValue,
            g: Float(gpuUtilization),
            s: swapTotal == 0 ? 0 : Float(Double(swapUsed) / Double(swapTotal))
        )
        history.append(s)
        // Keep 30 min in memory (900 samples @ 2s); on-disk JSON has 24h.
        let inMemoryCutoff = Date().timeIntervalSince1970 - 1800
        if let i = history.firstIndex(where: { $0.t >= inMemoryCutoff }), i > 0 {
            history.removeFirst(i)
        }
        lastUpdate = Date()

        // every other tick (~4s): processes + GPU + persist
        procTick += 1
        if procTick % 2 == 1 {
            refreshProcesses()
            refreshGPU()
        }
        saveTick += 1
        if saveTick % 15 == 0 { persistHistory() }   // every 30s
    }

    private func refreshProcesses() {
        Task.detached(priority: .utility) {
            let rows = Self.psTopProcesses(limit: 40)
            await MainActor.run { LiveMemory.shared.topProcesses = rows }
        }
    }

    private func refreshGPU() {
        Task.detached(priority: .utility) {
            let g = Self.gpuPerf()
            await MainActor.run {
                LiveMemory.shared.gpuUtilization = g.utilization
                LiveMemory.shared.gpuInUseBytes  = g.inUse
                LiveMemory.shared.gpuAllocBytes  = g.alloc
                LiveMemory.shared.gpuRecoveryCount = g.recovery
            }
        }
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let arr = try? JSONDecoder().decode([MemorySample].self, from: data) else { return }
        let cutoff = Date().timeIntervalSince1970 - 86400
        history = arr.filter { $0.t >= cutoff }
    }

    private func persistHistory() {
        let snapshot = history
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    // MARK: - mach / sysctl

    private static func physicalMemory() -> UInt64 {
        var size: UInt64 = 0; var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0); return size
    }

    private static func vmStats() -> (app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64,
                                      pageIns: UInt64, pageOuts: UInt64, compressions: UInt64, decompressions: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0,0,0,0,0,0,0,0,0) }
        let pageSize    = UInt64(vm_kernel_page_size)
        // Activity Monitor formula — these partition physical RAM without double-counting:
        //   App memory  = internal (anonymous) - purgeable
        //   Cached files = external (file-backed) + purgeable + speculative
        //   Wired       = wire_count
        //   Compressed  = compressor_page_count
        //   Free        = free_count - speculative   (speculative is shown as cached)
        let internalP   = UInt64(stats.internal_page_count) * pageSize
        let externalP   = UInt64(stats.external_page_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let purgeable   = UInt64(stats.purgeable_count) * pageSize
        let wired       = UInt64(stats.wire_count) * pageSize
        let compressed  = UInt64(stats.compressor_page_count) * pageSize
        let freeRaw     = UInt64(stats.free_count) * pageSize

        let app    = internalP &- min(internalP, purgeable)
        let cached = externalP &+ purgeable &+ speculative
        let free   = freeRaw &- min(freeRaw, speculative)
        return (app, wired, compressed, cached, free,
                UInt64(stats.pageins), UInt64(stats.pageouts),
                UInt64(stats.compressions), UInt64(stats.decompressions))
    }

    private static func swap() -> (used: UInt64, total: UInt64) {
        var xsw = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        let r = sysctlbyname("vm.swapusage", &xsw, &size, nil, 0)
        guard r == 0 else { return (0, 0) }
        return (UInt64(xsw.xsu_used), UInt64(xsw.xsu_total))
    }

    private static func pressureLevel() -> MemoryPressure {
        var lvl: Int32 = 0; var size = MemoryLayout<Int32>.size
        let r = sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &size, nil, 0)
        if r != 0 { return .normal }
        return MemoryPressure(rawValue: Int(lvl)) ?? .normal
    }

    // MARK: - GPU via ioreg

    nonisolated private static func gpuInfoStatic() -> (name: String, cores: Int) {
        let out = runShell("/usr/sbin/ioreg", ["-l", "-r", "-c", "IOAccelerator", "-w", "0"]) ?? ""
        let name = matchString(in: out, key: "model")
              ?? matchString(in: out, key: "IOName")
              ?? matchString(in: out, key: "device_name")
              ?? "Apple GPU"
        let cores = matchInt(in: out, key: "gpu-core-count") ?? matchInt(in: out, key: "GPUCoreCount") ?? 0
        return (name, cores)
    }

    nonisolated private static func gpuPerf() -> (utilization: Double, inUse: UInt64, alloc: UInt64, recovery: Int) {
        let out = runShell("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator", "-w", "0"]) ?? ""
        let util = Double(matchInt(in: out, key: "Device Utilization %") ?? 0) / 100.0
        let inUse = UInt64(matchInt(in: out, key: "In use system memory") ?? 0)
        let alloc = UInt64(matchInt(in: out, key: "Alloc system memory") ?? 0)
        let recov = matchInt(in: out, key: "recoveryCount") ?? 0
        return (util, inUse, alloc, recov)
    }

    nonisolated private static func matchInt(in text: String, key: String) -> Int? {
        // ioreg formats: `"Key" = 1234`
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"" + escaped + "\"\\s*=\\s*(\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
    nonisolated private static func matchString(in text: String, key: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"" + escaped + "\"\\s*=\\s*\"([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - top processes via `ps`

    nonisolated private static func psTopProcesses(limit: Int) -> [ProcMem] {
        guard let out = runShell("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="]) else { return [] }
        struct Row { let pid: Int32; let bytes: UInt64; let cpu: Double; let comm: String }
        var rows: [Row] = []; rows.reserveCapacity(512)
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            rows.append(Row(pid: pid, bytes: rssKB &* 1024, cpu: cpu, comm: String(parts[3])))
        }
        rows.sort { $0.bytes > $1.bytes }
        let top = Array(rows.prefix(limit))
        return top.map { r -> ProcMem in
            let (display, isApp, bundle) = prettifyProcess(comm: r.comm)
            return ProcMem(id: r.pid, name: display, bytes: r.bytes, cpu: r.cpu, isApp: isApp, bundlePath: bundle)
        }
    }

    nonisolated private static func prettifyProcess(comm: String) -> (String, Bool, String?) {
        if let appRange = comm.range(of: ".app/", options: .backwards) {
            let bundlePath = String(String(comm[..<appRange.upperBound]).dropLast())
            let url = URL(fileURLWithPath: bundlePath)
            let bundle = Bundle(url: url)
            let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            if comm.contains("Helper") {
                let suffix = comm.contains("Renderer") ? " (Renderer)" : comm.contains("GPU") ? " (GPU)" : " Helper"
                return (name + suffix, true, bundlePath)
            }
            return (name, true, bundlePath)
        }
        let last = (comm as NSString).lastPathComponent
        return (last, false, nil)
    }

    nonisolated private static func runShell(_ exec: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Formatters

    var totalText: String { Self.fmt(totalBytes) }
    var usedText: String  { Self.fmt(usedBytes) }
    var freeText: String  { Self.fmt(freeBytes) }
    var swapText: String  { swapTotal == 0 ? "0 B" : "\(Self.fmt(swapUsed)) / \(Self.fmt(swapTotal))" }

    static func fmt(_ b: UInt64) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useGB, .useMB]; f.countStyle = .memory
        return f.string(fromByteCount: Int64(b))
    }
}
