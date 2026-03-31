# bloat — Disk Storage Analyzer & Cleanup TUI

**Date:** 2026-03-31
**Status:** Approved

## Overview

`bloat` is an htop-style interactive TUI for macOS that helps users visualize disk storage usage and clean up space. It combines a real-time disk explorer with smart cleanup suggestions, organized in a tabbed interface.

- **Platform:** macOS only (APFS-aware)
- **Language:** Rust
- **Architecture:** Monolithic single-binary app
- **Name:** `bloat` — accusatory, direct, no sugarcoating

## CLI Interface

```
bloat                     # launches the TUI (default)
bloat scan [path]         # scan and print summary to stdout
bloat clean --dry-run     # show what would be cleaned
bloat clean               # interactive cleanup (confirmation prompts)
bloat clean --safe        # auto-clean all SAFE items, no prompts
bloat top [n]             # print top N largest dirs (default 10)
```

**Flags:**
- `--json` — machine-readable output for all subcommands
- `--no-color` — plain text output
- `--path <dir>` — scope scan to a specific directory (default: `~`)
- `--min-size <size>` — only show items above threshold (e.g. `100MB`)

## Core Components

### Scanner

Parallel filesystem walker using `jwalk`. Builds an in-memory tree of directories with aggregated sizes. Uses `rayon` for parallel size computation. Respects macOS permissions — skips unreadable paths and reports them.

Default scan root is `~` (home directory). Disk-level stats in the Overview tab (used/free/total) come from `statvfs`, not the tree walk — so they're instant even before the scan completes.

Runs on a background thread during TUI mode, pushes progress updates via `mpsc` channel. TUI stays responsive during scan.

### Analyzer

Takes the scan tree and runs cleanup rules against it. Each rule implements a `CleanupRule` trait:

```rust
trait CleanupRule {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn impact(&self) -> &str;
    fn category(&self) -> Category; // Dev, System, App, Media
    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem>;
    fn safety(&self) -> Safety;     // Safe, Caution, Risky
}
```

- **Safe** — deletion goes to macOS Trash automatically
- **Caution** — requires confirmation prompt, then goes to Trash
- **Risky** — requires confirmation prompt, offers both Trash and permanent delete options

### Cleaner

Executes deletions using the tiered approach:

- **Safe items:** Moved to `~/.Trash` via macOS `trash` crate (wraps `NSFileManager`)
- **Caution items:** Confirmation prompt required, then moved to Trash
- **Risky items:** Confirmation prompt required, user chooses Trash or permanent deletion

User empties Trash themselves for final space reclamation.

### TUI (ratatui + crossterm)

Three-tab interface, keyboard-driven:

#### Tab 1: Overview
- Disk usage summary: used/free/total
- Color-coded segmented bar showing space by category (Apps, Dev, Docs, System, etc.)
- Top 5 space consumers list
- Quick reclaimable space summary with nudge to Cleanup tab

#### Tab 2: Explorer
- Interactive directory tree sorted by size (largest first)
- Each entry shows: expand/collapse arrow, name, size, proportional size bar
- Navigation: arrow keys to move, Enter/Right to expand, Left to collapse
- Search with `/`, sort toggle with `s` (name/size/date)
- Breadcrumb path display at top

#### Tab 3: Cleanup
- Detected cleanup items grouped by category (Developer, System, Apps, Media)
- Each item shows: checkbox, safety indicator (green/yellow/red dot + label), name, size
- Selection: Space to toggle, `a` for all, `c` for category
- `i` key shows item details (what it is, why safe to remove, what might break)
- Enter executes cleanup on selected items
- Running total of selected items and space to reclaim

**Global keybindings:**
- `1`/`2`/`3` or `Tab`: switch tabs
- `r`: rescan
- `q`: quit
- `?`: help overlay

## Cleanup Rules Catalog

### Developer
| Rule | Safety | Notes |
|------|--------|-------|
| `node_modules/` directories | Safe | Can `npm install` again |
| Xcode DerivedData | Safe | Rebuild cache |
| `cargo target/` directories | Caution | Long rebuild times |
| `.gradle/` and `build/` dirs | Safe | Rebuild cache |
| Python `__pycache__`, `.venv`, `.tox` | Safe | Regenerated/recreatable |
| CocoaPods cache | Safe | Redownloads on install |
| `.build/` (Swift PM) | Safe | Rebuild cache |

### System
| Rule | Safety | Notes |
|------|--------|-------|
| `~/Library/Caches/*` | Safe | macOS regenerates |
| System logs older than 30 days | Safe | Historical only |
| `~/.Trash` contents | Safe | Already "deleted" |
| Old iOS device backups | Caution | Irreplaceable if not in iCloud |
| Time Machine local snapshots | Caution | May lose restore points |

### Applications
| Rule | Safety | Notes |
|------|--------|-------|
| Browser caches (Chrome, Safari, Firefox, Arc) | Safe | Redownloads on browse |
| Slack/Discord/Teams cache | Safe | Redownloads on launch |
| Spotify offline cache | Safe | Redownloads songs |
| Docker images/volumes/build cache | Caution | May need repull |
| Homebrew cache (`brew cleanup`) | Safe | Redownloads on install |
| npm/pip/cargo global cache | Caution | Slower next install |

### Media
| Rule | Safety | Notes |
|------|--------|-------|
| Duplicate files (by hash) | Caution | User picks which to keep |
| Large files (>1GB) not accessed in 90+ days | Informational | Flagged, not auto-suggested |

## Technical Stack

### Crates
- `ratatui` + `crossterm` — TUI rendering and terminal input
- `jwalk` — parallel filesystem walking
- `clap` — CLI argument parsing with derive macros
- `serde` / `serde_json` — JSON output mode
- `trash` crate — macOS Trash integration
- `blake3` — fast hashing for duplicate file detection

### Async Model
- Scanner runs on a background thread, sends progress via `std::sync::mpsc`
- TUI event loop polls for both terminal input and scanner messages
- Scan results cached in memory; `r` key triggers rescan
- Cleanup rule matching runs after scan completes, results appear incrementally

### Performance Targets
- Full home directory scan: under 10 seconds on SSD
- TUI rendering: 30fps minimum, never blocks on I/O
- Memory: tree structure should handle millions of entries without excessive RAM

## Project Structure

```
src/
  main.rs           — entry point, clap CLI parsing
  app.rs            — app state, tab management, event loop
  scanner.rs        — parallel filesystem walker
  analyzer.rs       — runs cleanup rules against scan tree
  cleaner.rs        — deletion engine (trash / permanent)
  tree.rs           — in-memory filesystem tree data structure
  ui/
    mod.rs          — shared rendering helpers
    overview.rs     — Tab 1 renderer
    explorer.rs     — Tab 2 renderer
    cleanup.rs      — Tab 3 renderer
  rules/
    mod.rs          — CleanupRule trait + registry
    dev.rs          — developer tool rules
    system.rs       — system cache/log rules
    apps.rs         — application cache rules
    media.rs        — duplicate/large file rules
```
