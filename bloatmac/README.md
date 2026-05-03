# BloatMac

Native macOS SwiftUI cleanup + maintenance app. CleanMyMac-class feature surface, none of the subscription friction. Real detection — every module reads actual disk / system state, not mocks.

## Install

```sh
brew install --cask akhil-gautam/tap/bloatmac
```

Or grab the `.dmg` from the [releases page](https://github.com/akhil-gautam/bloat/releases) (tags starting with `bloatmac-v…`).

Releases are **Developer ID signed and Apple-notarized** — Gatekeeper opens the app cleanly, no quarantine workaround needed.

Requires macOS 26 (Tahoe) — the dashboard's AI briefing uses Foundation Models when available and degrades to a deterministic heuristic briefing on older releases.

## Modules

**Sidebar / Overview**
- **Smart Care** — one-click scan that sequences storage refresh, cache scan, duplicate hashing, startup audit, and memory snapshot, then surfaces a consolidated reclaimable-bytes total + actionable recommendations
- **Dashboard** — health score from live subsystems, AI-generated briefing on macOS 26+
- **Analytics** — 30-day history (memory pressure, network, battery, storage trends), CSV export

**Sidebar / Storage**
- **Storage** — animated squarified treemap by category, drill-down, recoverable summary
- **Large files** — recursive scan of home dirs, multi-select trash + reveal in Finder
- **Duplicates** — exact (SHA-256) + visually-similar images (Vision feature print clustering)
- **Unused & old** — apps + files filtered by Spotlight `kMDItemLastUsedDate` / access time
- **Downloads & cache** — auto-categorized downloads, curated safe-cache registry across 20+ apps
- **Uninstaller** — sweeps all leftover paths (Application Support, Caches, Preferences, Saved State, LaunchAgents, Containers, Group Containers) keyed off bundle id + team id
- **Updater** — surfaces updates from Homebrew casks, Mac App Store (mas-cli), and Sparkle feeds; one-click update routes to the right tool
- **System junk** — Xcode DerivedData / iOS DeviceSupport / archives, iOS device backups, Mail attachments, Photos thumbnails, Time Machine local APFS snapshots, broken login items
- **Privacy** — browser data wipe (Chrome / Edge / Brave / Arc / Safari / Firefox) + chat-app caches; refuses while target app is running to avoid corrupting open SQLite journals
- **Cloud** — iCloud Drive cloud-only vs locally-cached classification, `brctl evict` for reclaiming space; Drive / Dropbox / OneDrive / Box detection via `~/Library/CloudStorage/`

**Sidebar / System**
- **Memory** — live VM stats via `host_statistics64`, GPU usage via IOKit, top processes from `ps`, kill via SIGTERM/SIGKILL
- **Startup items** — walks all 5 launchd scopes, risk classification (known/unknown/flagged), enable/disable/remove via launchctl bootouts
- **Battery** — IOKit `AppleSmartBattery` health, cycles, predicted time-to-empty via vDSP regression on 30-day SQLite history
- **Network** — interface rates, Wi-Fi (SSID/BSSID/channel/RSSI), top talkers via `nettop`
- **Maintenance** — DNS flush, RAM purge, periodic scripts, Spotlight reindex, Launch Services rebuild, volume verify; root actions escalate via single OS auth prompt
- **Schedules** — recurring Smart Care runs (hourly / daily / weekly), `UNUserNotificationCenter` notification when reclaimable bytes cross threshold
- **Disk health** — capacity per APFS volume, SMART status, encryption state, local snapshot count
- **Permissions** — TCC audit grouping installed apps by declared usage descriptions; deep-links to System Settings panes for system-managed grants (Full Disk Access, Screen Recording, Accessibility, Automation, Input Monitoring)

**Menu bar widget** — real `NSStatusItem` showing storage %, memory pressure, network rates; click pops a SwiftUI popover with quick-scan + jump-to-screen buttons.

## Open in Xcode

```sh
open bloatmac.xcodeproj
```

Run with ⌘R. ⌘1–⌘9 jump between screens.

## Project layout

```
bloatmac/
  bloatmacApp.swift       # @main, hidden-titlebar WindowGroup, scenePhase + menubar lifecycle
  ContentView.swift       # root: desktop bg + window shell + overlays + screen router
  AppState.swift          # current screen, theme, accent, overlays, FDA gate
  Theme/                  # design tokens + accent palettes
  Models/                 # Live* (real detection / actions) + CleanupLog SQLite
  Components/             # Donut, Sparkline, LiveAreaGraph, Treemap, Ring, etc.
  Shell/                  # Sidebar, Topbar, DesktopBackground, StatusItemController
  Screens/                # 19 screens (one per sidebar entry)
  Overlays/               # NotifPanel, MenuBarWidgetPopover, Onboarding, PermissionsGate
```

Most modules follow the same shape: `Models/Live<Foo>.swift` is a `@MainActor` `ObservableObject` singleton with `@Published` state and detached scan tasks; `Screens/<Foo>Screen.swift` observes it.

## Roadmap

- Threat hygiene scan (codesign anomalies, persistence audit, browser extension review) — heuristic, not signature-based
- Optional persistent privileged helper (SMAppService daemon) for users who don't want a password prompt per maintenance click
- Real LaunchAgent-based background scan (current scheduler runs in-process while the app is open)

## License

MIT. See `../LICENSE` for the umbrella project.
