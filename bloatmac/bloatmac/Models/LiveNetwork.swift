import Foundation
import SwiftUI
import Combine
import Darwin
import AppKit
import CoreLocation
import SQLite3

private let SQLITE_TRANSIENT_NET = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class LocationCoordinator: NSObject, CLLocationManagerDelegate {
    let onAuthChange: (Bool) -> Void
    init(onAuthChange: @escaping (Bool) -> Void) { self.onAuthChange = onAuthChange }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        onAuthChange(s == .authorizedAlways || s == .authorized)
    }
    // Required so requestLocation() doesn't quietly fail on permission flow.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum NetIfType: String { case wifi, ethernet, cellular, loopback, virtual, other
    var icon: String {
        switch self {
        case .wifi:     return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .virtual:  return "rectangle.connected.to.line.below"
        case .other:    return "network"
        }
    }
    var label: String {
        switch self {
        case .wifi: "Wi-Fi"; case .ethernet: "Ethernet"; case .cellular: "Cellular"
        case .loopback: "Loopback"; case .virtual: "Virtual"; case .other: "Other"
        }
    }
}

struct NetIface: Identifiable, Hashable {
    let id: String              // BSD name (en0, en1, lo0…)
    let type: NetIfType
    let displayName: String
    var ipv4: String? = nil
    var ipv6: String? = nil
    var mac: String? = nil
    var mtu: Int = 0
    var isUp: Bool = false
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var pktsIn: UInt64 = 0
    var pktsOut: UInt64 = 0
    var rateInBps: Double = 0       // bytes per second (current)
    var rateOutBps: Double = 0
    var linkSpeedMbps: Double = 0   // best-effort
}

struct NetTalker: Identifiable {
    let id: String                  // process name + pid
    let pid: Int32
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let bundlePath: String?
}

struct NetSample: Codable {
    let t: TimeInterval
    let downBps: Double
    let upBps: Double
    let pingMs: Double          // -1 if unknown
}

enum NetRange: String, CaseIterable, Identifiable {
    case m5 = "5m", h1 = "1h", h6 = "6h", d1 = "1d", d7 = "7d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .m5: return 300; case .h1: return 3600; case .h6: return 21600; case .d1: return 86400; case .d7: return 604800 }
    }
}

@MainActor
final class LiveNetwork: ObservableObject {
    static let shared = LiveNetwork()

    // Live
    @Published private(set) var interfaces: [NetIface] = []
    @Published private(set) var primary: NetIface? = nil
    @Published private(set) var rateInBps: Double = 0
    @Published private(set) var rateOutBps: Double = 0
    @Published private(set) var sessionBytesIn: UInt64 = 0
    @Published private(set) var sessionBytesOut: UInt64 = 0
    @Published private(set) var pingMs: Double = -1
    @Published private(set) var pingHost: String = ""
    @Published private(set) var gateway: String = ""
    @Published private(set) var publicIPv4: String = ""        // best-effort, not fetched by default
    @Published private(set) var dns: [String] = []
    @Published private(set) var ssid: String = ""
    @Published private(set) var bssid: String = ""
    @Published private(set) var rssi: Int = 0
    @Published private(set) var channel: Int = 0
    @Published private(set) var security: String = ""
    @Published private(set) var txRateMbps: Double = 0

    // History
    @Published var range: NetRange = .m5
    @Published private(set) var samples: [NetSample] = []
    // Cached short rolling windows so the throughput sparklines don't reslice the full history each redraw.
    @Published private(set) var recentDown: [Double] = []
    @Published private(set) var recentUp: [Double] = []
    @Published private(set) var locationAuthorized: Bool = false
    @Published private(set) var needsRelaunch: Bool = false

    // Top talkers
    @Published private(set) var talkers: [NetTalker] = []
    @Published var talkerSearch: String = ""

    var filteredTalkers: [NetTalker] {
        let q = talkerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return talkers }
        return talkers.filter { $0.name.lowercased().contains(q) || String($0.pid).contains(q) }
    }

    var samplesInRange: [NetSample] {
        let cutoff = Date().timeIntervalSince1970 - range.seconds
        return samples.filter { $0.t >= cutoff }
    }

    private var timer: Timer?
    private let locationManager = CLLocationManager()
    private var locationCoordinator: LocationCoordinator?
    private var lastTotals: (inB: UInt64, outB: UInt64, t: TimeInterval) = (0, 0, 0)
    private var lastPerIface: [String: (UInt64, UInt64)] = [:]
    private var sessionStartIn: UInt64 = 0
    private var sessionStartOut: UInt64 = 0
    private var tick = 0
    private var db: OpaquePointer?

    nonisolated private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BloatMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("network.sqlite")
    }()

    private init() {
        openDB()
        loadHistory()
        Self.refreshHardwarePortMap()
    }

    nonisolated(unsafe) private static var hwPortType: [String: NetIfType] = [:]

    nonisolated private static func refreshHardwarePortMap() {
        guard let out = runShell("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return }
        var port: String = ""
        var dev: String = ""
        var map: [String: NetIfType] = [:]
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                port = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                dev = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty {
                    let p = port.lowercased()
                    if p.contains("wi-fi") || p.contains("airport") { map[dev] = .wifi }
                    else if p.contains("thunderbolt bridge") || p.contains("bridge") { map[dev] = .virtual }
                    else if p.contains("ethernet") || p.contains("lan") || p.contains("usb") { map[dev] = .ethernet }
                    else if p.contains("bluetooth") { map[dev] = .virtual }
                    else { map[dev] = .other }
                }
            }
        }
        hwPortType = map
    }

    func start() {
        guard timer == nil else { return }
        ensureLocationAuth()
        sample(initial: true)
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func requestLocationAuthorization() {
        ensureLocationAuth(force: true)
    }

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n forces a new instance; -a points at our bundle
        task.arguments = ["-n", "-a", bundleURL.path]
        do { try task.run() } catch { return }
        // Give launchctl a moment to start the new process before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private func ensureLocationAuth(force: Bool = false) {
        let wasAuthorized = locationAuthorized
        let coord = locationCoordinator ?? LocationCoordinator { [weak self] authorized in
            Task { @MainActor in
                guard let self else { return }
                let flipped = !wasAuthorized && authorized
                self.locationAuthorized = authorized
                if authorized { self.refreshNetworkInfo() }
                // The TCC token for child processes is captured at parent launch.
                // If the user just granted access, system_profiler will keep returning
                // <redacted> until we relaunch — flag the UI to surface that.
                if flipped { self.needsRelaunch = true }
            }
        }
        locationCoordinator = coord
        locationManager.delegate = coord
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorized:
            locationAuthorized = true
        case .notDetermined:
            // Bring our process to the front so the system prompt is visible (it would
            // otherwise be hidden if the user just clicked through from another app),
            // then ask for authorization. requestLocation() forces the prompt to appear
            // even on macOS versions where requestAlwaysAuthorization alone is silent.
            NSApp.activate(ignoringOtherApps: true)
            locationManager.requestAlwaysAuthorization()
            locationManager.requestLocation()
            // Safety net: if no prompt has shown within 1.5s (rare cases on macOS 14+),
            // open System Settings so the user has a guaranteed path forward.
            if force {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    let s = self.locationManager.authorizationStatus
                    if s == .notDetermined { Self.openLocationPrefs() }
                }
            }
        case .denied, .restricted:
            locationAuthorized = false
            if force { Self.openLocationPrefs() }
        @unknown default:
            break
        }
    }

    private static func openLocationPrefs() {
        // System Settings URL works on macOS 13+; opening the bundle is a fallback.
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Location"
        ]
        for s in urls { if let u = URL(string: s) { NSWorkspace.shared.open(u); return } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func clearHistory() {
        samples = []
        sqlite3_exec(db, "DELETE FROM net_samples;", nil, nil, nil)
    }

    // MARK: - Sampling

    private func sample(initial: Bool = false) {
        let snapshot = Self.readInterfaces()
        let now = Date().timeIntervalSince1970
        let dt = lastTotals.t == 0 ? 1.0 : max(0.001, now - lastTotals.t)

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var rows: [NetIface] = []
        for var iface in snapshot {
            // Per-iface rates
            let prev = lastPerIface[iface.id]
            if let prev {
                let dIn  = iface.bytesIn  &- min(iface.bytesIn,  prev.0)
                let dOut = iface.bytesOut &- min(iface.bytesOut, prev.1)
                iface.rateInBps  = Double(dIn)  / dt
                iface.rateOutBps = Double(dOut) / dt
            }
            lastPerIface[iface.id] = (iface.bytesIn, iface.bytesOut)
            // Don't count loopback in totals
            if iface.type != .loopback {
                totalIn  &+= iface.bytesIn
                totalOut &+= iface.bytesOut
            }
            rows.append(iface)
        }
        interfaces = rows

        // Pick primary by default route lookup (filled below) or by rate
        if let gw = gateway.split(separator: " ").last.map(String.init), !gw.isEmpty,
           let activeIfName = Self.defaultInterfaceName(),
           let active = rows.first(where: { $0.id == activeIfName }) {
            primary = active
        } else {
            primary = rows
                .filter { $0.type != .loopback && $0.isUp && $0.ipv4 != nil }
                .max(by: { ($0.rateInBps + $0.rateOutBps) < ($1.rateInBps + $1.rateOutBps) })
        }

        if initial {
            sessionStartIn = totalIn
            sessionStartOut = totalOut
            rateInBps = 0; rateOutBps = 0
        } else {
            let dIn  = totalIn  &- min(totalIn,  lastTotals.inB)
            let dOut = totalOut &- min(totalOut, lastTotals.outB)
            rateInBps  = Double(dIn)  / dt
            rateOutBps = Double(dOut) / dt
        }
        sessionBytesIn  = totalIn  &- min(totalIn,  sessionStartIn)
        sessionBytesOut = totalOut &- min(totalOut, sessionStartOut)
        lastTotals = (totalIn, totalOut, now)

        let s = NetSample(t: now, downBps: rateInBps, upBps: rateOutBps, pingMs: pingMs)
        samples.append(s)
        // Keep ~1 hour in memory; SQLite has the full 7d history for the longer ranges.
        let inMemoryCutoff = now - 3600
        if let i = samples.firstIndex(where: { $0.t >= inMemoryCutoff }), i > 0 {
            samples.removeFirst(i)
        }
        // Maintain a 60-sample rolling buffer for the always-visible mini sparklines so
        // the View doesn't reslice the entire history on every redraw.
        var rd = recentDown, ru = recentUp
        rd.append(rateInBps);  if rd.count > 60 { rd.removeFirst(rd.count - 60) }
        ru.append(rateOutBps); if ru.count > 60 { ru.removeFirst(ru.count - 60) }
        recentDown = rd; recentUp = ru
        insertSample(s)

        tick += 1
        if tick % 5 == 1 { refreshNetworkInfo() }   // every 10s: gateway, dns, ssid
        if tick % 3 == 1 { refreshPing() }          // every 6s
        if tick % 4 == 1 { refreshTalkers() }       // every 8s
    }

    // MARK: - Interface enumeration

    nonisolated private static func readInterfaces() -> [NetIface] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(first) }

        var byName: [String: NetIface] = [:]
        var ptr = Optional(first)
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            var iface = byName[name] ?? NetIface(id: name, type: classify(name), displayName: prettyName(name))
            iface.isUp = (ifa.ifa_flags & UInt32(IFF_UP)) != 0
            if let sa = ifa.ifa_addr {
                let family = sa.pointee.sa_family
                if family == sa_family_t(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        iface.ipv4 = String(cString: hostname)
                    }
                } else if family == sa_family_t(AF_INET6) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: hostname)
                        if !s.hasPrefix("fe80") { iface.ipv6 = s }
                    }
                } else if family == sa_family_t(AF_LINK) {
                    if let data = ifa.ifa_data {
                        let if_data = data.assumingMemoryBound(to: if_data.self).pointee
                        iface.bytesIn  = UInt64(if_data.ifi_ibytes)
                        iface.bytesOut = UInt64(if_data.ifi_obytes)
                        iface.pktsIn   = UInt64(if_data.ifi_ipackets)
                        iface.pktsOut  = UInt64(if_data.ifi_opackets)
                        iface.mtu      = Int(if_data.ifi_mtu)
                        iface.linkSpeedMbps = Double(if_data.ifi_baudrate) / 1_000_000
                    }
                    let sdl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
                    iface.mac = macAddress(sdl)
                }
            }
            byName[name] = iface
            ptr = ifa.ifa_next
        }
        // Pull in ifi_data totals from netstat -ibn for any interface where getifaddrs gave 32-bit counters truncated
        if let totals = readNetstatTotals() {
            for (k, v) in totals {
                if var i = byName[k] {
                    if v.0 > i.bytesIn  { i.bytesIn  = v.0 }
                    if v.1 > i.bytesOut { i.bytesOut = v.1 }
                    byName[k] = i
                }
            }
        }
        // Sort by relevance: primary types first, then by traffic
        let order: [NetIfType: Int] = [.ethernet: 0, .wifi: 1, .cellular: 2, .virtual: 3, .other: 4, .loopback: 5]
        return byName.values.sorted {
            let a = order[$0.type] ?? 99, b = order[$1.type] ?? 99
            if a != b { return a < b }
            return ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut)
        }
    }

    nonisolated private static func macAddress(_ sdl: sockaddr_dl) -> String? {
        guard sdl.sdl_alen == 6 else { return nil }
        var sdl = sdl
        return withUnsafePointer(to: &sdl.sdl_data) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(sdl.sdl_nlen) + 6) { base in
                let macPtr = base.advanced(by: Int(sdl.sdl_nlen))
                return String(format: "%02x:%02x:%02x:%02x:%02x:%02x",
                              macPtr[0], macPtr[1], macPtr[2],
                              macPtr[3], macPtr[4], macPtr[5])
            }
        }
    }

    nonisolated private static func classify(_ name: String) -> NetIfType {
        if name == "lo0" { return .loopback }
        if let mapped = hwPortType[name] { return mapped }
        if name.hasPrefix("en") { return .ethernet }
        if name.hasPrefix("eth") { return .ethernet }
        if name.hasPrefix("pdp_ip") || name.hasPrefix("rmnet") { return .cellular }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tun") || name.hasPrefix("tap") { return .virtual }
        if name.hasPrefix("bridge") || name.hasPrefix("awdl") || name.hasPrefix("llw") { return .virtual }
        return .other
    }
    nonisolated private static func prettyName(_ name: String) -> String {
        if name == "lo0" { return "Loopback" }
        if name.hasPrefix("utun") { return "VPN (\(name))" }
        if name.hasPrefix("awdl") { return "AirDrop (\(name))" }
        if name.hasPrefix("bridge") { return "Bridge (\(name))" }
        return name.uppercased()
    }

    nonisolated private static func readNetstatTotals() -> [String: (UInt64, UInt64)]? {
        guard let out = runShell("/usr/sbin/netstat", ["-ibn"]) else { return nil }
        var result: [String: (UInt64, UInt64)] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // Look for rows with <Link#> as Network so each iface is counted once
            guard parts.count >= 10, parts[2].hasPrefix("<Link#") else { continue }
            let name = String(parts[0])
            let ibytes = UInt64(parts[6]) ?? 0
            let obytes = UInt64(parts[9]) ?? 0
            result[name] = (ibytes, obytes)
        }
        return result
    }

    nonisolated private static func defaultInterfaceName() -> String? {
        guard let out = runShell("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return String(trimmed.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Background lookups

    private func refreshNetworkInfo() {
        Task.detached(priority: .utility) {
            let gw   = Self.lookupGateway()
            let dns  = Self.lookupDNS()
            let wifi = Self.lookupWiFi()
            await MainActor.run {
                self.gateway = gw
                self.dns = dns
                if let w = wifi {
                    self.ssid = w.ssid; self.bssid = w.bssid; self.rssi = w.rssi
                    self.channel = w.channel; self.security = w.security; self.txRateMbps = w.txRate
                }
            }
        }
    }

    private func refreshPing() {
        let host = gateway.isEmpty ? "1.1.1.1" : gateway
        let captured = host
        Task.detached(priority: .utility) {
            let ms = Self.pingHost(captured)
            await MainActor.run { self.pingMs = ms; self.pingHost = captured }
        }
    }

    private func refreshTalkers() {
        Task.detached(priority: .utility) {
            let rows = Self.readTopTalkers(limit: 20)
            await MainActor.run { self.talkers = rows }
        }
    }

    nonisolated private static func lookupGateway() -> String {
        guard let out = runShell("/sbin/route", ["-n", "get", "default"]) else { return "" }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    nonisolated private static func lookupDNS() -> [String] {
        guard let out = runShell("/usr/sbin/scutil", ["--dns"]) else { return [] }
        var seen = Set<String>(); var ordered: [String] = []
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // "nameserver[0] : 1.1.1.1"
            if t.hasPrefix("nameserver["),
               let colon = t.firstIndex(of: ":") {
                let v = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && !seen.contains(v) { seen.insert(v); ordered.append(v) }
            }
        }
        return ordered
    }

    private struct WiFi { let ssid: String; let bssid: String; let rssi: Int; let channel: Int; let security: String; let txRate: Double }

    nonisolated private static func lookupWiFi() -> WiFi? {
        // system_profiler is reliable & doesn't need sudo. Slow-ish, called every 10s only.
        guard let out = runShell("/usr/sbin/system_profiler", ["-json", "SPAirPortDataType"]) else { return nil }
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPAirPortDataType"] as? [[String: Any]] else { return nil }
        for entry in arr {
            guard let interfaces = entry["spairport_airport_interfaces"] as? [[String: Any]] else { continue }
            for iface in interfaces {
                if let current = iface["spairport_current_network_information"] as? [String: Any] {
                    let ssid = (current["_name"] as? String) ?? ""
                    let bssid = (current["spairport_network_bssid"] as? String) ?? ""
                    let channelStr = (current["spairport_network_channel"] as? String) ?? ""
                    let channel = Int(channelStr.split(separator: " ").first.map(String.init) ?? "") ?? 0
                    let rssiStr = (current["spairport_signal_noise"] as? String) ?? ""
                    var rssi = 0
                    if let r = rssiStr.split(separator: "/").first?.split(separator: " ").first.map(String.init), let n = Int(r) { rssi = n }
                    let security = (current["spairport_security_mode"] as? String) ?? ""
                    let txStr = (current["spairport_network_rate"] as? String) ?? ""
                    let tx = Double(txStr.split(separator: " ").first.map(String.init) ?? "") ?? 0
                    return WiFi(ssid: ssid, bssid: bssid, rssi: rssi, channel: channel,
                                security: prettySecurity(security), txRate: tx)
                }
            }
        }
        return nil
    }

    nonisolated private static func prettySecurity(_ raw: String) -> String {
        let t = raw.lowercased()
        if t.contains("wpa3") { return "WPA3" }
        if t.contains("wpa2") { return "WPA2" }
        if t.contains("wpa")  { return "WPA"  }
        if t.contains("wep")  { return "WEP"  }
        if t.contains("none") || t.contains("open") { return "Open" }
        return raw.replacingOccurrences(of: "spairport_security_mode_", with: "").uppercased()
    }

    nonisolated private static func pingHost(_ host: String) -> Double {
        guard !host.isEmpty,
              let out = runShell("/sbin/ping", ["-c", "1", "-t", "2", "-q", host]) else { return -1 }
        // Look for "round-trip min/avg/max/stddev = a/b/c/d ms"
        if let line = out.split(separator: "\n").first(where: { $0.contains("min/avg/") }) {
            let parts = line.split(separator: "=")
            if parts.count >= 2 {
                let nums = parts[1].split(separator: "/")
                if nums.count >= 2, let avg = Double(nums[1].trimmingCharacters(in: .whitespaces)) {
                    return avg
                }
            }
        }
        return -1
    }

    nonisolated private static func readTopTalkers(limit: Int) -> [NetTalker] {
        guard let out = runShell("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]) else { return [] }
        struct R { let pid: Int32; let name: String; let bIn: UInt64; let bOut: UInt64 }
        var rows: [R] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // Expected: ["", "process.pid", "bytes_in", "bytes_out"] or with leading time on first row
            guard cols.count >= 4 else { continue }
            // Find a token shaped "name.<pid>" and two trailing numbers
            for i in 0..<cols.count - 2 {
                let token = cols[i].trimmingCharacters(in: .whitespaces)
                guard let dot = token.lastIndex(of: "."),
                      let pid = Int32(token[token.index(after: dot)...]) else { continue }
                let name = String(token[..<dot])
                let bin  = UInt64(cols[i+1].trimmingCharacters(in: .whitespaces)) ?? 0
                let bout = UInt64(cols[i+2].trimmingCharacters(in: .whitespaces)) ?? 0
                if bin == 0 && bout == 0 { break }
                rows.append(R(pid: pid, name: name, bIn: bin, bOut: bout))
                break
            }
        }
        // Aggregate by pid (nettop sometimes shows multi-rows per process)
        var agg: [Int32: R] = [:]
        for r in rows {
            if let existing = agg[r.pid] {
                agg[r.pid] = R(pid: r.pid, name: existing.name, bIn: existing.bIn + r.bIn, bOut: existing.bOut + r.bOut)
            } else { agg[r.pid] = r }
        }
        let sorted = agg.values.sorted { ($0.bIn + $0.bOut) > ($1.bIn + $1.bOut) }
        let ws = NSWorkspace.shared
        return sorted.prefix(limit).map { r -> NetTalker in
            let bundlePath = ws.runningApplications.first { $0.processIdentifier == r.pid }?.bundleURL?.path
            return NetTalker(id: "\(r.name).\(r.pid)", pid: r.pid, name: r.name,
                             bytesIn: r.bIn, bytesOut: r.bOut, bundlePath: bundlePath)
        }
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

    // MARK: - SQLite

    private func openDB() {
        let path = Self.dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS net_samples(
                t REAL PRIMARY KEY, down_bps REAL, up_bps REAL, ping_ms REAL
            );
            CREATE INDEX IF NOT EXISTS idx_net_t ON net_samples(t);
        """, nil, nil, nil)
        // Trim >7d
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM net_samples WHERE t<?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff); sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func insertSample(_ s: NetSample) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO net_samples(t,down_bps,up_bps,ping_ms) VALUES (?,?,?,?)",
            -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, s.t)
        sqlite3_bind_double(stmt, 2, s.downBps)
        sqlite3_bind_double(stmt, 3, s.upBps)
        sqlite3_bind_double(stmt, 4, s.pingMs)
        sqlite3_step(stmt)
    }

    private func loadHistory() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        if sqlite3_prepare_v2(db, "SELECT t,down_bps,up_bps,ping_ms FROM net_samples WHERE t>=? ORDER BY t ASC", -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, cutoff)
        var rows: [NetSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(NetSample(
                t: sqlite3_column_double(stmt, 0),
                downBps: sqlite3_column_double(stmt, 1),
                upBps: sqlite3_column_double(stmt, 2),
                pingMs: sqlite3_column_double(stmt, 3)
            ))
        }
        samples = rows
    }

    // MARK: - Formatting

    static func bps(_ v: Double) -> String {
        let bits = v * 8
        if bits >= 1_000_000_000 { return String(format: "%.2f Gb/s", bits / 1_000_000_000) }
        if bits >= 1_000_000     { return String(format: "%.1f Mb/s", bits / 1_000_000) }
        if bits >= 1_000         { return String(format: "%.0f Kb/s", bits / 1_000) }
        return String(format: "%.0f b/s", bits)
    }
    static func bytes(_ v: UInt64) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useGB, .useMB, .useKB]; f.countStyle = .binary
        return f.string(fromByteCount: Int64(v))
    }

    var rssiPct: Double {
        // RSSI typical range: -30 (excellent) to -90 (poor)
        if rssi == 0 { return 0 }
        let clamped = max(-90, min(-30, Double(rssi)))
        return (clamped + 90) / 60
    }

    var rssiLabel: String {
        if rssi == 0 { return "—" }
        if rssi >= -50 { return "Excellent" }
        if rssi >= -60 { return "Good" }
        if rssi >= -70 { return "Fair" }
        return "Weak"
    }
}
