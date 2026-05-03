import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            DesktopBackground()
            AppShell()
            if state.notifOpen { NotifPanel().transition(.opacity) }
            if state.widgetOpen && state.menubarWidgetEnabled { MenuBarWidgetPopover().transition(.opacity) }
            if state.onboardingActive { Onboarding().transition(.opacity) }
            if state.needsFDA { PermissionsGate().transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .tint(state.accent.value)
        .animation(.easeOut(duration: 0.2), value: state.notifOpen)
        .animation(.easeOut(duration: 0.2), value: state.widgetOpen)
        .animation(.easeOut(duration: 0.2), value: state.needsFDA)
    }
}

struct AppShell: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 232)
            VStack(spacing: 0) {
                Topbar()
                ScreenRouter()
                    .id(state.current)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
    }
}

struct ScreenRouter: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        switch state.current {
        case .smartcare:  SmartCareScreen()
        case .dashboard:  DashboardScreen()
        case .storage:    StorageScreen()
        case .large:      LargeFilesScreen()
        case .duplicates: DuplicatesScreen()
        case .unused:     UnusedScreen()
        case .downloads:  DownloadsCacheScreen()
        case .uninstaller:UninstallerScreen()
        case .updater:    UpdaterScreen()
        case .systemjunk: SystemJunkScreen()
        case .privacy:    PrivacyScreen()
        case .cloud:      CloudScreen()
        case .maintenance:MaintenanceScreen()
        case .memory:     MemoryScreen()
        case .startup:    StartupScreen()
        case .battery:    BatteryScreen()
        case .network:    NetworkScreen()
        case .schedules:  SchedulesScreen()
        case .diskHealth: DiskHealthScreen()
        case .permissionsAudit: PermissionsAuditScreen()
        case .threatHygiene:    ThreatHygieneScreen()
        case .analytics:  AnalyticsScreen()
        case .settings:   SettingsScreen()
        }
    }
}
