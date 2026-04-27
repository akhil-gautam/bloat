import Foundation
import SwiftUI
import Combine
import IOKit
import IOKit.ps
import AppKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum BatteryState: String { case charging, discharging, full, ac
    var label: String {
        switch self {
        case .charging:    return "Charging"
        case .discharging: return "On battery"
        case .full:        return "Fully charged"
        case .ac:          return "Plugged in"
        }
    }
    var color: Color {
        switch self {
        case .charging:    return Tokens.good
        case .discharging: return Tokens.warn
        case .full:        return Tokens.good
        case .ac:          return Tokens.catApps
        }
    }
    var icon: String {
        switch self {
        case .charging:    return "bolt.fill"
        case .discharging: return "battery.50"
        case .full:        return "battery.100"
        case .ac:          return "powerplug.fill"
        }
    }
}

struct BatteryReading: Codable {
    let t: TimeInterval
    let percent: Double         // 0...1
    let charging: Int           // -1 discharge, 0 idle, 1 charge
    let watts: Double           // signed: negative draining, positive charging
    let voltage: Double         // V
    let amperage: Double        // A (signed)
    let tempC: Double
    let timeRemaining: Int      // minutes; 0 if unknown
}

struct BatteryHealthSnapshot: Codable {
    let t: TimeInterval
    let designCapacity: Int     // mAh or mWh raw
    let maxCapacity: Int
    let cycleCount: Int
}

enum BatteryRange: String, CaseIterable, Identifiable {
    case h1 = "1h", h6 = "6h", d1 = "1d", d7 = "7d", d30 = "30d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .h1: return 3600; case .h6: return 21600; case .d1: return 86400; case .d7: return 604800; case .d30: return 2_592_000 }
    }
}

@MainActor
final class LiveBattery: ObservableObject {
    static let shared = LiveBattery()

    // Live snapshot
    @Published private(set) var hasBattery: Bool = false
    @Published private(set) var percent: Double = 0
    @Published private(set) var state: BatteryState = .ac
    @Published private(set) var watts: Double = 0
    @Published private(set) var voltage: Double = 0
    @Published private(set) var amperage: Double = 0
    @Published private(set) var tempC: Double = 0
    @Published private(set) var timeRemaining: Int = 0    // minutes from system
    @Published private(set) var fullyCharged: Bool = false
    @Published private(set) var externalConnected: Bool = false

    // Health
    @Published private(set) var designCapacity: Int = 0
    @Published private(set) var maxCapacity: Int = 0
    @Published private(set) var cycleCount: Int = 0
    @Published private(set) var maxCycleCount: Int = 1000

    // Identity
    @Published private(set) var manufacturer: String = ""
    @Published private(set) var deviceName: String = ""
    @Published private(set) var serial: String = ""
    @Published private(set) var manufactureDate: Date? = nil
    @Published private(set) var adapterWatts: Int = 0
    @Published private(set) var adapterName: String = ""
    @Published private(set) var optimizedCharging: Bool = false
    @Published private(set) var lowPowerMode: Bool = false

    // Predicted remaining (AI-ish via linear regression on recent samples)
    @Published private(set) var predictedRemainingMin: Int = 0
    @Published private(set) var predictedDrainPctPerHour: Double = 0

    // History
    @Published var range: BatteryRange = .d1
    @Published private(set) var samples: [BatteryReading] = []
    @Published private(set) var healthHistory: [BatteryHealthSnapshot] = []

    // Insights
    @Published private(set) var insights: [BatteryInsight] = []

    // Daily routine: 24 buckets of "fraction of time on AC" (0...1)
    @Published private(set) var hourlyAC: [Double] = Array(repeating: 0, count: 24)

    // Top energy consumers (CPU% as a live proxy; sampled when discharging)
    @Published private(set) var topConsumers: [ProcMem] = []

    private var timer: Timer?
    private var db: OpaquePointer?
    private var sampleTick = 0

    nonisolated private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("battery.sqlite")
    }()

    private init() {
        openDB()
        readIdentity()
        readPMSet()
        readSamples()
        readHealth()
        recomputeDerived()
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    func clearHistory() {
        samples = []
        sqlite3_exec(db, "DELETE FROM samples; DELETE FROM health;", nil, nil, nil)
        recomputeDerived()
    }

    // MARK: - Sampling

    private func sample() {
        guard let snap = readBattery() else {
            hasBattery = false; return
        }
        hasBattery = true
        percent      = snap.percent
        watts        = snap.watts
        voltage      = snap.voltage
        amperage     = snap.amperage
        tempC        = snap.tempC
        timeRemaining = snap.timeRemaining
        fullyCharged = snap.fullyCharged
        externalConnected = snap.external
        designCapacity = snap.designCap
        maxCapacity = snap.maxCap
        cycleCount = snap.cycle
        adapterWatts = snap.adapterWatts
        adapterName = snap.adapterName

        if snap.fullyCharged && snap.external { state = .full }
        else if snap.charging                   { state = .charging }
        else if snap.external                   { state = .ac }
        else                                    { state = .discharging }

        let reading = BatteryReading(
            t: Date().timeIntervalSince1970,
            percent: snap.percent,
            charging: snap.charging ? 1 : (snap.external ? 0 : -1),
            watts: snap.watts,
            voltage: snap.voltage,
            amperage: snap.amperage,
            tempC: snap.tempC,
            timeRemaining: snap.timeRemaining
        )
        samples.append(reading)
        // Keep ~2h in memory (1440 samples @ 5s); SQLite holds the full 30d for longer ranges.
        if samples.count > 1440 { samples.removeFirst(samples.count - 1440) }
        insertSample(reading)

        sampleTick += 1
        if sampleTick % 12 == 1 {       // every minute
            insertHealth(BatteryHealthSnapshot(
                t: reading.t, designCapacity: snap.designCap,
                maxCapacity: snap.maxCap, cycleCount: snap.cycle
            ))
            readPMSet()
            refreshTopConsumers()
            recomputeDerived()
        }
    }

    // MARK: - IOKit reads

    private struct Snap {
        let percent: Double
        let watts: Double
        let voltage: Double
        let amperage: Double
        let tempC: Double
        let timeRemaining: Int
        let designCap: Int
        let maxCap: Int
        let cycle: Int
        let charging: Bool
        let external: Bool
        let fullyCharged: Bool
        let adapterWatts: Int
        let adapterName: String
    }

    private func readBattery() -> Snap? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // CurrentCapacity / MaxCapacity on Apple Silicon are normalized 0–100 (charge level).
        // Real-mAh values come from AppleRawCurrentCapacity / AppleRawMaxCapacity (or
        // BatteryData → NominalChargeCapacity), and DesignCapacity is in mAh.
        let cur = (dict["CurrentCapacity"] as? Int) ?? 0
        let mxNorm = (dict["MaxCapacity"]  as? Int) ?? 100
        let bd  = dict["BatteryData"] as? [String: Any]
        let rawMax: Int = (dict["AppleRawMaxCapacity"] as? Int)
                       ?? (bd?["NominalChargeCapacity"] as? Int)
                       ?? 0
        let dcRaw: Int = (dict["DesignCapacity"] as? Int)
                       ?? (bd?["DesignCapacity"] as? Int)
                       ?? 0
        // Use mAh values for cap reporting; fall back to the normalized values if mAh is unavailable.
        let mx = rawMax > 0 ? rawMax : mxNorm
        let dc = dcRaw > 0 ? dcRaw : mx
        let cyc = (dict["CycleCount"] as? Int) ?? (bd?["CycleCount"] as? Int) ?? 0
        let v   = Double((dict["Voltage"] as? Int) ?? 0) / 1000.0    // mV → V
        let aRaw = (dict["Amperage"] as? Int64) ?? Int64((dict["Amperage"] as? Int) ?? 0)
        // Handle signed 16/32-bit weirdness — IOKit sometimes returns large positive instead of negative.
        let amp: Double = {
            var x = Double(aRaw) / 1000.0     // mA → A
            if x > 50 { x -= 65.536 }         // wrap-around for old hardware
            return x
        }()
        let watts = v * amp                    // signed: negative draining
        let temp = Double((dict["Temperature"] as? Int) ?? 0) / 100.0
        let tte = (dict["AvgTimeToEmpty"] as? Int) ?? 0
        let ttf = (dict["AvgTimeToFull"]  as? Int) ?? 0
        let timeRemaining: Int = {
            let t1 = (tte > 0 && tte < 0xFFFF) ? tte : 0
            let t2 = (ttf > 0 && ttf < 0xFFFF) ? ttf : 0
            return t1 != 0 ? t1 : t2
        }()
        let charging = (dict["IsCharging"] as? Bool) ?? false
        let external = (dict["ExternalConnected"] as? Bool) ?? false
        let full     = (dict["FullyCharged"] as? Bool) ?? false
        let adapter  = dict["AdapterDetails"] as? [String: Any]
        let aw       = (adapter?["Watts"] as? Int) ?? 0
        let an       = (adapter?["Description"] as? String) ?? (adapter?["Name"] as? String) ?? ""

        return Snap(
            percent: max(mxNorm, 1) > 0 ? Double(cur) / Double(mxNorm) : 0,
            watts: watts, voltage: v, amperage: amp, tempC: temp,
            timeRemaining: timeRemaining,
            designCap: dc, maxCap: mx, cycle: cyc,
            charging: charging, external: external, fullyCharged: full,
            adapterWatts: aw, adapterName: an
        )
    }

    private func readIdentity() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        manufacturer = (dict["Manufacturer"] as? String) ?? ""
        deviceName   = (dict["DeviceName"] as? String) ?? ""
        serial       = (dict["BatterySerialNumber"] as? String)
                    ?? (dict["Serial"] as? String) ?? ""
        if let raw = dict["ManufactureDate"] as? Int {
            // packed: bits 0-4 day, 5-8 month, 9-15 year (since 1980)
            let day = raw & 0x1F
            let month = (raw >> 5) & 0x0F
            let year = ((raw >> 9) & 0x7F) + 1980
            var c = DateComponents(); c.day = day; c.month = month; c.year = year
            manufactureDate = Calendar(identifier: .gregorian).date(from: c)
        }
    }

    private func readPMSet() {
        if let out = runShell("/usr/bin/pmset", ["-g"]) {
            lowPowerMode = out.contains("lowpowermode         1")
        }
        if let out = runShell("/usr/bin/pmset", ["-g", "adapter"]) {
            // "Optimized Battery Charging Engaged: 1"  (varies)
            optimizedCharging = out.lowercased().contains("optimized") || out.contains("OptimizedBatteryChargingEngaged = 1")
        }
    }

    private func refreshTopConsumers() {
        guard state == .discharging else { topConsumers = []; return }
        Task.detached(priority: .utility) {
            let rows = Self.psTopByCPU(limit: 6)
            await MainActor.run { LiveBattery.shared.topConsumers = rows }
        }
    }

    nonisolated private static func psTopByCPU(limit: Int) -> [ProcMem] {
        guard let out = runShell("/bin/ps", ["-axo", "pid=,rss=,%cpu=,comm="]) else { return [] }
        struct R { let pid: Int32; let rss: UInt64; let cpu: Double; let comm: String }
        var rows: [R] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let rss = UInt64(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            rows.append(R(pid: pid, rss: rss * 1024, cpu: cpu, comm: String(parts[3])))
        }
        rows.sort { $0.cpu > $1.cpu }
        let top = Array(rows.prefix(limit))
        return top.map { r in
            let pretty = prettify(comm: r.comm)
            return ProcMem(id: r.pid, name: pretty.0, bytes: r.rss, cpu: r.cpu, isApp: pretty.1, bundlePath: pretty.2)
        }
    }
    nonisolated private static func prettify(comm: String) -> (String, Bool, String?) {
        if let appRange = comm.range(of: ".app/", options: .backwards) {
            let bp = String(String(comm[..<appRange.upperBound]).dropLast())
            let url = URL(fileURLWithPath: bp)
            let bundle = Bundle(url: url)
            let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            return (name, true, bp)
        }
        return ((comm as NSString).lastPathComponent, false, nil)
    }
    nonisolated private static func runShell(_ exec: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    private func runShell(_ e: String, _ a: [String]) -> String? { Self.runShell(e, a) }

    // MARK: - Derived (regression, hourly heatmap, insights)

    private func recomputeDerived() {
        // Predicted drain from last ~10 minutes of discharge samples — least squares on (t, percent)
        let now = Date().timeIntervalSince1970
        let recent = samples.suffix(180).filter { now - $0.t <= 1800 }    // last 30m
        let dis = recent.filter { $0.charging == -1 }
        if dis.count >= 4 {
            let xs = dis.map { $0.t }
            let ys = dis.map { $0.percent }
            if let slope = leastSquaresSlope(xs: xs, ys: ys), slope < 0 {
                predictedDrainPctPerHour = -slope * 3600 * 100
                let levels = ys.last ?? percent
                let secsToZero = levels / -slope
                predictedRemainingMin = max(0, Int(secsToZero / 60))
            } else {
                predictedDrainPctPerHour = 0
                predictedRemainingMin = 0
            }
        } else {
            predictedDrainPctPerHour = 0
            predictedRemainingMin = 0
        }

        // Hourly AC fraction over last 7 days
        var sums = Array(repeating: 0.0, count: 24)
        var counts = Array(repeating: 0.0, count: 24)
        let cutoff = now - 7 * 86400
        let cal = Calendar(identifier: .gregorian)
        for s in samples where s.t >= cutoff {
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: s.t))
            counts[h] += 1
            if s.charging != -1 { sums[h] += 1 }
        }
        hourlyAC = (0..<24).map { counts[$0] > 0 ? sums[$0] / counts[$0] : 0 }

        // Insights
        var out: [BatteryInsight] = []
        let healthPct = designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0
        if healthPct > 0 && healthPct < 0.80 {
            out.append(.init(icon: "heart.text.square.fill",
                             tone: .warn,
                             title: "Battery health is \(Int((healthPct*100).rounded()))%",
                             body: "Capacity has dropped below 80% of design. Consider a service appointment."))
        }
        if cycleCount > 0 {
            let frac = Double(cycleCount) / Double(maxCycleCount)
            if frac > 0.85 {
                out.append(.init(icon: "arrow.2.circlepath",
                                 tone: .warn,
                                 title: "\(cycleCount) charge cycles",
                                 body: "Approaching the typical \(maxCycleCount)-cycle rating."))
            } else {
                out.append(.init(icon: "arrow.2.circlepath",
                                 tone: .info,
                                 title: "\(cycleCount) charge cycles",
                                 body: "About \(Int((frac*100).rounded()))% of typical lifetime."))
            }
        }
        if state == .discharging && predictedDrainPctPerHour > 18 {
            out.append(.init(icon: "exclamationmark.triangle.fill",
                             tone: .warn,
                             title: "High drain — \(String(format: "%.1f", predictedDrainPctPerHour))%/hr",
                             body: "Significantly above your normal rate. Check the top energy users below."))
        }
        if !optimizedCharging && cycleCount > 100 && externalConnected {
            out.append(.init(icon: "leaf.fill",
                             tone: .info,
                             title: "Enable Optimized Battery Charging",
                             body: "macOS can learn your charging routine to slow long-term wear."))
        }
        if tempC > 35 {
            out.append(.init(icon: "thermometer.high",
                             tone: .warn,
                             title: "Battery is warm — \(Int(tempC.rounded()))°C",
                             body: "Sustained heat accelerates capacity loss."))
        }
        if let d = manufactureDate {
            let years = Date().timeIntervalSince(d) / (365 * 86400)
            if years > 4 {
                out.append(.init(icon: "calendar",
                                 tone: .info,
                                 title: "Battery is \(String(format: "%.1f", years)) years old",
                                 body: "Manufactured \(d.formatted(.dateTime.year().month()))."))
            }
        }
        if out.isEmpty {
            out.append(.init(icon: "checkmark.seal.fill", tone: .good,
                             title: "Battery looks healthy",
                             body: "No anomalies detected in the recent history."))
        }
        insights = out
    }

    private func leastSquaresSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - mx
            num += dx * (ys[i] - my)
            den += dx * dx
        }
        return den == 0 ? nil : num / den
    }

    // MARK: - SQLite

    private func openDB() {
        let path = Self.dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS samples(
                t REAL PRIMARY KEY,
                percent REAL, charging INTEGER, watts REAL,
                voltage REAL, amperage REAL, temp REAL, time_remaining INTEGER
            );
            CREATE TABLE IF NOT EXISTS health(
                t REAL PRIMARY KEY,
                design_capacity INTEGER, max_capacity INTEGER, cycle_count INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_samples_t ON samples(t);
            CREATE INDEX IF NOT EXISTS idx_health_t  ON health(t);
        """, nil, nil, nil)
        // Trim anything older than 30 days
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM samples WHERE t<?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff); sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Drop any rows that were captured with the old (broken) capacity formula —
        // anything where max_capacity was the normalized 0–100 value.
        sqlite3_exec(db, "DELETE FROM health WHERE max_capacity <= 100;", nil, nil, nil)
    }

    private func insertSample(_ r: BatteryReading) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO samples(t,percent,charging,watts,voltage,amperage,temp,time_remaining) VALUES (?,?,?,?,?,?,?,?)",
            -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, r.t)
        sqlite3_bind_double(stmt, 2, r.percent)
        sqlite3_bind_int(stmt,    3, Int32(r.charging))
        sqlite3_bind_double(stmt, 4, r.watts)
        sqlite3_bind_double(stmt, 5, r.voltage)
        sqlite3_bind_double(stmt, 6, r.amperage)
        sqlite3_bind_double(stmt, 7, r.tempC)
        sqlite3_bind_int(stmt,    8, Int32(r.timeRemaining))
        sqlite3_step(stmt)
    }

    private func insertHealth(_ h: BatteryHealthSnapshot) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO health(t,design_capacity,max_capacity,cycle_count) VALUES (?,?,?,?)",
            -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, h.t)
        sqlite3_bind_int(stmt,    2, Int32(h.designCapacity))
        sqlite3_bind_int(stmt,    3, Int32(h.maxCapacity))
        sqlite3_bind_int(stmt,    4, Int32(h.cycleCount))
        sqlite3_step(stmt)
        healthHistory.append(h)
    }

    private func readSamples() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        if sqlite3_prepare_v2(db, "SELECT t,percent,charging,watts,voltage,amperage,temp,time_remaining FROM samples WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        var rows: [BatteryReading] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(BatteryReading(
                t: sqlite3_column_double(stmt, 0),
                percent: sqlite3_column_double(stmt, 1),
                charging: Int(sqlite3_column_int(stmt, 2)),
                watts: sqlite3_column_double(stmt, 3),
                voltage: sqlite3_column_double(stmt, 4),
                amperage: sqlite3_column_double(stmt, 5),
                tempC: sqlite3_column_double(stmt, 6),
                timeRemaining: Int(sqlite3_column_int(stmt, 7))
            ))
        }
        samples = rows
    }

    private func readHealth() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT t,design_capacity,max_capacity,cycle_count FROM health ORDER BY t ASC", -1, &stmt, nil) != SQLITE_OK { return }
        var rows: [BatteryHealthSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(BatteryHealthSnapshot(
                t: sqlite3_column_double(stmt, 0),
                designCapacity: Int(sqlite3_column_int(stmt, 1)),
                maxCapacity: Int(sqlite3_column_int(stmt, 2)),
                cycleCount: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        healthHistory = rows
    }

    // MARK: - Derived helpers exposed to view

    var samplesInRange: [BatteryReading] {
        let cutoff = Date().timeIntervalSince1970 - range.seconds
        return samples.filter { $0.t >= cutoff }
    }

    var healthFraction: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0
    }

    var ageText: String {
        guard let d = manufactureDate else { return "Unknown" }
        let years = Date().timeIntervalSince(d) / (365.25 * 86400)
        if years < 1 { return "\(Int((years * 12).rounded())) months" }
        return String(format: "%.1f years", years)
    }

    var timeRemainingText: String {
        let m = predictedRemainingMin > 0 ? predictedRemainingMin : timeRemaining
        if m <= 0 { return "—" }
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }
}

struct BatteryInsight: Identifiable {
    enum Tone { case good, info, warn, danger
        var color: Color {
            switch self { case .good: return Tokens.good; case .info: return Tokens.catApps; case .warn: return Tokens.warn; case .danger: return Tokens.danger }
        }
    }
    let id = UUID()
    let icon: String
    let tone: Tone
    let title: String
    let body: String
}
