import SwiftUI
import Combine

enum Screen: String, CaseIterable, Identifiable {
    case smartcare, dashboard, storage, large, duplicates, unused, downloads
    case uninstaller, updater, systemjunk, privacy, cloud, maintenance
    case memory, startup, battery, network
    case analytics, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartcare:  return "Smart Care"
        case .dashboard:  return "Dashboard"
        case .storage:    return "Storage"
        case .large:      return "Large Files"
        case .duplicates: return "Duplicates"
        case .unused:     return "Unused & Old"
        case .downloads:  return "Downloads & Cache"
        case .uninstaller:return "Uninstaller"
        case .updater:    return "Updater"
        case .systemjunk: return "System Junk"
        case .privacy:    return "Privacy"
        case .cloud:      return "Cloud"
        case .maintenance:return "Maintenance"
        case .memory:     return "Memory"
        case .startup:    return "Startup Items"
        case .battery:    return "Battery & Energy"
        case .network:    return "Network"
        case .analytics:  return "Analytics"
        case .settings:   return "Settings"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var current: Screen = .dashboard
    @Published var notifOpen = false
    @Published var widgetOpen = false
    @Published var onboardingActive = false
    @Published var needsFDA = false
    @Published var searchQuery: String = ""
    @Published var searchFocusToken: Int = 0   // bumped to nudge focus

    @AppStorage("theme") var themeRaw: String = "dark"          // "light" | "dark"
    @AppStorage("accent") var accentRaw: String = "blue"
    @AppStorage("menubarWidgetEnabled") var menubarWidgetEnabled: Bool = true
    @AppStorage("hasOnboarded") var hasOnboarded: Bool = false
    // Set true when the user dismisses the permissions gate; gate stays hidden
    // until they explicitly re-open it from Settings, even if FDA is still off.
    @AppStorage("permissionsDismissed") var permissionsDismissed: Bool = false

    var accent: AccentKey {
        get { AccentKey(rawValue: accentRaw) ?? .blue }
        set { accentRaw = newValue.rawValue }
    }
    var colorScheme: ColorScheme { themeRaw == "light" ? .light : .dark }

    init() {
        if !hasOnboarded { onboardingActive = true }
        refreshPermissions()
    }

    /// Re-probe Full Disk Access. Cheap (a few directory enumerations); call on
    /// scenePhase .active to pick up grants made in System Settings.
    func refreshPermissions() {
        let granted = Self.hasFullDiskAccess()
        needsFDA = !granted && !permissionsDismissed
        // If the user has now granted access, clear the dismissed flag so the
        // gate would re-appear cleanly if they ever revoke it.
        if granted { permissionsDismissed = false }
    }

    func dismissPermissionsGate() {
        permissionsDismissed = true
        needsFDA = false
    }

    func reopenPermissionsGate() {
        permissionsDismissed = false
        refreshPermissions()
    }

    /// Probe well-known TCC-protected user directories to infer whether the
    /// running app has Full Disk Access. We try several paths: if any exist
    /// and we can list them (or fail with a permission error), we have a
    /// definitive answer. If none exist (fresh machine), assume granted to
    /// avoid pestering the user.
    private static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory() as NSString
        let probes = [
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Safari"),
            home.appendingPathComponent("Library/Messages"),
            home.appendingPathComponent("Library/Suggestions"),
        ]
        let fm = FileManager.default
        for path in probes {
            do {
                let entries = try fm.contentsOfDirectory(atPath: path)
                if !entries.isEmpty { return true }
                // Empty but readable — keep probing in case another path is populated.
            } catch let err as NSError where err.domain == NSCocoaErrorDomain
                && (err.code == NSFileReadNoSuchFileError || err.code == NSFileNoSuchFileError) {
                continue   // path doesn't exist on this machine
            } catch {
                return false   // permission denied — FDA missing
            }
        }
        return true   // inconclusive — assume granted
    }

    func goto(_ s: Screen) {
        withAnimation(.easeOut(duration: 0.22)) { current = s }
        notifOpen = false
        widgetOpen = false
    }

    func toggleNotif() {
        notifOpen.toggle()
        if notifOpen { widgetOpen = false }
    }
    func toggleWidget() {
        widgetOpen.toggle()
        if widgetOpen { notifOpen = false }
    }
    func dismissOnboarding() {
        withAnimation(.easeOut(duration: 0.3)) { onboardingActive = false }
        hasOnboarded = true
    }
    func replayOnboarding() {
        hasOnboarded = false
        withAnimation(.easeOut(duration: 0.2)) { onboardingActive = true }
    }
    func focusSearch() { searchFocusToken &+= 1 }
}
