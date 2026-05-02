import Foundation
import AppKit
import Combine

/// Read-only TCC audit. Modern macOS forbids reading `TCC.db` directly
/// (the records are gated by Full Disk Access and Apple-private), so we
/// can't enumerate which apps have actually been *granted* a permission.
///
/// What we can do: scan every installed `.app` bundle's `Info.plist` for
/// the standard usage-description keys (`NSCameraUsageDescription`,
/// `NSMicrophoneUsageDescription`, …). Their presence means the app
/// *declared* it might request the permission — useful as a "candidates"
/// list. Categories that aren't surfaced via Info.plist (Accessibility,
/// Full Disk Access, Screen Recording, Apple Events) get a deep-link to
/// the System Settings pane and a clear "managed by macOS" note.
struct PermissionCategory: Identifiable {
    let id: String              // TCC service identifier
    let title: String
    let icon: String
    let infoPlistKeys: [String] // empty when system-managed
    let settingsAnchor: String  // x-apple.systempreferences anchor
    let apps: [PermissionAppDeclaration]
    let isInfoPlistDriven: Bool

    var deepLinkURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }
}

struct PermissionAppDeclaration: Identifiable, Hashable {
    let id: String              // bundle id
    let displayName: String
    let appURL: URL
    let usageString: String     // first matching usage description (one liner)
}

@MainActor
final class LivePermissionsAudit: ObservableObject {
    static let shared = LivePermissionsAudit()

    @Published private(set) var categories: [PermissionCategory] = []
    @Published private(set) var scanning: Bool = false
    @Published private(set) var lastError: String? = nil

    private var task: Task<Void, Never>? = nil
    private init() {}

    func startIfNeeded() {
        if categories.isEmpty && !scanning { scan() }
    }

    func scan() {
        cancel()
        scanning = true
        task = Task.detached(priority: .userInitiated) { await Self.runScan() }
    }

    func cancel() { task?.cancel(); task = nil; scanning = false }

    func openSettings(for category: PermissionCategory) {
        guard let url = category.deepLinkURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Scan

    private nonisolated static func runScan() async {
        // Build the full app inventory once, then bucket per category.
        let apps = enumerateApps()
        let infoCategories: [(String, String, String, [String], String)] = [
            ("camera",     "Camera",            "camera",        ["NSCameraUsageDescription"],                 "Privacy_Camera"),
            ("microphone", "Microphone",        "mic",           ["NSMicrophoneUsageDescription"],             "Privacy_Microphone"),
            ("photos",     "Photos",            "photo",         ["NSPhotoLibraryUsageDescription",
                                                                  "NSPhotoLibraryAddUsageDescription"],       "Privacy_Photos"),
            ("contacts",   "Contacts",          "person.crop.circle", ["NSContactsUsageDescription"],         "Privacy_AddressBook"),
            ("calendar",   "Calendar",          "calendar",      ["NSCalendarsUsageDescription"],              "Privacy_Calendars"),
            ("reminders",  "Reminders",         "checkmark.circle", ["NSRemindersUsageDescription"],          "Privacy_Reminders"),
            ("location",   "Location",          "location",      ["NSLocationUsageDescription",
                                                                  "NSLocationAlwaysAndWhenInUseUsageDescription",
                                                                  "NSLocationWhenInUseUsageDescription"],     "Privacy_LocationServices"),
            ("bluetooth",  "Bluetooth",         "bolt.horizontal.circle", ["NSBluetoothAlwaysUsageDescription"], "Privacy_Bluetooth"),
            ("speech",     "Speech Recognition","waveform",      ["NSSpeechRecognitionUsageDescription"],     "Privacy_SpeechRecognition"),
            ("siri",       "Siri",              "mic.circle",    ["NSSiriUsageDescription"],                  "Privacy_Siri"),
        ]
        var rows: [PermissionCategory] = []
        for (id, title, icon, keys, anchor) in infoCategories {
            let matching = apps.compactMap { app -> PermissionAppDeclaration? in
                for key in keys {
                    if let usage = app.info[key] as? String, !usage.isEmpty {
                        return PermissionAppDeclaration(id: app.bundleID,
                                                        displayName: app.displayName,
                                                        appURL: app.url,
                                                        usageString: usage)
                    }
                }
                return nil
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            rows.append(PermissionCategory(
                id: id, title: title, icon: icon,
                infoPlistKeys: keys, settingsAnchor: anchor,
                apps: matching, isInfoPlistDriven: true
            ))
        }

        // System-managed categories — Info.plist doesn't carry the entitlement,
        // TCC.db is unreadable, so we surface category + deep-link only.
        let managed: [(String, String, String, String)] = [
            ("fda",          "Full Disk Access",  "lock.shield",  "Privacy_AllFiles"),
            ("screencap",    "Screen Recording",  "rectangle.dashed.badge.record", "Privacy_ScreenCapture"),
            ("accessibility","Accessibility",     "figure.wave",  "Privacy_Accessibility"),
            ("automation",   "Automation",        "gearshape.2",  "Privacy_Automation"),
            ("inputmonitor", "Input Monitoring",  "keyboard",     "Privacy_InputMonitoring"),
        ]
        for (id, title, icon, anchor) in managed {
            rows.append(PermissionCategory(
                id: id, title: title, icon: icon,
                infoPlistKeys: [], settingsAnchor: anchor,
                apps: [], isInfoPlistDriven: false
            ))
        }

        let finalRows = rows
        await MainActor.run {
            LivePermissionsAudit.shared.categories = finalRows
            LivePermissionsAudit.shared.scanning = false
        }
    }

    private struct AppEntry {
        let url: URL
        let bundleID: String
        let displayName: String
        let info: [String: Any]
    }

    private nonisolated static func enumerateApps() -> [AppEntry] {
        let fm = FileManager.default
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        var entries: [AppEntry] = []
        for root in roots {
            guard let urls = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for app in urls where app.pathExtension == "app" {
                let info = app.appendingPathComponent("Contents/Info.plist")
                guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { continue }
                let bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
                guard !bundleID.isEmpty else { continue }
                let name = (dict["CFBundleDisplayName"] as? String)
                        ?? (dict["CFBundleName"] as? String)
                        ?? app.deletingPathExtension().lastPathComponent
                entries.append(AppEntry(url: app, bundleID: bundleID, displayName: name, info: dict))
            }
        }
        return entries
    }
}
