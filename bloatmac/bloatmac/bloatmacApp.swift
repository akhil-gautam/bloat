import SwiftUI
import AppKit

@main
struct bloatmacApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Apply persisted appearance synchronously, before any window opens,
        // so the system never sees a brief flash of the wrong appearance.
        let theme = UserDefaults.standard.string(forKey: "theme") ?? "dark"
        NSApp?.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    }

    var body: some Scene {
        WindowGroup("BloatMac") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1240, idealWidth: 1480, minHeight: 800, idealHeight: 920)
                .onAppear {
                    applyAppearance(state.themeRaw)
                    if state.menubarWidgetEnabled {
                        StatusItemController.shared.start(state: state)
                    }
                }
                .onChange(of: state.themeRaw) { _, new in applyAppearance(new) }
                .onChange(of: state.menubarWidgetEnabled) { _, enabled in
                    if enabled {
                        StatusItemController.shared.start(state: state)
                    } else {
                        StatusItemController.shared.stop()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { state.refreshPermissions() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { state.goto(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Find") { state.focusSearch() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Go") {
                ForEach(Array(Screen.allCases.enumerated()), id: \.offset) { idx, s in
                    if idx < 9 {
                        Button(s.title) { state.goto(s) }
                            .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                    } else {
                        Button(s.title) { state.goto(s) }
                    }
                }
            }
        }
    }

    private func applyAppearance(_ theme: String) {
        NSApp.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    }
}
