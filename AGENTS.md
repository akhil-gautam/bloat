# Agent guide

## Scope and working approach

This repository contains two independent macOS products. The checkout may be named
`memclean`, but the Rust package/binary is **bloat** and the desktop product is
**BloatMac**. There is no Rust–Swift bridge or shared cleanup engine.

- Identify which product the request affects before editing. Trace the relevant
  entry point, callers, detection logic, and action handler; similar features in
  the other product do not automatically need the same change.
- Reuse existing helpers, native APIs, and installed dependencies. Keep changes
  focused; avoid framework migrations, new abstraction layers, or broad formatting
  passes unless the task requires them.
- Preserve unrelated working-tree changes. Do not commit generated build products,
  `.DS_Store`, or Xcode user state.
- Treat source and build configuration as authoritative for current behavior.
  `README.md` and `bloatmac/README.md` provide orientation; `docs/superpowers/` and
  the app's `*PLAN.md` files contain historical/proposed work, not standing tasks.

## Build and verification

Run these commands from the repository root. Both products require macOS for full
validation; do not assume Linux builds cover Darwin APIs or macOS behavior.

### Rust CLI / TUI

Use a current stable Rust toolchain and Xcode command-line tools. The crate uses
Rust 2021; the README's Rust 1.70 claim is not an enforced MSRV. `Cargo.lock` is
tracked: preserve it and use `--locked` unless intentionally changing dependencies.

```sh
cargo build --locked
cargo test --locked
cargo test --locked scanner::tests
cargo fmt --all -- --check
cargo clippy --locked --all-targets
cargo build --locked --release
```

Tests live in inline `#[cfg(test)]` modules under `src/`; filesystem tests use the
existing `tempfile` dependency. Add focused regression coverage alongside affected
code, using disposable files. Start with the relevant test filter, then run the
full suite for Rust behavior changes. Clippy is an additional diagnostic check,
not an existing warnings-as-errors gate. Do not reformat unrelated files to make
the repository-wide formatting check green.

For a harmless CLI smoke check, create a disposable scan root:

```sh
scan_fixture=$(mktemp -d /tmp/bloat-smoke.XXXXXX)
mkdir -p "$scan_fixture/node_modules"
printf 'fixture\n' > "$scan_fixture/node_modules/example.js"
cargo run --locked -- scan "$scan_fixture" --json
cargo run --locked -- clean --dry-run --path "$scan_fixture"
cargo run --locked -- top 5 --path "$scan_fixture"
```

### SwiftUI app

Use full Xcode with a macOS SDK supporting the checked-in **macOS 26.2** deployment
target. The project uses Swift 5 language mode with approachable concurrency and
default `MainActor` isolation; do not infer these settings from old plans.

```sh
open bloatmac/bloatmac.xcodeproj
xcodebuild -project bloatmac/bloatmac.xcodeproj \
  -scheme bloatmac -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/bloatmac-deriveddata \
  CODE_SIGNING_ALLOWED=NO build
```

The unsigned build checks compilation without requiring a signing identity.
Interactive validation uses Xcode Run (⌘R) with local signing configured. The
project currently has no automated test target and no Swift Package manifest;
`swift test` is not an app test command. For UI changes, check the affected screen
in light/dark appearances, empty/loading/error states, keyboard interaction, and
at the minimum window size (1240 × 800). For new nontrivial logic, provide a small
runnable regression check where practical; do not call a build a behavioral test.

Run `sh bloatmac/Checks/run.sh` for focused Swift regression checks against the
production cleanup, intelligence, search, and system-status helpers. Checks use
disposable temporary files and do not clean user data.

Baseline verified on 2026-09-12: 47 Rust tests passed; the unsigned Debug app build
succeeded with Xcode 26.5. `cargo fmt --all -- --check` found existing formatting
drift. These are baseline observations, not a substitute for checking new changes.

## Rust architecture and extension points

| Area | Start here |
| --- | --- |
| CLI flags, command dispatch, text/JSON output | `src/main.rs` |
| TUI state, key handling, scan lifecycle, action dispatch | `src/app.rs` |
| Filesystem tree and synchronous/background scans | `src/tree.rs`, `src/scanner.rs` |
| Rule execution and reclaimable totals | `src/analyzer.rs` |
| Cleanup contract, safety levels, registration | `src/rules/mod.rs` |
| Trash, permanent/admin deletion, results | `src/cleaner.rs` |
| Permission tiers and privileged commands | `src/permissions.rs`, `src/memory_actions.rs` |
| Live metrics, time-series history, alerts | `src/system_monitor.rs`, `src/history.rs`, `src/alerts.rs` |
| Terminal rendering | `src/ui/` |
| TOML panels, external JSON-lines plugins, Lua scripts | `src/plugins/`, `examples/` |

- CLI flow: `main.rs` → `scanner::scan` → `RuleRegistry::with_defaults` →
  `analyzer::analyze` → output or `cleaner::clean_item`. TUI scanning uses
  `scan_async`, channel progress events, and cancellation state in `app.rs`.
- **Keep the registry distinction:** `with_defaults()` contains tree-based rules
  scoped to the scan root; `with_caps()` adds direct probes of known macOS paths
  and capability-gated rules for the TUI. Probe rules can inspect locations outside
  the selected folder. Do not add them to the CLI defaults accidentally.
- Add rules to the appropriate existing `src/rules/` module, implement
  `CleanupRule`, and register them through that module's `register` function.
  Reuse `rules/probe.rs` for direct probes. Set `Safety`, `requires_admin`, and
  `required_tier` deliberately, with accurate descriptions and impact text.
- Preserve skipped-path reporting, symlink handling, progress, and cancellation
  when changing scans. Keep expensive work out of rendering and key handlers.
- Plugins are executable user configuration, not passive sample data. Their
  locations are `~/.config/bloat/plugins.toml`, `~/.config/bloat/plugins/`, and
  `~/.config/bloat/lua/`. Preserve protocol fields in `plugins/protocol.rs` and
  update affected examples when changing plugin contracts.

## SwiftUI architecture and extension points

Paths below are relative to `bloatmac/bloatmac/`.

| Area | Start here |
| --- | --- |
| App lifecycle, appearance, commands, menu-bar startup | `bloatmacApp.swift` |
| Screen enum, navigation, preferences, Full Disk Access gate | `AppState.swift` |
| Root shell, overlays, screen routing | `ContentView.swift` |
| Detection, metrics, actions | `Models/Live*.swift` |
| Screens | `Screens/Screens.swift` plus dedicated `Screens/*Screen.swift` files |
| Shared styling and controls | `Theme/DesignTokens.swift`, `Theme/Accent.swift`, `Components/` |
| Sidebar, search/title bar, native status item | `Shell/` |
| Onboarding and permission overlays | `Overlays/Overlays.swift` |
| Cleanup history | `Models/CleanupLog.swift` |

- Most feature models are `@MainActor ObservableObject` singletons with
  `@Published` state; screens observe `.shared`. Follow the affected model's
  existing lifecycle and keep filesystem/process work in the model.
- Workers commonly use `Task.detached` and `nonisolated` helpers, then publish via
  `MainActor.run`. Default actor isolation also affects types without an explicit
  annotation. Check isolation before moving code; do not suppress concurrency
  diagnostics by adding unchecked sharing. Preserve cancellation and prevent old
  scan results from overwriting a newer run.
- Timers and shared models may serve screens, Smart Care, and the menu-bar widget.
  Check all consumers before changing `start`/`stop` or scan ownership.
- For a new screen, wire `Screen`/title in `AppState.swift`, `ScreenRouter` in
  `ContentView.swift`, and navigation in `Shell/Sidebar.swift`; check Topbar search
  behavior too. Many existing screens share `Screens/Screens.swift`, so search for
  the view name instead of assuming a same-named file exists.
- Reuse `Tokens`, accent palettes, and existing controls. Preserve readable
  contrast, accessible labels, focus, and keyboard behavior.
- The Xcode source folder uses `PBXFileSystemSynchronizedRootGroup`; new Swift
  files under it normally need no manual file-reference/build-phase entries.
  Build settings, generated Info.plist keys, and signing live in
  `bloatmac/bloatmac.xcodeproj/project.pbxproj`. App Sandbox is disabled and
  hardened runtime is enabled; changing either affects real system access.
- Successful cleanup actions feed `CleanupLog.record`. It shares
  `~/Library/Application Support/BloatMac/dashboard.sqlite` with dashboard history
  through a separate connection. Preserve locking, WAL behavior, and persisted
  data when modifying storage. Preferences use UserDefaults/AppStorage keys.

## Cleanup and system-action boundaries

This software acts on real user files and processes. Development validation must
use fixtures or read-only/dry-run paths; do not run real cleanup, process killing,
cache purges, privacy wipes, uninstallers, or admin maintenance as a smoke test.

- Ordinary deletion defaults to Trash (`trash` in Rust,
  `FileManager.trashItem` in Swift). Permanent/admin actions require deliberate
  routing and user-facing intent. Never turn a failed Trash operation into an
  automatic permanent-delete fallback.
- Rust `method_for` handles admin items; `default_method` returns Trash for every
  safety level. APFS snapshots use virtual `__apfs_snapshot__/<date>` paths and
  must route to `tmutil`, never generic file deletion.
- Keep permission checks and action confirmations. Full Disk Access,
  Accessibility, and administrator authorization are distinct capabilities;
  missing access must not be presented as proof that no data exists.
- Preserve shell quoting and AppleScript escaping in privileged helpers. Prefer
  process argument arrays for ordinary subprocesses; never interpolate unchecked
  paths, identifiers, or plugin output into privileged shell commands.
- Privacy cleanup must not touch databases owned by running apps. Review the
  running-state check and SQLite journal handling when changing that path.
- Keep at least one copy during duplicate cleanup; visually similar images are
  not proof of identical content. Cloud eviction is different from deleting the
  cloud file. Preserve these distinctions in actions and UI copy.
- Report partial failures accurately. Remove/count only successful actions;
  distinguish estimated reclaimable bytes from actual free disk space—moving
  files to Trash does not itself release their storage.

## Known documentation traps and release boundaries

- `MockData.swift` remains as legacy data. Search and the recommendations badge
  use live models; do not replace live data with mock values.
- Threat hygiene is already implemented despite older roadmap text. It provides
  heuristic findings, not a signature-based antivirus guarantee.
- `LiveSchedule` runs in-process while the app is open. Its execution path scans
  and notifies; it does not automatically clean files.
  There is no persistent background helper target.
- Dashboard and Analytics let Foundation Models rank approved fact IDs; Swift
  renders the facts and numbers. Preserve deterministic fallback, generation
  ownership, and actual sample coverage. Never display unvalidated generated
  quantitative advice. Fallback does not lower the deployment target.
- Release workflows are separate: `.github/workflows/release.yml` handles CLI
  `v[0-9]*` tags; `release-bloatmac.yml` handles `bloatmac-v*` tags and produces a
  universal ad-hoc-signed, unnotarized app. `bump-homebrew-bloatmac.yml` opens a cask-update PR in the
  external tap; `Casks/bloatmac.rb` is the in-repo template. Do not cross the tag or
  artifact naming schemes when changing release tooling.

## Finishing a change

Run checks appropriate to the files and behavior changed. Report what changed,
the checks actually run, and any failures or unverified behavior. Keep this guide
current when architecture, commands, or safety contracts change; keep feature
backlogs and unrelated project TODOs elsewhere.
