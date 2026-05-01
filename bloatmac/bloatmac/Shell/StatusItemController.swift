import AppKit
import SwiftUI
import Combine

/// Owns the real `NSStatusItem` that lives in the system menu bar. Created on
/// app launch when `AppState.menubarWidgetEnabled` is true; torn down when the
/// user toggles it off in Settings.
///
/// The popover content is a SwiftUI view (`StatusItemPopover`) hosted in an
/// `NSHostingController`. It observes the same `AppState` and `Live*.shared`
/// stores the main window does, so values stay in sync.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private let popover: NSPopover
    private weak var state: AppState?
    private var iconUpdateCancellable: AnyCancellable?

    private override init() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 300, height: 260)
        self.popover = pop
        super.init()
    }

    /// Idempotent. Call from `bloatmacApp` on launch and whenever the user
    /// flips `menubarWidgetEnabled` from false → true.
    func start(state: AppState) {
        self.state = state
        if statusItem != nil { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "BloatMac")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.contentViewController = NSHostingController(
            rootView: StatusItemPopover(closePopover: { [weak self] in self?.popover.performClose(nil) })
                .environmentObject(state)
        )

        self.statusItem = item
        bindIconUpdates()
    }

    /// Idempotent. Call when user flips `menubarWidgetEnabled` to false.
    func stop() {
        iconUpdateCancellable?.cancel()
        iconUpdateCancellable = nil
        if popover.isShown { popover.performClose(nil) }
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    // MARK: - Click

    @objc private func togglePopover(_ sender: NSStatusBarButton?) {
        guard let sender else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Live icon

    /// Watch storage and overlay a colored dot when usage crosses warn/danger
    /// thresholds. Cheap — the source publishers tick on the order of seconds.
    private func bindIconUpdates() {
        let storage = LiveStorage.shared
        iconUpdateCancellable = storage.objectWillChange
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let live = LiveStorage.shared
        let pct = live.totalGB > 0 ? live.usedGB / live.totalGB : 0
        let base = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "BloatMac")
        base?.isTemplate = true
        button.image = base
        // Surface a numeric badge once storage is at warn (>70%) so it's
        // glanceable from the menu bar without opening the popover.
        if pct > 0.70 {
            button.title = " \(Int((pct * 100).rounded()))%"
            button.image?.isTemplate = true
        } else {
            button.title = ""
        }
    }
}

// MARK: - SwiftUI popover content

private struct StatusItemPopover: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var storage = LiveStorage.shared
    @ObservedObject private var memory = LiveMemory.shared
    @ObservedObject private var network = LiveNetwork.shared
    let closePopover: () -> Void

    var body: some View {
        let pct = storage.totalGB > 0 ? storage.usedGB / storage.totalGB : 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                BrandMark()
                Text("BloatMac").font(.system(size: 13, weight: .bold))
                Spacer()
                Button("Open ›") {
                    activateApp()
                    closePopover()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Ring(value: pct, size: 64, stroke: 7,
                     color: pct > 0.85 ? Tokens.danger : pct > 0.70 ? Tokens.warn : Tokens.good,
                     label: "\(Int((pct * 100).rounded()))%")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(Int(storage.usedGB.rounded())) GB used")
                        .font(.system(size: 15, weight: .bold))
                    Text("\(Int(storage.freeGB.rounded())) GB free")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 16) {
                StatChip(label: "Memory", value: memoryLabel(), tint: memoryTint())
                StatChip(label: "Net ↓", value: rate(network.rateInBps), tint: Tokens.good)
                StatChip(label: "Net ↑", value: rate(network.rateOutBps), tint: Tokens.good)
            }

            HStack(spacing: 8) {
                Btn(label: "Quick scan", icon: "sparkle.magnifyingglass", style: .primary) {
                    activateApp()
                    state.goto(.dashboard)
                    closePopover()
                }
                Btn(label: "Storage", icon: "internaldrive", style: .ghost) {
                    activateApp()
                    state.goto(.storage)
                    closePopover()
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func memoryLabel() -> String {
        switch memory.pressure {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    private func memoryTint() -> Color {
        switch memory.pressure {
        case .normal:   return Tokens.good
        case .warning:  return Tokens.warn
        case .critical: return Tokens.danger
        }
    }

    private func rate(_ bps: Double) -> String {
        let bytesPerSec = bps / 8.0
        if bytesPerSec >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSec / 1_000_000) }
        if bytesPerSec >= 1_000     { return String(format: "%.0f KB/s", bytesPerSec / 1_000) }
        return "\(Int(bytesPerSec)) B/s"
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
            win.makeKeyAndOrderFront(nil)
        }
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
        }
    }
}
