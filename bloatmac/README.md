# BloatMac

Native macOS SwiftUI companion to the `bloat` CLI — storage and memory management with a polished, Activity-Monitor-grade UI.

## Install

**Homebrew (recommended)**

```sh
brew install --cask akhil-gautam/tap/bloatmac
```

**Direct download**

Grab the `.dmg` or `.zip` from the [releases page](https://github.com/akhil-gautam/bloat/releases) (look for tags starting with `bloatmac-v…`), open the dmg, and drag BloatMac.app into Applications.

The release is **ad-hoc signed** (not Developer-ID notarized). On first launch macOS may flag it as an unidentified developer — right-click the app and choose Open, or run once:

```sh
xattr -dr com.apple.quarantine /Applications/BloatMac.app
```

## Open in Xcode

```sh
open bloatmac.xcodeproj
```

Run with ⌘R. Requires macOS 26 (Tahoe) for the Foundation Models–powered briefing on Dashboard / Analytics; older macOS versions degrade gracefully to the deterministic heuristic briefing.

## What's there

12 screens, all wired with mock data matching `data.js` from the original design bundle:

- **Dashboard** — donut storage breakdown, live RAM area graph, recommendation cards
- **Storage** (hero) — animated squarified treemap with drill-down, category legend, recoverable panel
- **Large files / Duplicates / Unused / Downloads & cache** — cleanup workflows
- **Memory** — live RAM graph (700ms tick), composition bars, processes table with quit
- **Startup items / Battery / Network / Analytics / Settings**
- **Onboarding** — scan animation that plays on first launch (replay from Settings)
- **Notifications panel** + **menu-bar widget popover** (toggled from menu bar)

Theme: light + dark, persisted. Accent: 5 colors (blue/purple/green/orange/pink), live swap.

## Project layout

```
bloatmac/
  bloatmacApp.swift       # @main, hidden-titlebar WindowGroup, ⌘1–⌘9 nav
  ContentView.swift       # root: desktop bg + menubar + window shell + overlays
  AppState.swift          # current screen, theme, accent, overlays state
  Theme/                  # design tokens + accent palettes
  Models/                 # data structs + mock data set
  Components/             # Donut, Sparkline, LiveAreaGraph, Treemap (squarify), Ring, PressureGauge, CountUp, Card, Pill, Btn, Switch, Checkbox
  Shell/                  # DesktopBackground, MenuBarView, Sidebar, Topbar
  Screens/                # 12 screens
  Overlays/               # NotifPanel, MenuBarWidgetPopover, Onboarding
```

## Design source

The design lives in the handoff bundle (`/tmp/bloatmac-design/bloatmac/project/`):

- `BloatMac.html` + `app.jsx` / `screens-1.jsx` / `screens-2.jsx` / `components.jsx`
- `styles.css` — all color/radius/shadow tokens, mirrored in `Theme/DesignTokens.swift`
- `data.js` — mock data, mirrored in `Models/MockData.swift`

Treemap is a Swift port of the Bruls/Huijsen/van Wijk squarified algorithm (`Components/Treemap.swift`).

## V2 roadmap

- XPC bridge to the `bloat` Rust core (`../src/scanner.rs`, `memory_actions.rs`) for real scans and process control
- Real `NSStatusItem` menu-bar widget (currently rendered as in-window popover)
- File-system permission tier flow tied to `../src/permissions.rs`
- Persisted scan history + alerts (`../src/history.rs`, `../src/alerts.rs`)
- Plugin discovery for `../examples/plugins/`

## Plan

See [PLAN.md](PLAN.md) for the full implementation plan and granular TODOs.
