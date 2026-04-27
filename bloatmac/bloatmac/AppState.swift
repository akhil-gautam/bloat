import SwiftUI
import Combine

enum Screen: String, CaseIterable, Identifiable {
    case dashboard, storage, large, duplicates, unused, downloads
    case memory, startup, battery, network
    case analytics, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:  return "Dashboard"
        case .storage:    return "Storage"
        case .large:      return "Large Files"
        case .duplicates: return "Duplicates"
        case .unused:     return "Unused & Old"
        case .downloads:  return "Downloads & Cache"
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
    @Published var searchQuery: String = ""
    @Published var searchFocusToken: Int = 0   // bumped to nudge focus

    @AppStorage("theme") var themeRaw: String = "dark"          // "light" | "dark"
    @AppStorage("accent") var accentRaw: String = "blue"
    @AppStorage("menubarWidgetEnabled") var menubarWidgetEnabled: Bool = true
    @AppStorage("hasOnboarded") var hasOnboarded: Bool = false

    var accent: AccentKey {
        get { AccentKey(rawValue: accentRaw) ?? .blue }
        set { accentRaw = newValue.rawValue }
    }
    var colorScheme: ColorScheme { themeRaw == "light" ? .light : .dark }

    init() {
        if !hasOnboarded { onboardingActive = true }
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
