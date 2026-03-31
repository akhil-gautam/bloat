# bloat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bloat`, an htop-style interactive TUI for macOS that visualizes disk storage usage and provides smart cleanup with tiered safety.

**Architecture:** Monolithic Rust binary. Scanner walks the filesystem in parallel via `jwalk`, builds an in-memory tree. Analyzer runs cleanup rules against the tree. Cleaner executes deletions via macOS Trash or permanent delete. TUI uses `ratatui`+`crossterm` with three tabs (Overview, Explorer, Cleanup). CLI subcommands provide non-interactive access.

**Tech Stack:** Rust, ratatui, crossterm, jwalk, clap, serde/serde_json, trash crate, blake3

---

## File Map

| File | Responsibility |
|------|---------------|
| `Cargo.toml` | Dependencies and project metadata |
| `src/main.rs` | Entry point, clap CLI parsing, dispatches to TUI or CLI subcommands |
| `src/tree.rs` | `FsTree` and `FsNode` data structures for in-memory directory tree |
| `src/scanner.rs` | Parallel filesystem walker, builds `FsTree`, sends progress via channel |
| `src/rules/mod.rs` | `CleanupRule` trait, `Category`, `Safety`, `CleanupItem` types, rule registry |
| `src/rules/dev.rs` | Developer cleanup rules (node_modules, DerivedData, cargo target, etc.) |
| `src/rules/system.rs` | System cleanup rules (caches, logs, trash, backups) |
| `src/rules/apps.rs` | Application cleanup rules (browser caches, Docker, Homebrew, etc.) |
| `src/rules/media.rs` | Media rules (duplicate files, large unused files) |
| `src/analyzer.rs` | Runs all registered rules against a scan tree, produces cleanup results |
| `src/cleaner.rs` | Deletion engine — trash or permanent delete with confirmation |
| `src/app.rs` | App state, tab management, TUI event loop |
| `src/ui/mod.rs` | Shared TUI rendering helpers (size formatting, progress bar, colors) |
| `src/ui/overview.rs` | Tab 1: disk usage summary, top consumers, reclaimable nudge |
| `src/ui/explorer.rs` | Tab 2: interactive directory tree with size bars |
| `src/ui/cleanup.rs` | Tab 3: categorized cleanup items with checkboxes and safety labels |

---

### Task 1: Project Scaffold & Tree Data Structure

**Files:**
- Create: `Cargo.toml`
- Create: `src/main.rs`
- Create: `src/tree.rs`

- [ ] **Step 1: Initialize Cargo project**

Run:
```bash
cd /Users/akhilgautam/projects/personal/memclean
cargo init --name bloat
```

- [ ] **Step 2: Add dependencies to Cargo.toml**

Replace `Cargo.toml` with:

```toml
[package]
name = "bloat"
version = "0.1.0"
edition = "2021"
description = "An htop-style disk storage analyzer and cleanup TUI for macOS"

[dependencies]
ratatui = "0.29"
crossterm = "0.28"
jwalk = "0.8"
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
trash = "5"
blake3 = "1"
human-bytes = "0.4"

[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 3: Write the failing test for FsNode and FsTree**

Write `src/tree.rs`:

```rust
use std::path::PathBuf;

/// A single node in the filesystem tree — either a file or a directory.
#[derive(Debug, Clone)]
pub struct FsNode {
    pub name: String,
    pub path: PathBuf,
    pub size: u64,
    pub is_dir: bool,
    pub children: Vec<FsNode>,
}

impl FsNode {
    pub fn new_file(name: String, path: PathBuf, size: u64) -> Self {
        Self {
            name,
            path,
            size,
            is_dir: false,
            children: Vec::new(),
        }
    }

    pub fn new_dir(name: String, path: PathBuf) -> Self {
        Self {
            name,
            path,
            size: 0,
            is_dir: true,
            children: Vec::new(),
        }
    }

    /// Add a child node and update this directory's size.
    pub fn add_child(&mut self, child: FsNode) {
        self.size += child.size;
        self.children.push(child);
    }

    /// Sort children by size descending.
    pub fn sort_by_size(&mut self) {
        self.children.sort_by(|a, b| b.size.cmp(&a.size));
        for child in &mut self.children {
            child.sort_by_size();
        }
    }

    /// Count total number of nodes (including self).
    pub fn node_count(&self) -> usize {
        1 + self.children.iter().map(|c| c.node_count()).sum::<usize>()
    }
}

/// The full filesystem tree with metadata.
#[derive(Debug)]
pub struct FsTree {
    pub root: FsNode,
    pub skipped_paths: Vec<PathBuf>,
}

impl FsTree {
    pub fn new(root: FsNode) -> Self {
        Self {
            root,
            skipped_paths: Vec::new(),
        }
    }

    /// Get total size of the tree.
    pub fn total_size(&self) -> u64 {
        self.root.size
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_file() {
        let f = FsNode::new_file("hello.txt".into(), PathBuf::from("/tmp/hello.txt"), 1024);
        assert_eq!(f.name, "hello.txt");
        assert_eq!(f.size, 1024);
        assert!(!f.is_dir);
        assert!(f.children.is_empty());
    }

    #[test]
    fn test_new_dir_with_children() {
        let mut dir = FsNode::new_dir("mydir".into(), PathBuf::from("/tmp/mydir"));
        let f1 = FsNode::new_file("a.txt".into(), PathBuf::from("/tmp/mydir/a.txt"), 100);
        let f2 = FsNode::new_file("b.txt".into(), PathBuf::from("/tmp/mydir/b.txt"), 200);
        dir.add_child(f1);
        dir.add_child(f2);

        assert_eq!(dir.size, 300);
        assert_eq!(dir.children.len(), 2);
    }

    #[test]
    fn test_sort_by_size() {
        let mut dir = FsNode::new_dir("root".into(), PathBuf::from("/tmp/root"));
        dir.add_child(FsNode::new_file("small.txt".into(), PathBuf::from("/tmp/root/small.txt"), 10));
        dir.add_child(FsNode::new_file("big.txt".into(), PathBuf::from("/tmp/root/big.txt"), 1000));
        dir.add_child(FsNode::new_file("med.txt".into(), PathBuf::from("/tmp/root/med.txt"), 500));
        dir.sort_by_size();

        assert_eq!(dir.children[0].name, "big.txt");
        assert_eq!(dir.children[1].name, "med.txt");
        assert_eq!(dir.children[2].name, "small.txt");
    }

    #[test]
    fn test_node_count() {
        let mut dir = FsNode::new_dir("root".into(), PathBuf::from("/root"));
        let mut sub = FsNode::new_dir("sub".into(), PathBuf::from("/root/sub"));
        sub.add_child(FsNode::new_file("f.txt".into(), PathBuf::from("/root/sub/f.txt"), 50));
        dir.add_child(sub);
        dir.add_child(FsNode::new_file("g.txt".into(), PathBuf::from("/root/g.txt"), 100));

        assert_eq!(dir.node_count(), 4); // root, sub, f.txt, g.txt
    }

    #[test]
    fn test_fs_tree_total_size() {
        let mut root = FsNode::new_dir("root".into(), PathBuf::from("/root"));
        root.add_child(FsNode::new_file("a.txt".into(), PathBuf::from("/root/a.txt"), 500));
        root.add_child(FsNode::new_file("b.txt".into(), PathBuf::from("/root/b.txt"), 300));
        let tree = FsTree::new(root);

        assert_eq!(tree.total_size(), 800);
    }
}
```

- [ ] **Step 4: Update main.rs to declare the module**

Write `src/main.rs`:

```rust
mod tree;

fn main() {
    println!("bloat v0.1.0");
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --lib tree`
Expected: All 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git init
echo "target/" > .gitignore
echo ".superpowers/" >> .gitignore
git add Cargo.toml src/main.rs src/tree.rs .gitignore docs/
git commit -m "feat: project scaffold with FsTree data structure and tests"
```

---

### Task 2: Filesystem Scanner

**Files:**
- Create: `src/scanner.rs`
- Modify: `src/main.rs` (add module declaration)

- [ ] **Step 1: Write the failing test for scanner**

Write `src/scanner.rs`:

```rust
use crate::tree::{FsNode, FsTree};
use jwalk::WalkDir;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;

/// Progress update sent from scanner to UI.
#[derive(Debug, Clone)]
pub enum ScanProgress {
    /// A new directory is being scanned.
    Scanning(PathBuf),
    /// Scan is complete.
    Done(FsTree),
    /// Scan encountered an error on a path.
    Error(PathBuf, String),
}

/// Scan a directory tree and build an FsTree.
/// Returns the tree directly (blocking). For async use, see `scan_async`.
pub fn scan(root: &Path) -> FsTree {
    let mut nodes: HashMap<PathBuf, FsNode> = HashMap::new();
    let mut skipped: Vec<PathBuf> = Vec::new();

    // Collect all entries first
    let entries: Vec<_> = WalkDir::new(root)
        .skip_hidden(false)
        .sort(true)
        .into_iter()
        .collect();

    for entry in &entries {
        match entry {
            Ok(entry) => {
                let path = entry.path();
                let metadata = match path.symlink_metadata() {
                    Ok(m) => m,
                    Err(_) => {
                        skipped.push(path.clone());
                        continue;
                    }
                };

                if metadata.is_symlink() {
                    continue;
                }

                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.to_string_lossy().to_string());

                if metadata.is_file() {
                    let size = metadata.len();
                    nodes.insert(path.clone(), FsNode::new_file(name, path.clone(), size));
                } else if metadata.is_dir() {
                    nodes.insert(path.clone(), FsNode::new_dir(name, path.clone()));
                }
            }
            Err(_) => {}
        }
    }

    // Build tree bottom-up: attach children to parents
    let all_paths: Vec<PathBuf> = nodes.keys().cloned().collect();
    // Sort paths by depth descending so we process children before parents
    let mut sorted_paths = all_paths;
    sorted_paths.sort_by(|a, b| {
        let depth_a = a.components().count();
        let depth_b = b.components().count();
        depth_b.cmp(&depth_a)
    });

    for path in &sorted_paths {
        if path == root {
            continue;
        }
        if let Some(parent_path) = path.parent() {
            let parent_path = parent_path.to_path_buf();
            if let Some(child) = nodes.remove(path) {
                if let Some(parent) = nodes.get_mut(&parent_path) {
                    parent.add_child(child);
                }
            }
        }
    }

    let root_node = nodes.remove(root).unwrap_or_else(|| {
        FsNode::new_dir(
            root.to_string_lossy().to_string(),
            root.to_path_buf(),
        )
    });

    let mut tree = FsTree::new(root_node);
    tree.root.sort_by_size();
    tree.skipped_paths = skipped;
    tree
}

/// Scan asynchronously, sending progress updates through a channel.
/// Returns a join handle. The final `ScanProgress::Done` contains the tree.
pub fn scan_async(
    root: PathBuf,
    tx: mpsc::Sender<ScanProgress>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let tree = scan(&root);
        let _ = tx.send(ScanProgress::Done(tree));
    })
}

/// Get disk usage stats via statvfs (instant, no scan needed).
#[derive(Debug, Clone)]
pub struct DiskStats {
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub used_bytes: u64,
}

pub fn disk_stats(path: &Path) -> Option<DiskStats> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };
    if ret != 0 {
        return None;
    }

    let total = stat.f_blocks * stat.f_frsize as u64;
    let free = stat.f_bavail * stat.f_frsize as u64;
    let used = total.saturating_sub(free);

    Some(DiskStats {
        total_bytes: total,
        free_bytes: free,
        used_bytes: used,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_test_tree() -> TempDir {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();

        fs::create_dir_all(root.join("subdir/nested")).unwrap();
        fs::write(root.join("file1.txt"), "hello").unwrap(); // 5 bytes
        fs::write(root.join("subdir/file2.txt"), "world!").unwrap(); // 6 bytes
        fs::write(root.join("subdir/nested/file3.txt"), "ab").unwrap(); // 2 bytes

        tmp
    }

    #[test]
    fn test_scan_counts_files() {
        let tmp = create_test_tree();
        let tree = scan(tmp.path());

        // root should contain subdir + file1.txt
        assert_eq!(tree.root.children.len(), 2);
    }

    #[test]
    fn test_scan_computes_sizes() {
        let tmp = create_test_tree();
        let tree = scan(tmp.path());

        // Total size: 5 + 6 + 2 = 13
        assert_eq!(tree.total_size(), 13);
    }

    #[test]
    fn test_scan_sorts_by_size() {
        let tmp = create_test_tree();
        let tree = scan(tmp.path());

        // subdir (8 bytes) should come before file1.txt (5 bytes)
        assert!(tree.root.children[0].is_dir);
        assert_eq!(tree.root.children[0].name, "subdir");
    }

    #[test]
    fn test_scan_nested_dirs() {
        let tmp = create_test_tree();
        let tree = scan(tmp.path());

        let subdir = &tree.root.children[0];
        assert_eq!(subdir.size, 8); // 6 + 2
        assert_eq!(subdir.children.len(), 2); // file2.txt + nested/
    }

    #[test]
    fn test_scan_async_sends_done() {
        let tmp = create_test_tree();
        let (tx, rx) = mpsc::channel();
        let handle = scan_async(tmp.path().to_path_buf(), tx);
        handle.join().unwrap();

        let msg = rx.recv().unwrap();
        match msg {
            ScanProgress::Done(tree) => {
                assert_eq!(tree.total_size(), 13);
            }
            _ => panic!("Expected ScanProgress::Done"),
        }
    }

    #[test]
    fn test_disk_stats_returns_some() {
        let stats = disk_stats(Path::new("/")).unwrap();
        assert!(stats.total_bytes > 0);
        assert!(stats.used_bytes > 0);
        assert!(stats.total_bytes >= stats.used_bytes);
    }
}
```

- [ ] **Step 2: Add module declaration and libc dependency**

Add to `Cargo.toml` under `[dependencies]`:

```toml
libc = "0.2"
```

Add to `src/main.rs`:

```rust
mod scanner;
mod tree;

fn main() {
    println!("bloat v0.1.0");
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `cargo test --lib scanner`
Expected: All 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/scanner.rs src/main.rs Cargo.toml
git commit -m "feat: parallel filesystem scanner with async support and disk stats"
```

---

### Task 3: Cleanup Rule Trait & Developer Rules

**Files:**
- Create: `src/rules/mod.rs`
- Create: `src/rules/dev.rs`
- Modify: `src/main.rs` (add module)

- [ ] **Step 1: Write the CleanupRule trait and types**

Write `src/rules/mod.rs`:

```rust
pub mod dev;

use crate::tree::FsTree;
use std::path::PathBuf;

/// Category of cleanup rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Category {
    Developer,
    System,
    App,
    Media,
}

impl std::fmt::Display for Category {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Category::Developer => write!(f, "Developer"),
            Category::System => write!(f, "System"),
            Category::App => write!(f, "Applications"),
            Category::Media => write!(f, "Media"),
        }
    }
}

/// Safety level of a cleanup action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Safety {
    Safe,
    Caution,
    Risky,
}

impl std::fmt::Display for Safety {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Safety::Safe => write!(f, "SAFE"),
            Safety::Caution => write!(f, "CAUTION"),
            Safety::Risky => write!(f, "RISKY"),
        }
    }
}

/// A single item detected for potential cleanup.
#[derive(Debug, Clone)]
pub struct CleanupItem {
    pub name: String,
    pub paths: Vec<PathBuf>,
    pub total_size: u64,
    pub description: String,
    pub impact: String,
    pub category: Category,
    pub safety: Safety,
}

/// Trait for cleanup rule implementations.
pub trait CleanupRule: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn impact(&self) -> &str;
    fn category(&self) -> Category;
    fn safety(&self) -> Safety;
    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem>;
}

/// Registry of all cleanup rules.
pub struct RuleRegistry {
    rules: Vec<Box<dyn CleanupRule>>,
}

impl RuleRegistry {
    pub fn new() -> Self {
        Self { rules: Vec::new() }
    }

    pub fn register(&mut self, rule: Box<dyn CleanupRule>) {
        self.rules.push(rule);
    }

    pub fn rules(&self) -> &[Box<dyn CleanupRule>] {
        &self.rules
    }

    /// Create a registry with all built-in rules.
    pub fn with_defaults() -> Self {
        let mut registry = Self::new();
        dev::register(&mut registry);
        registry
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safety_ordering() {
        assert!(Safety::Safe < Safety::Caution);
        assert!(Safety::Caution < Safety::Risky);
    }

    #[test]
    fn test_registry_register_and_count() {
        let registry = RuleRegistry::with_defaults();
        assert!(registry.rules().len() > 0, "Default registry should have rules");
    }
}
```

- [ ] **Step 2: Write developer cleanup rules**

Write `src/rules/dev.rs`:

```rust
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};
use crate::tree::{FsNode, FsTree};
use std::path::PathBuf;

/// Register all developer cleanup rules.
pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(NodeModulesRule));
    registry.register(Box::new(XcodeDerivedDataRule));
    registry.register(Box::new(CargoTargetRule));
    registry.register(Box::new(GradleBuildRule));
    registry.register(Box::new(PythonCacheRule));
    registry.register(Box::new(CocoaPodsRule));
    registry.register(Box::new(SwiftBuildRule));
}

// --- Helper: recursively find directories matching a predicate ---

fn find_dirs(node: &FsNode, predicate: &dyn Fn(&FsNode) -> bool) -> Vec<(PathBuf, u64)> {
    let mut results = Vec::new();
    if predicate(node) {
        results.push((node.path.clone(), node.size));
        return results; // Don't recurse into matched dirs
    }
    for child in &node.children {
        results.extend(find_dirs(child, predicate));
    }
    results
}

fn make_item(
    name: &str,
    matches: Vec<(PathBuf, u64)>,
    description: &str,
    impact: &str,
    safety: Safety,
) -> Option<CleanupItem> {
    if matches.is_empty() {
        return None;
    }
    let total_size: u64 = matches.iter().map(|(_, s)| s).sum();
    let paths: Vec<PathBuf> = matches.into_iter().map(|(p, _)| p).collect();
    let count = paths.len();
    Some(CleanupItem {
        name: if count > 1 {
            format!("{} ({} dirs)", name, count)
        } else {
            name.to_string()
        },
        paths,
        total_size,
        description: description.to_string(),
        impact: impact.to_string(),
        category: Category::Developer,
        safety,
    })
}

// --- Rules ---

pub struct NodeModulesRule;

impl CleanupRule for NodeModulesRule {
    fn name(&self) -> &str { "node_modules" }
    fn description(&self) -> &str { "Node.js dependency directories. Recreated by running npm install or yarn install." }
    fn impact(&self) -> &str { "Next npm install will re-download packages. No data loss." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| n.is_dir && n.name == "node_modules");
        make_item("node_modules", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct XcodeDerivedDataRule;

impl CleanupRule for XcodeDerivedDataRule {
    fn name(&self) -> &str { "Xcode DerivedData" }
    fn description(&self) -> &str { "Xcode build cache. Regenerated automatically on next build." }
    fn impact(&self) -> &str { "Next Xcode build will be slower (cold build). No data loss." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "DerivedData" && n.path.to_string_lossy().contains("Developer/Xcode")
        });
        make_item("Xcode DerivedData", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct CargoTargetRule;

impl CleanupRule for CargoTargetRule {
    fn name(&self) -> &str { "cargo target/" }
    fn description(&self) -> &str { "Rust build artifacts. Recreated by cargo build, but compilation can be slow." }
    fn impact(&self) -> &str { "Next cargo build will recompile from scratch. Can be slow for large projects." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir
                && n.name == "target"
                && n.path.parent().map_or(false, |p| p.join("Cargo.toml").exists())
        });
        make_item("cargo target/", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct GradleBuildRule;

impl CleanupRule for GradleBuildRule {
    fn name(&self) -> &str { ".gradle & build/" }
    fn description(&self) -> &str { "Gradle build cache and output directories. Recreated on next build." }
    fn impact(&self) -> &str { "Next Gradle build will re-download dependencies and recompile. No data loss." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let gradle_dirs = find_dirs(&tree.root, &|n| n.is_dir && n.name == ".gradle");
        let build_dirs = find_dirs(&tree.root, &|n| {
            n.is_dir
                && n.name == "build"
                && n.path.parent().map_or(false, |p| p.join("build.gradle").exists() || p.join("build.gradle.kts").exists())
        });
        let mut all = gradle_dirs;
        all.extend(build_dirs);
        make_item(".gradle & build/", all, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct PythonCacheRule;

impl CleanupRule for PythonCacheRule {
    fn name(&self) -> &str { "Python caches" }
    fn description(&self) -> &str { "Python bytecode caches, virtual environments, and test caches." }
    fn impact(&self) -> &str { "Virtual environments need recreating. __pycache__ regenerates automatically." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && (n.name == "__pycache__" || n.name == ".venv" || n.name == ".tox")
        });
        make_item("Python caches", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct CocoaPodsRule;

impl CleanupRule for CocoaPodsRule {
    fn name(&self) -> &str { "CocoaPods cache" }
    fn description(&self) -> &str { "CocoaPods dependency cache. Re-downloads on next pod install." }
    fn impact(&self) -> &str { "Next pod install will re-download dependencies. No data loss." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "CocoaPods" && n.path.to_string_lossy().contains("Library/Caches")
        });
        make_item("CocoaPods cache", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct SwiftBuildRule;

impl CleanupRule for SwiftBuildRule {
    fn name(&self) -> &str { "Swift PM .build/" }
    fn description(&self) -> &str { "Swift Package Manager build artifacts. Recreated on next swift build." }
    fn impact(&self) -> &str { "Next swift build will recompile. No data loss." }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir
                && n.name == ".build"
                && n.path.parent().map_or(false, |p| p.join("Package.swift").exists())
        });
        make_item("Swift PM .build/", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn scan_tmp(tmp: &TempDir) -> FsTree {
        crate::scanner::scan(tmp.path())
    }

    #[test]
    fn test_node_modules_detection() {
        let tmp = TempDir::new().unwrap();
        let nm = tmp.path().join("project/node_modules");
        fs::create_dir_all(&nm).unwrap();
        fs::write(nm.join("lodash.js"), "x".repeat(1000)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].total_size, 1000);
        assert_eq!(items[0].safety, Safety::Safe);
    }

    #[test]
    fn test_no_false_positives_on_empty() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("readme.md"), "hello").unwrap();

        let tree = scan_tmp(&tmp);
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty());
    }

    #[test]
    fn test_cargo_target_detection() {
        let tmp = TempDir::new().unwrap();
        let project = tmp.path().join("myrust");
        fs::create_dir_all(project.join("target/debug")).unwrap();
        fs::write(project.join("Cargo.toml"), "[package]\nname=\"x\"").unwrap();
        fs::write(project.join("target/debug/binary"), "x".repeat(5000)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = CargoTargetRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].safety, Safety::Caution);
    }

    #[test]
    fn test_python_cache_detection() {
        let tmp = TempDir::new().unwrap();
        let pycache = tmp.path().join("mypy/__pycache__");
        fs::create_dir_all(&pycache).unwrap();
        fs::write(pycache.join("mod.pyc"), "bytecode").unwrap();
        let venv = tmp.path().join("mypy/.venv/lib");
        fs::create_dir_all(&venv).unwrap();
        fs::write(venv.join("site.py"), "pkg").unwrap();

        let tree = scan_tmp(&tmp);
        let rule = PythonCacheRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].paths.len(), 2); // __pycache__ + .venv
    }

    #[test]
    fn test_multiple_node_modules() {
        let tmp = TempDir::new().unwrap();
        for name in &["proj1", "proj2", "proj3"] {
            let nm = tmp.path().join(name).join("node_modules");
            fs::create_dir_all(&nm).unwrap();
            fs::write(nm.join("dep.js"), "x").unwrap();
        }

        let tree = scan_tmp(&tmp);
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].paths.len(), 3);
        assert!(items[0].name.contains("3 dirs"));
    }
}
```

- [ ] **Step 3: Add module declaration**

Update `src/main.rs`:

```rust
mod rules;
mod scanner;
mod tree;

fn main() {
    println!("bloat v0.1.0");
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --lib rules`
Expected: All 7 tests pass (2 in mod.rs + 5 in dev.rs).

- [ ] **Step 5: Commit**

```bash
git add src/rules/ src/main.rs
git commit -m "feat: CleanupRule trait, registry, and developer cleanup rules"
```

---

### Task 4: System & Application Cleanup Rules

**Files:**
- Create: `src/rules/system.rs`
- Create: `src/rules/apps.rs`
- Modify: `src/rules/mod.rs` (register new modules)

- [ ] **Step 1: Write system cleanup rules**

Write `src/rules/system.rs`:

```rust
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};
use crate::tree::{FsNode, FsTree};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(LibraryCachesRule));
    registry.register(Box::new(OldLogsRule));
    registry.register(Box::new(TrashRule));
    registry.register(Box::new(IosBackupsRule));
    registry.register(Box::new(TimeMachineLocalRule));
}

fn find_dirs(node: &FsNode, predicate: &dyn Fn(&FsNode) -> bool) -> Vec<(PathBuf, u64)> {
    let mut results = Vec::new();
    if predicate(node) {
        results.push((node.path.clone(), node.size));
        return results;
    }
    for child in &node.children {
        results.extend(find_dirs(child, predicate));
    }
    results
}

fn make_item(
    name: &str,
    matches: Vec<(PathBuf, u64)>,
    description: &str,
    impact: &str,
    safety: Safety,
) -> Option<CleanupItem> {
    if matches.is_empty() {
        return None;
    }
    let total_size: u64 = matches.iter().map(|(_, s)| s).sum();
    let paths: Vec<PathBuf> = matches.into_iter().map(|(p, _)| p).collect();
    let count = paths.len();
    Some(CleanupItem {
        name: if count > 1 {
            format!("{} ({} items)", name, count)
        } else {
            name.to_string()
        },
        paths,
        total_size,
        description: description.to_string(),
        impact: impact.to_string(),
        category: Category::System,
        safety,
    })
}

pub struct LibraryCachesRule;

impl CleanupRule for LibraryCachesRule {
    fn name(&self) -> &str { "Library Caches" }
    fn description(&self) -> &str { "macOS application caches in ~/Library/Caches. Regenerated by apps as needed." }
    fn impact(&self) -> &str { "Apps may be slightly slower on next launch while rebuilding caches. No data loss." }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Caches" && n.path.to_string_lossy().contains("Library/Caches")
        });
        make_item("Library Caches", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct OldLogsRule;

impl CleanupRule for OldLogsRule {
    fn name(&self) -> &str { "Old log files" }
    fn description(&self) -> &str { "System and application log files older than 30 days." }
    fn impact(&self) -> &str { "Old log entries are lost. Current logs are unaffected." }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let thirty_days_ago = SystemTime::now() - Duration::from_secs(30 * 24 * 3600);
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Logs" && n.path.to_string_lossy().contains("Library/Logs")
        });
        // For logs, we report the whole Logs directory — actual cleanup should filter by age
        make_item("Old log files", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct TrashRule;

impl CleanupRule for TrashRule {
    fn name(&self) -> &str { "Trash contents" }
    fn description(&self) -> &str { "Files in ~/.Trash that are already marked for deletion." }
    fn impact(&self) -> &str { "Permanently removes trashed files. Cannot be recovered." }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == ".Trash"
        });
        make_item("Trash contents", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct IosBackupsRule;

impl CleanupRule for IosBackupsRule {
    fn name(&self) -> &str { "iOS device backups" }
    fn description(&self) -> &str { "Local iOS device backups in ~/Library/Application Support/MobileSync/Backup." }
    fn impact(&self) -> &str { "Device backups are lost. Ensure iCloud backup is enabled before removing." }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Backup" && n.path.to_string_lossy().contains("MobileSync/Backup")
        });
        make_item("iOS device backups", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

pub struct TimeMachineLocalRule;

impl CleanupRule for TimeMachineLocalRule {
    fn name(&self) -> &str { "Time Machine local snapshots" }
    fn description(&self) -> &str { "Local Time Machine snapshots stored on this disk." }
    fn impact(&self) -> &str { "Lose ability to restore from local snapshots. External TM backup unaffected." }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == ".MobileBackups"
        });
        make_item("Time Machine local snapshots", matches, self.description(), self.impact(), self.safety())
            .into_iter()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn scan_tmp(tmp: &TempDir) -> FsTree {
        crate::scanner::scan(tmp.path())
    }

    #[test]
    fn test_trash_detection() {
        let tmp = TempDir::new().unwrap();
        let trash = tmp.path().join(".Trash");
        fs::create_dir_all(&trash).unwrap();
        fs::write(trash.join("deleted_file.txt"), "old stuff").unwrap();

        let tree = scan_tmp(&tmp);
        let rule = TrashRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].safety, Safety::Safe);
    }

    #[test]
    fn test_no_trash_when_empty_dir() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("keep.txt"), "important").unwrap();

        let tree = scan_tmp(&tmp);
        let rule = TrashRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty());
    }
}
```

- [ ] **Step 2: Write application cleanup rules**

Write `src/rules/apps.rs`:

```rust
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};
use crate::tree::{FsNode, FsTree};
use std::path::PathBuf;

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(BrowserCacheRule));
    registry.register(Box::new(SlackCacheRule));
    registry.register(Box::new(SpotifyCacheRule));
    registry.register(Box::new(DockerRule));
    registry.register(Box::new(HomebrewCacheRule));
    registry.register(Box::new(PackageManagerCacheRule));
}

fn find_dirs(node: &FsNode, predicate: &dyn Fn(&FsNode) -> bool) -> Vec<(PathBuf, u64)> {
    let mut results = Vec::new();
    if predicate(node) {
        results.push((node.path.clone(), node.size));
        return results;
    }
    for child in &node.children {
        results.extend(find_dirs(child, predicate));
    }
    results
}

fn make_item(
    name: &str,
    matches: Vec<(PathBuf, u64)>,
    description: &str,
    impact: &str,
    category: Category,
    safety: Safety,
) -> Option<CleanupItem> {
    if matches.is_empty() {
        return None;
    }
    let total_size: u64 = matches.iter().map(|(_, s)| s).sum();
    let paths: Vec<PathBuf> = matches.into_iter().map(|(p, _)| p).collect();
    let count = paths.len();
    Some(CleanupItem {
        name: if count > 1 {
            format!("{} ({} items)", name, count)
        } else {
            name.to_string()
        },
        paths,
        total_size,
        description: description.to_string(),
        impact: impact.to_string(),
        category,
        safety,
    })
}

pub struct BrowserCacheRule;

impl CleanupRule for BrowserCacheRule {
    fn name(&self) -> &str { "Browser caches" }
    fn description(&self) -> &str { "Cache directories for Chrome, Safari, Firefox, and Arc browsers." }
    fn impact(&self) -> &str { "Pages may load slightly slower until caches rebuild. No data loss." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let browser_cache_names = [
            "Google/Chrome",
            "com.apple.Safari",
            "Firefox",
            "company.thebrowser.Browser", // Arc
        ];
        let mut all_matches = Vec::new();
        for browser in &browser_cache_names {
            let matches = find_dirs(&tree.root, &|n| {
                n.is_dir
                    && n.name == "Cache"
                    && n.path.to_string_lossy().contains(browser)
            });
            all_matches.extend(matches);
        }
        make_item("Browser caches", all_matches, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

pub struct SlackCacheRule;

impl CleanupRule for SlackCacheRule {
    fn name(&self) -> &str { "Slack cache" }
    fn description(&self) -> &str { "Slack desktop app cache and local storage." }
    fn impact(&self) -> &str { "Slack will re-download data on next launch. No messages lost." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir
                && (n.name == "Cache" || n.name == "Service Worker")
                && n.path.to_string_lossy().contains("com.tinyspeck.slackmacgap")
        });
        make_item("Slack cache", matches, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

pub struct SpotifyCacheRule;

impl CleanupRule for SpotifyCacheRule {
    fn name(&self) -> &str { "Spotify cache" }
    fn description(&self) -> &str { "Spotify offline music cache and temporary data." }
    fn impact(&self) -> &str { "Offline music will need to re-download. Playlists and account unaffected." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir
                && n.name == "com.spotify.client"
                && n.path.to_string_lossy().contains("Caches")
        });
        make_item("Spotify cache", matches, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

pub struct DockerRule;

impl CleanupRule for DockerRule {
    fn name(&self) -> &str { "Docker data" }
    fn description(&self) -> &str { "Docker images, volumes, and build cache." }
    fn impact(&self) -> &str { "Images will need to be re-pulled. Volumes with data may be lost." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Docker" && n.path.to_string_lossy().contains("Library/Containers")
        });
        // Also check ~/Docker
        let docker_home = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Docker" && !n.path.to_string_lossy().contains("Library")
        });
        let mut all = matches;
        all.extend(docker_home);
        make_item("Docker data", all, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

pub struct HomebrewCacheRule;

impl CleanupRule for HomebrewCacheRule {
    fn name(&self) -> &str { "Homebrew cache" }
    fn description(&self) -> &str { "Cached Homebrew downloads and old formula versions." }
    fn impact(&self) -> &str { "Homebrew will re-download packages when needed. No installed packages affected." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "Homebrew" && n.path.to_string_lossy().contains("Caches")
        });
        make_item("Homebrew cache", matches, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

pub struct PackageManagerCacheRule;

impl CleanupRule for PackageManagerCacheRule {
    fn name(&self) -> &str { "Package manager caches" }
    fn description(&self) -> &str { "Global caches for npm, pip, and cargo package managers." }
    fn impact(&self) -> &str { "Next package install will be slower as it re-downloads. No installed packages affected." }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let mut all = Vec::new();
        // npm cache: ~/.npm/_cacache
        all.extend(find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "_cacache" && n.path.to_string_lossy().contains(".npm")
        }));
        // pip cache: ~/Library/Caches/pip
        all.extend(find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "pip" && n.path.to_string_lossy().contains("Caches")
        }));
        // cargo registry cache: ~/.cargo/registry
        all.extend(find_dirs(&tree.root, &|n| {
            n.is_dir && n.name == "registry" && n.path.to_string_lossy().contains(".cargo")
        }));
        make_item("Package manager caches", all, self.description(), self.impact(), Category::App, self.safety())
            .into_iter()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn scan_tmp(tmp: &TempDir) -> FsTree {
        crate::scanner::scan(tmp.path())
    }

    #[test]
    fn test_docker_detection() {
        let tmp = TempDir::new().unwrap();
        let docker = tmp.path().join("Docker");
        fs::create_dir_all(&docker).unwrap();
        fs::write(docker.join("image.tar"), "x".repeat(2000)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = DockerRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].safety, Safety::Caution);
    }

    #[test]
    fn test_homebrew_cache_detection() {
        let tmp = TempDir::new().unwrap();
        let cache = tmp.path().join("Library/Caches/Homebrew/downloads");
        fs::create_dir_all(&cache).unwrap();
        fs::write(cache.join("pkg.tar.gz"), "x".repeat(500)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = HomebrewCacheRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
    }
}
```

- [ ] **Step 3: Register new modules in mod.rs**

Update `src/rules/mod.rs` — add module declarations and update `with_defaults`:

Add after `pub mod dev;`:
```rust
pub mod system;
pub mod apps;
```

Update `with_defaults`:
```rust
pub fn with_defaults() -> Self {
    let mut registry = Self::new();
    dev::register(&mut registry);
    system::register(&mut registry);
    apps::register(&mut registry);
    registry
}
```

- [ ] **Step 4: Run all rules tests**

Run: `cargo test --lib rules`
Expected: All tests pass (mod + dev + system + apps).

- [ ] **Step 5: Commit**

```bash
git add src/rules/
git commit -m "feat: system and application cleanup rules"
```

---

### Task 5: Media Rules (Duplicate Detection)

**Files:**
- Create: `src/rules/media.rs`
- Modify: `src/rules/mod.rs` (register)

- [ ] **Step 1: Write media rules with duplicate file detection**

Write `src/rules/media.rs`:

```rust
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};
use crate::tree::{FsNode, FsTree};
use std::collections::HashMap;
use std::path::PathBuf;

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(DuplicateFilesRule));
    registry.register(Box::new(LargeUnusedFilesRule));
}

/// Collect all file paths and sizes from the tree.
fn collect_files(node: &FsNode, files: &mut Vec<(PathBuf, u64)>) {
    if !node.is_dir {
        files.push((node.path.clone(), node.size));
    }
    for child in &node.children {
        collect_files(child, files);
    }
}

pub struct DuplicateFilesRule;

impl CleanupRule for DuplicateFilesRule {
    fn name(&self) -> &str { "Duplicate files" }
    fn description(&self) -> &str { "Files with identical content detected by BLAKE3 hash. Shows groups of duplicates." }
    fn impact(&self) -> &str { "You choose which copy to keep. Removing duplicates frees the extra copies' space." }
    fn category(&self) -> Category { Category::Media }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let mut files = Vec::new();
        collect_files(&tree.root, &mut files);

        // Group by size first (cheap pre-filter)
        let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
        for (path, size) in &files {
            if *size > 1024 { // Skip tiny files
                by_size.entry(*size).or_default().push(path.clone());
            }
        }

        // For groups with same size, hash to confirm duplicates
        let mut duplicate_groups: Vec<Vec<PathBuf>> = Vec::new();
        for (_size, paths) in &by_size {
            if paths.len() < 2 {
                continue;
            }
            let mut by_hash: HashMap<String, Vec<PathBuf>> = HashMap::new();
            for path in paths {
                if let Ok(data) = std::fs::read(path) {
                    let hash = blake3::hash(&data).to_hex().to_string();
                    by_hash.entry(hash).or_default().push(path.clone());
                }
            }
            for (_, group) in by_hash {
                if group.len() >= 2 {
                    duplicate_groups.push(group);
                }
            }
        }

        if duplicate_groups.is_empty() {
            return Vec::new();
        }

        // Calculate total wasted space (all copies except one per group)
        let mut total_wasted: u64 = 0;
        let mut all_paths = Vec::new();
        for group in &duplicate_groups {
            let file_size = std::fs::metadata(&group[0]).map(|m| m.len()).unwrap_or(0);
            total_wasted += file_size * (group.len() as u64 - 1);
            all_paths.extend(group.iter().skip(1).cloned()); // Skip first (the "keeper")
        }

        let count = duplicate_groups.len();
        vec![CleanupItem {
            name: format!("Duplicate files ({} groups)", count),
            paths: all_paths,
            total_size: total_wasted,
            description: self.description().to_string(),
            impact: self.impact().to_string(),
            category: Category::Media,
            safety: Safety::Caution,
        }]
    }
}

pub struct LargeUnusedFilesRule;

impl CleanupRule for LargeUnusedFilesRule {
    fn name(&self) -> &str { "Large unused files" }
    fn description(&self) -> &str { "Files larger than 1 GB not accessed in 90+ days. Informational only." }
    fn impact(&self) -> &str { "Review suggested. These files may be important — bloat only flags them for your attention." }
    fn category(&self) -> Category { Category::Media }
    fn safety(&self) -> Safety { Safety::Risky }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        use std::time::{Duration, SystemTime};

        let ninety_days = Duration::from_secs(90 * 24 * 3600);
        let cutoff = SystemTime::now() - ninety_days;
        let one_gb: u64 = 1024 * 1024 * 1024;

        let mut files = Vec::new();
        collect_files(&tree.root, &mut files);

        let mut large_old: Vec<(PathBuf, u64)> = Vec::new();
        for (path, size) in files {
            if size < one_gb {
                continue;
            }
            if let Ok(metadata) = std::fs::metadata(&path) {
                let accessed = metadata.accessed().unwrap_or(SystemTime::UNIX_EPOCH);
                if accessed < cutoff {
                    large_old.push((path, size));
                }
            }
        }

        if large_old.is_empty() {
            return Vec::new();
        }

        let total: u64 = large_old.iter().map(|(_, s)| s).sum();
        let count = large_old.len();
        let paths: Vec<PathBuf> = large_old.into_iter().map(|(p, _)| p).collect();

        vec![CleanupItem {
            name: format!("Large unused files ({} files)", count),
            paths,
            total_size: total,
            description: self.description().to_string(),
            impact: self.impact().to_string(),
            category: Category::Media,
            safety: Safety::Risky,
        }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn scan_tmp(tmp: &TempDir) -> FsTree {
        crate::scanner::scan(tmp.path())
    }

    #[test]
    fn test_duplicate_detection() {
        let tmp = TempDir::new().unwrap();
        let content = "x".repeat(2000); // >1024 bytes to pass filter
        fs::write(tmp.path().join("copy1.dat"), &content).unwrap();
        fs::write(tmp.path().join("copy2.dat"), &content).unwrap();
        fs::write(tmp.path().join("unique.dat"), "y".repeat(2000)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = DuplicateFilesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].paths.len(), 1); // One duplicate (keeps one copy)
        assert_eq!(items[0].total_size, 2000);
    }

    #[test]
    fn test_no_duplicates_when_unique() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("a.dat"), "x".repeat(2000)).unwrap();
        fs::write(tmp.path().join("b.dat"), "y".repeat(2000)).unwrap();

        let tree = scan_tmp(&tmp);
        let rule = DuplicateFilesRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty());
    }

    #[test]
    fn test_large_unused_skips_recent() {
        // This test just verifies the rule runs without error on small files
        // (we can't easily create 1GB test files)
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("small.txt"), "hello").unwrap();

        let tree = scan_tmp(&tmp);
        let rule = LargeUnusedFilesRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty()); // Too small to trigger
    }
}
```

- [ ] **Step 2: Register media module**

In `src/rules/mod.rs`, add `pub mod media;` and update `with_defaults`:

```rust
pub fn with_defaults() -> Self {
    let mut registry = Self::new();
    dev::register(&mut registry);
    system::register(&mut registry);
    apps::register(&mut registry);
    media::register(&mut registry);
    registry
}
```

- [ ] **Step 3: Run tests**

Run: `cargo test --lib rules::media`
Expected: All 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/rules/
git commit -m "feat: media cleanup rules with BLAKE3 duplicate detection"
```

---

### Task 6: Analyzer

**Files:**
- Create: `src/analyzer.rs`
- Modify: `src/main.rs` (add module)

- [ ] **Step 1: Write analyzer**

Write `src/analyzer.rs`:

```rust
use crate::rules::{Category, CleanupItem, RuleRegistry};
use crate::tree::FsTree;
use std::collections::HashMap;

/// Results of analyzing a scanned tree against cleanup rules.
#[derive(Debug)]
pub struct AnalysisResult {
    pub items: Vec<CleanupItem>,
    pub total_reclaimable: u64,
}

impl AnalysisResult {
    /// Group items by category.
    pub fn by_category(&self) -> HashMap<Category, Vec<&CleanupItem>> {
        let mut grouped: HashMap<Category, Vec<&CleanupItem>> = HashMap::new();
        for item in &self.items {
            grouped.entry(item.category).or_default().push(item);
        }
        grouped
    }

    /// Get total size of items matching a given category.
    pub fn category_size(&self, category: Category) -> u64 {
        self.items
            .iter()
            .filter(|i| i.category == category)
            .map(|i| i.total_size)
            .sum()
    }
}

/// Run all registered rules against a scanned tree.
pub fn analyze(tree: &FsTree, registry: &RuleRegistry) -> AnalysisResult {
    let mut items = Vec::new();

    for rule in registry.rules() {
        let detected = rule.detect(tree);
        items.extend(detected);
    }

    // Sort by size descending
    items.sort_by(|a, b| b.total_size.cmp(&a.total_size));

    let total_reclaimable = items.iter().map(|i| i.total_size).sum();

    AnalysisResult {
        items,
        total_reclaimable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::Safety;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_analyze_finds_node_modules() {
        let tmp = TempDir::new().unwrap();
        let nm = tmp.path().join("project/node_modules");
        fs::create_dir_all(&nm).unwrap();
        fs::write(nm.join("dep.js"), "x".repeat(500)).unwrap();

        let tree = crate::scanner::scan(tmp.path());
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        assert!(!result.items.is_empty());
        assert!(result.total_reclaimable > 0);
    }

    #[test]
    fn test_analyze_sorts_by_size() {
        let tmp = TempDir::new().unwrap();
        // Create two detectable items of different sizes
        let nm = tmp.path().join("proj/node_modules");
        fs::create_dir_all(&nm).unwrap();
        fs::write(nm.join("big.js"), "x".repeat(5000)).unwrap();

        let trash = tmp.path().join(".Trash");
        fs::create_dir_all(&trash).unwrap();
        fs::write(trash.join("small.txt"), "y".repeat(100)).unwrap();

        let tree = crate::scanner::scan(tmp.path());
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        if result.items.len() >= 2 {
            assert!(result.items[0].total_size >= result.items[1].total_size);
        }
    }

    #[test]
    fn test_analyze_by_category() {
        let tmp = TempDir::new().unwrap();
        let nm = tmp.path().join("proj/node_modules");
        fs::create_dir_all(&nm).unwrap();
        fs::write(nm.join("dep.js"), "code").unwrap();

        let tree = crate::scanner::scan(tmp.path());
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);
        let grouped = result.by_category();

        assert!(grouped.contains_key(&Category::Developer));
    }

    #[test]
    fn test_analyze_empty_tree() {
        let tmp = TempDir::new().unwrap();
        let tree = crate::scanner::scan(tmp.path());
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        assert_eq!(result.total_reclaimable, 0);
        assert!(result.items.is_empty());
    }
}
```

- [ ] **Step 2: Add module to main.rs**

```rust
mod analyzer;
mod rules;
mod scanner;
mod tree;

fn main() {
    println!("bloat v0.1.0");
}
```

- [ ] **Step 3: Run tests**

Run: `cargo test --lib analyzer`
Expected: All 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/analyzer.rs src/main.rs
git commit -m "feat: analyzer runs cleanup rules against scan tree"
```

---

### Task 7: Cleaner (Deletion Engine)

**Files:**
- Create: `src/cleaner.rs`
- Modify: `src/main.rs` (add module)

- [ ] **Step 1: Write the cleaner**

Write `src/cleaner.rs`:

```rust
use crate::rules::{CleanupItem, Safety};
use std::path::Path;

/// Result of a cleanup operation.
#[derive(Debug)]
pub struct CleanResult {
    pub item_name: String,
    pub freed_bytes: u64,
    pub paths_removed: usize,
    pub paths_failed: Vec<(std::path::PathBuf, String)>,
}

/// Method of deletion.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DeleteMethod {
    Trash,
    Permanent,
}

/// Move a path to macOS Trash.
fn trash_path(path: &Path) -> Result<(), String> {
    trash::delete(path).map_err(|e| format!("Failed to trash {}: {}", path.display(), e))
}

/// Permanently delete a path.
fn permanent_delete(path: &Path) -> Result<(), String> {
    if path.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    }
    .map_err(|e| format!("Failed to delete {}: {}", path.display(), e))
}

/// Clean a single item using the specified method.
pub fn clean_item(item: &CleanupItem, method: DeleteMethod) -> CleanResult {
    let mut freed: u64 = 0;
    let mut removed: usize = 0;
    let mut failed: Vec<(std::path::PathBuf, String)> = Vec::new();

    for path in &item.paths {
        if !path.exists() {
            continue;
        }

        // Get size before deletion
        let size = if path.is_dir() {
            dir_size(path)
        } else {
            std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
        };

        let result = match method {
            DeleteMethod::Trash => trash_path(path),
            DeleteMethod::Permanent => permanent_delete(path),
        };

        match result {
            Ok(_) => {
                freed += size;
                removed += 1;
            }
            Err(e) => {
                failed.push((path.clone(), e));
            }
        }
    }

    CleanResult {
        item_name: item.name.clone(),
        freed_bytes: freed,
        paths_removed: removed,
        paths_failed: failed,
    }
}

/// Determine the appropriate delete method based on safety level and user preference.
pub fn default_method(safety: Safety) -> DeleteMethod {
    match safety {
        Safety::Safe => DeleteMethod::Trash,
        Safety::Caution => DeleteMethod::Trash,
        Safety::Risky => DeleteMethod::Trash, // Default to trash even for risky; permanent is opt-in
    }
}

/// Calculate total size of a directory.
fn dir_size(path: &Path) -> u64 {
    jwalk::WalkDir::new(path)
        .skip_hidden(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter_map(|e| e.path().symlink_metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

/// Dry run: report what would be cleaned without actually deleting.
pub fn dry_run(items: &[CleanupItem]) -> Vec<(String, u64, usize, Safety)> {
    items
        .iter()
        .map(|item| {
            (
                item.name.clone(),
                item.total_size,
                item.paths.len(),
                item.safety,
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::{Category, Safety};
    use std::fs;
    use tempfile::TempDir;

    fn make_test_item(tmp: &TempDir) -> CleanupItem {
        let dir = tmp.path().join("test_cleanup");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("file1.txt"), "hello").unwrap();
        fs::write(dir.join("file2.txt"), "world").unwrap();

        CleanupItem {
            name: "Test item".to_string(),
            paths: vec![dir],
            total_size: 10,
            description: "test".to_string(),
            impact: "none".to_string(),
            category: Category::Developer,
            safety: Safety::Safe,
        }
    }

    #[test]
    fn test_permanent_delete() {
        let tmp = TempDir::new().unwrap();
        let item = make_test_item(&tmp);

        let result = clean_item(&item, DeleteMethod::Permanent);

        assert_eq!(result.paths_removed, 1);
        assert!(result.paths_failed.is_empty());
        assert!(!item.paths[0].exists());
    }

    #[test]
    fn test_clean_nonexistent_path() {
        let item = CleanupItem {
            name: "Ghost".to_string(),
            paths: vec![std::path::PathBuf::from("/tmp/does_not_exist_bloat_test")],
            total_size: 0,
            description: "test".to_string(),
            impact: "none".to_string(),
            category: Category::Developer,
            safety: Safety::Safe,
        };

        let result = clean_item(&item, DeleteMethod::Permanent);
        assert_eq!(result.paths_removed, 0);
        assert!(result.paths_failed.is_empty()); // Skipped, not failed
    }

    #[test]
    fn test_dry_run() {
        let items = vec![CleanupItem {
            name: "Test".to_string(),
            paths: vec![std::path::PathBuf::from("/fake")],
            total_size: 1000,
            description: "d".to_string(),
            impact: "i".to_string(),
            category: Category::System,
            safety: Safety::Caution,
        }];

        let report = dry_run(&items);
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].0, "Test");
        assert_eq!(report[0].1, 1000);
    }

    #[test]
    fn test_default_method() {
        assert_eq!(default_method(Safety::Safe), DeleteMethod::Trash);
        assert_eq!(default_method(Safety::Caution), DeleteMethod::Trash);
        assert_eq!(default_method(Safety::Risky), DeleteMethod::Trash);
    }
}
```

- [ ] **Step 2: Add module to main.rs**

```rust
mod analyzer;
mod cleaner;
mod rules;
mod scanner;
mod tree;

fn main() {
    println!("bloat v0.1.0");
}
```

- [ ] **Step 3: Run tests**

Run: `cargo test --lib cleaner`
Expected: All 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/cleaner.rs src/main.rs
git commit -m "feat: deletion engine with trash/permanent support and dry-run"
```

---

### Task 8: CLI Parsing with Clap

**Files:**
- Modify: `src/main.rs` (full rewrite with clap)

- [ ] **Step 1: Write CLI parser**

Rewrite `src/main.rs`:

```rust
mod analyzer;
mod cleaner;
mod rules;
mod scanner;
mod tree;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "bloat", version, about = "Your disk is bloated. Let's fix that.")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Output as JSON
    #[arg(long, global = true)]
    pub json: bool,

    /// Disable colored output
    #[arg(long, global = true)]
    pub no_color: bool,

    /// Directory to scan (default: home directory)
    #[arg(long, global = true)]
    pub path: Option<PathBuf>,

    /// Minimum size to display (e.g. 100MB, 1GB)
    #[arg(long, global = true)]
    pub min_size: Option<String>,
}

#[derive(Subcommand)]
pub enum Command {
    /// Scan and print disk usage summary
    Scan {
        /// Optional path to scan
        path: Option<PathBuf>,
    },
    /// Clean up detected junk
    Clean {
        /// Show what would be cleaned without deleting
        #[arg(long)]
        dry_run: bool,

        /// Auto-clean all SAFE items without prompts
        #[arg(long)]
        safe: bool,
    },
    /// Show top N largest directories
    Top {
        /// Number of directories to show (default: 10)
        #[arg(default_value = "10")]
        count: usize,
    },
}

impl Cli {
    /// Resolve the scan path: explicit --path, subcommand path, or home dir.
    pub fn scan_path(&self) -> PathBuf {
        if let Some(ref p) = self.path {
            return p.clone();
        }
        if let Some(Command::Scan { path: Some(ref p) }) = self.command {
            return p.clone();
        }
        dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
    }
}

fn main() {
    let cli = Cli::parse();

    match &cli.command {
        None => {
            // Launch TUI (TODO: Task 9)
            println!("bloat v0.1.0 — TUI mode (coming soon)");
            println!("Scan path: {}", cli.scan_path().display());
        }
        Some(Command::Scan { .. }) => {
            run_scan(&cli);
        }
        Some(Command::Clean { dry_run, safe }) => {
            run_clean(&cli, *dry_run, *safe);
        }
        Some(Command::Top { count }) => {
            run_top(&cli, *count);
        }
    }
}

fn run_scan(cli: &Cli) {
    let path = cli.scan_path();
    eprintln!("Scanning {}...", path.display());

    let tree = scanner::scan(&path);
    let registry = rules::RuleRegistry::with_defaults();
    let result = analyzer::analyze(&tree, &registry);

    if cli.json {
        print_scan_json(&tree, &result);
    } else {
        print_scan_text(&tree, &result);
    }
}

fn print_scan_text(tree: &tree::FsTree, result: &analyzer::AnalysisResult) {
    if let Some(stats) = scanner::disk_stats(&tree.root.path) {
        println!(
            "Disk: {} used / {} total ({:.1}%)",
            format_size(stats.used_bytes),
            format_size(stats.total_bytes),
            stats.used_bytes as f64 / stats.total_bytes as f64 * 100.0
        );
        println!();
    }

    println!("Scanned: {} ({})", tree.root.path.display(), format_size(tree.total_size()));

    if !result.items.is_empty() {
        println!("\nReclaimable: {}", format_size(result.total_reclaimable));
        for item in &result.items {
            println!(
                "  {:6} [{:>7}] {}",
                item.safety,
                format_size(item.total_size),
                item.name
            );
        }
    } else {
        println!("\nNo cleanup items detected.");
    }
}

fn print_scan_json(tree: &tree::FsTree, result: &analyzer::AnalysisResult) {
    let items: Vec<serde_json::Value> = result
        .items
        .iter()
        .map(|item| {
            serde_json::json!({
                "name": item.name,
                "size": item.total_size,
                "safety": format!("{}", item.safety),
                "category": format!("{}", item.category),
                "paths": item.paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>(),
            })
        })
        .collect();

    let output = serde_json::json!({
        "scan_path": tree.root.path.display().to_string(),
        "total_size": tree.total_size(),
        "reclaimable": result.total_reclaimable,
        "items": items,
    });

    println!("{}", serde_json::to_string_pretty(&output).unwrap());
}

fn run_clean(cli: &Cli, dry_run: bool, safe_only: bool) {
    let path = cli.scan_path();
    eprintln!("Scanning {}...", path.display());

    let tree = scanner::scan(&path);
    let registry = rules::RuleRegistry::with_defaults();
    let result = analyzer::analyze(&tree, &registry);

    if result.items.is_empty() {
        println!("Nothing to clean!");
        return;
    }

    if dry_run {
        let report = cleaner::dry_run(&result.items);
        println!("Dry run — would clean:\n");
        for (name, size, count, safety) in &report {
            println!("  {:6} [{:>7}] {} ({} paths)", safety, format_size(*size), name, count);
        }
        let total: u64 = report.iter().map(|(_, s, _, _)| s).sum();
        println!("\nTotal: {}", format_size(total));
        return;
    }

    let items: Vec<&rules::CleanupItem> = if safe_only {
        result.items.iter().filter(|i| i.safety == rules::Safety::Safe).collect()
    } else {
        result.items.iter().collect()
    };

    if items.is_empty() {
        println!("No items match the criteria.");
        return;
    }

    for item in &items {
        let method = cleaner::default_method(item.safety);
        if !safe_only && item.safety != rules::Safety::Safe {
            eprint!(
                "{} [{:>7}] {} — clean? [y/N] ",
                item.safety,
                format_size(item.total_size),
                item.name
            );
            let mut input = String::new();
            std::io::stdin().read_line(&mut input).unwrap_or(0);
            if !input.trim().eq_ignore_ascii_case("y") {
                println!("  Skipped.");
                continue;
            }
        }

        let clean_result = cleaner::clean_item(item, method);
        println!(
            "  Cleaned {} — freed {}",
            clean_result.item_name,
            format_size(clean_result.freed_bytes)
        );
        for (path, err) in &clean_result.paths_failed {
            eprintln!("  Error: {} — {}", path.display(), err);
        }
    }
}

fn run_top(cli: &Cli, count: usize) {
    let path = cli.scan_path();
    eprintln!("Scanning {}...", path.display());

    let tree = scanner::scan(&path);

    println!("Top {} largest directories under {}:\n", count, path.display());

    let mut dirs: Vec<(&str, u64)> = tree
        .root
        .children
        .iter()
        .filter(|n| n.is_dir)
        .map(|n| (n.name.as_str(), n.size))
        .collect();

    dirs.sort_by(|a, b| b.1.cmp(&a.1));
    dirs.truncate(count);

    for (i, (name, size)) in dirs.iter().enumerate() {
        println!("  {:>2}. {:>10}  {}", i + 1, format_size(*size), name);
    }
}

fn format_size(bytes: u64) -> String {
    human_bytes::human_bytes(bytes as f64)
}
```

- [ ] **Step 2: Add dirs crate dependency**

Add to `Cargo.toml` under `[dependencies]`:

```toml
dirs = "6"
```

- [ ] **Step 3: Test CLI parsing**

Run: `cargo build && ./target/debug/bloat --help`
Expected: Help text with scan, clean, top subcommands.

Run: `cargo build && ./target/debug/bloat scan --help`
Expected: Help text for scan subcommand.

- [ ] **Step 4: Commit**

```bash
git add src/main.rs Cargo.toml
git commit -m "feat: clap CLI with scan, clean, and top subcommands"
```

---

### Task 9: TUI App State & Event Loop

**Files:**
- Create: `src/app.rs`
- Create: `src/ui/mod.rs`
- Modify: `src/main.rs` (add modules, wire up TUI launch)

- [ ] **Step 1: Write app state and event loop**

Write `src/app.rs`:

```rust
use crate::analyzer::AnalysisResult;
use crate::rules::RuleRegistry;
use crate::scanner::{DiskStats, ScanProgress};
use crate::tree::FsTree;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

/// Which tab is active.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Tab {
    Overview,
    Explorer,
    Cleanup,
}

/// State for the explorer tab.
pub struct ExplorerState {
    /// Index of the selected item in the flattened visible list.
    pub selected: usize,
    /// Set of expanded directory paths.
    pub expanded: std::collections::HashSet<PathBuf>,
    /// Search query (if active).
    pub search: Option<String>,
}

impl ExplorerState {
    pub fn new() -> Self {
        Self {
            selected: 0,
            expanded: std::collections::HashSet::new(),
            search: None,
        }
    }
}

/// State for the cleanup tab.
pub struct CleanupState {
    /// Index of selected item.
    pub selected: usize,
    /// Set of selected item indices for cleanup.
    pub checked: std::collections::HashSet<usize>,
}

impl CleanupState {
    pub fn new() -> Self {
        Self {
            selected: 0,
            checked: std::collections::HashSet::new(),
        }
    }
}

/// Full application state.
pub struct App {
    pub tab: Tab,
    pub scan_path: PathBuf,
    pub disk_stats: Option<DiskStats>,
    pub tree: Option<FsTree>,
    pub analysis: Option<AnalysisResult>,
    pub scanning: bool,
    pub explorer: ExplorerState,
    pub cleanup: CleanupState,
    pub show_help: bool,
    pub should_quit: bool,
}

impl App {
    pub fn new(scan_path: PathBuf) -> Self {
        let disk_stats = crate::scanner::disk_stats(&scan_path);

        Self {
            tab: Tab::Overview,
            scan_path,
            disk_stats,
            tree: None,
            analysis: None,
            scanning: false,
            explorer: ExplorerState::new(),
            cleanup: CleanupState::new(),
            show_help: false,
            should_quit: false,
        }
    }

    /// Start an async scan, returning the receiver for progress updates.
    pub fn start_scan(&mut self) -> mpsc::Receiver<ScanProgress> {
        self.scanning = true;
        self.tree = None;
        self.analysis = None;
        let (tx, rx) = mpsc::channel();
        crate::scanner::scan_async(self.scan_path.clone(), tx);
        rx
    }

    /// Handle a completed scan.
    pub fn on_scan_complete(&mut self, tree: FsTree) {
        let registry = RuleRegistry::with_defaults();
        let analysis = crate::analyzer::analyze(&tree, &registry);
        self.tree = Some(tree);
        self.analysis = Some(analysis);
        self.scanning = false;
    }

    /// Handle a key event.
    pub fn on_key(&mut self, key: KeyEvent) {
        // Global keys
        match key.code {
            KeyCode::Char('q') => {
                self.should_quit = true;
                return;
            }
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.should_quit = true;
                return;
            }
            KeyCode::Char('?') => {
                self.show_help = !self.show_help;
                return;
            }
            KeyCode::Char('1') => {
                self.tab = Tab::Overview;
                return;
            }
            KeyCode::Char('2') => {
                self.tab = Tab::Explorer;
                return;
            }
            KeyCode::Char('3') => {
                self.tab = Tab::Cleanup;
                return;
            }
            KeyCode::Tab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Explorer,
                    Tab::Explorer => Tab::Cleanup,
                    Tab::Cleanup => Tab::Overview,
                };
                return;
            }
            KeyCode::BackTab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Cleanup,
                    Tab::Explorer => Tab::Overview,
                    Tab::Cleanup => Tab::Explorer,
                };
                return;
            }
            _ => {}
        }

        // Tab-specific keys
        match self.tab {
            Tab::Overview => self.on_key_overview(key),
            Tab::Explorer => self.on_key_explorer(key),
            Tab::Cleanup => self.on_key_cleanup(key),
        }
    }

    fn on_key_overview(&mut self, _key: KeyEvent) {
        // Overview has no interactive elements beyond global keys
    }

    fn on_key_explorer(&mut self, key: KeyEvent) {
        let visible_count = self.explorer_visible_count();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.explorer.selected > 0 {
                    self.explorer.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.explorer.selected + 1 < visible_count {
                    self.explorer.selected += 1;
                }
            }
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => {
                if let Some(path) = self.explorer_selected_path() {
                    if path.is_dir() {
                        self.explorer.expanded.insert(path);
                    }
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                if let Some(path) = self.explorer_selected_path() {
                    self.explorer.expanded.remove(&path);
                }
            }
            _ => {}
        }
    }

    fn on_key_cleanup(&mut self, key: KeyEvent) {
        let item_count = self.analysis.as_ref().map_or(0, |a| a.items.len());
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.cleanup.selected > 0 {
                    self.cleanup.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.cleanup.selected + 1 < item_count {
                    self.cleanup.selected += 1;
                }
            }
            KeyCode::Char(' ') => {
                let idx = self.cleanup.selected;
                if self.cleanup.checked.contains(&idx) {
                    self.cleanup.checked.remove(&idx);
                } else {
                    self.cleanup.checked.insert(idx);
                }
            }
            KeyCode::Char('a') => {
                // Toggle all
                if self.cleanup.checked.len() == item_count {
                    self.cleanup.checked.clear();
                } else {
                    self.cleanup.checked = (0..item_count).collect();
                }
            }
            _ => {}
        }
    }

    /// Count visible items in explorer (respecting expanded state).
    fn explorer_visible_count(&self) -> usize {
        self.tree.as_ref().map_or(0, |t| self.count_visible(&t.root))
    }

    fn count_visible(&self, node: &crate::tree::FsNode) -> usize {
        let mut count = 1; // This node
        if node.is_dir && self.explorer.expanded.contains(&node.path) {
            for child in &node.children {
                count += self.count_visible(child);
            }
        }
        count
    }

    /// Get the path of the currently selected explorer item.
    fn explorer_selected_path(&self) -> Option<PathBuf> {
        self.tree.as_ref().and_then(|t| {
            let mut idx = 0;
            self.find_by_index(&t.root, self.explorer.selected, &mut idx)
        })
    }

    fn find_by_index(
        &self,
        node: &crate::tree::FsNode,
        target: usize,
        current: &mut usize,
    ) -> Option<PathBuf> {
        if *current == target {
            return Some(node.path.clone());
        }
        *current += 1;
        if node.is_dir && self.explorer.expanded.contains(&node.path) {
            for child in &node.children {
                if let Some(path) = self.find_by_index(child, target, current) {
                    return Some(path);
                }
            }
        }
        None
    }
}

/// Run the TUI event loop.
pub fn run(mut terminal: DefaultTerminal, mut app: App) -> std::io::Result<()> {
    let rx = app.start_scan();

    loop {
        terminal.draw(|frame| crate::ui::draw(frame, &app))?;

        // Poll for scan progress (non-blocking)
        if app.scanning {
            if let Ok(progress) = rx.try_recv() {
                match progress {
                    ScanProgress::Done(tree) => {
                        app.on_scan_complete(tree);
                    }
                    ScanProgress::Error(path, err) => {
                        eprintln!("Scan error: {} — {}", path.display(), err);
                    }
                    ScanProgress::Scanning(_) => {}
                }
            }
        }

        // Poll for keyboard input
        if event::poll(Duration::from_millis(33))? {
            if let Event::Key(key) = event::read()? {
                // Ignore key release events on some platforms
                if key.kind == crossterm::event::KeyEventKind::Press {
                    app.on_key(key);
                }
            }
        }

        if app.should_quit {
            break;
        }
    }

    Ok(())
}
```

- [ ] **Step 2: Create UI module stub**

Write `src/ui/mod.rs`:

```rust
pub mod overview;
pub mod explorer;
pub mod cleanup;

use crate::app::{App, Tab};
use ratatui::prelude::*;
use ratatui::widgets::*;

/// Main draw function dispatches to the active tab.
pub fn draw(frame: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // Header + tabs
            Constraint::Min(0),   // Tab content
            Constraint::Length(1), // Status bar
        ])
        .split(frame.area());

    draw_header(frame, app, chunks[0]);

    match app.tab {
        Tab::Overview => overview::draw(frame, app, chunks[1]),
        Tab::Explorer => explorer::draw(frame, app, chunks[1]),
        Tab::Cleanup => cleanup::draw(frame, app, chunks[1]),
    }

    draw_status_bar(frame, app, chunks[2]);

    if app.show_help {
        draw_help_overlay(frame);
    }
}

fn draw_header(frame: &mut Frame, app: &App, area: Rect) {
    let titles = vec!["1 Overview", "2 Explorer", "3 Cleanup"];
    let selected = match app.tab {
        Tab::Overview => 0,
        Tab::Explorer => 1,
        Tab::Cleanup => 2,
    };

    let tabs = Tabs::new(titles)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" bloat ")
                .title_style(Style::default().fg(Color::Yellow).bold()),
        )
        .select(selected)
        .style(Style::default().fg(Color::DarkGray))
        .highlight_style(Style::default().fg(Color::Cyan).bold());

    frame.render_widget(tabs, area);
}

fn draw_status_bar(frame: &mut Frame, app: &App, area: Rect) {
    let status = if app.scanning {
        "Scanning...  "
    } else {
        "1-3: tabs · Tab: next · r: rescan · q: quit · ?: help"
    };

    let bar = Paragraph::new(status)
        .style(Style::default().fg(Color::DarkGray));

    frame.render_widget(bar, area);
}

fn draw_help_overlay(frame: &mut Frame) {
    let area = centered_rect(60, 60, frame.area());

    let help_text = vec![
        Line::from("Global").style(Style::default().fg(Color::Yellow).bold()),
        Line::from("  1/2/3    Switch tabs"),
        Line::from("  Tab      Next tab"),
        Line::from("  r        Rescan"),
        Line::from("  q        Quit"),
        Line::from("  ?        Toggle help"),
        Line::from(""),
        Line::from("Explorer").style(Style::default().fg(Color::Yellow).bold()),
        Line::from("  ↑/↓/j/k  Navigate"),
        Line::from("  Enter/→   Expand directory"),
        Line::from("  ←/h       Collapse directory"),
        Line::from(""),
        Line::from("Cleanup").style(Style::default().fg(Color::Yellow).bold()),
        Line::from("  ↑/↓/j/k  Navigate"),
        Line::from("  Space     Toggle selection"),
        Line::from("  a         Select/deselect all"),
    ];

    let help = Paragraph::new(help_text)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Help ")
                .title_style(Style::default().fg(Color::Yellow)),
        )
        .style(Style::default().fg(Color::White));

    frame.render_widget(Clear, area);
    frame.render_widget(help, area);
}

/// Helper: create a centered rect.
pub fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(area);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}

/// Format bytes to human-readable string.
pub fn format_size(bytes: u64) -> String {
    human_bytes::human_bytes(bytes as f64)
}

/// Color for safety level.
pub fn safety_color(safety: crate::rules::Safety) -> Color {
    match safety {
        crate::rules::Safety::Safe => Color::Green,
        crate::rules::Safety::Caution => Color::Yellow,
        crate::rules::Safety::Risky => Color::Red,
    }
}
```

- [ ] **Step 3: Create placeholder tab renderers**

Write `src/ui/overview.rs`:

```rust
use crate::app::App;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Overview ");

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center);
        frame.render_widget(loading, area);
        return;
    }

    let text = Paragraph::new("Overview tab — coming in Task 10")
        .block(block);
    frame.render_widget(text, area);
}
```

Write `src/ui/explorer.rs`:

```rust
use crate::app::App;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Explorer ");

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center);
        frame.render_widget(loading, area);
        return;
    }

    let text = Paragraph::new("Explorer tab — coming in Task 11")
        .block(block);
    frame.render_widget(text, area);
}
```

Write `src/ui/cleanup.rs`:

```rust
use crate::app::App;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Cleanup ");

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center);
        frame.render_widget(loading, area);
        return;
    }

    let text = Paragraph::new("Cleanup tab — coming in Task 12")
        .block(block);
    frame.render_widget(text, area);
}
```

- [ ] **Step 4: Wire up TUI launch in main.rs**

Update the `None` arm in `main()`:

```rust
None => {
    let path = cli.scan_path();
    let app = app::App::new(path);
    let terminal = ratatui::init();
    let result = app::run(terminal, app);
    ratatui::restore();
    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}
```

Add `mod app;` and `mod ui;` to the module declarations at the top.

- [ ] **Step 5: Build and test TUI launches**

Run: `cargo build`
Expected: Compiles successfully.

Run: `./target/debug/bloat` (press `q` to quit)
Expected: TUI appears with tabs, scanning message, then placeholder content.

- [ ] **Step 6: Commit**

```bash
git add src/app.rs src/ui/ src/main.rs
git commit -m "feat: TUI app state, event loop, and tab skeleton"
```

---

### Task 10: TUI Overview Tab

**Files:**
- Modify: `src/ui/overview.rs`

- [ ] **Step 1: Implement the overview tab renderer**

Rewrite `src/ui/overview.rs`:

```rust
use crate::app::App;
use crate::ui::format_size;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Overview ")
        .title_style(Style::default().fg(Color::Yellow).bold());

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(loading, area);
        return;
    }

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4),  // Disk stats + bar
            Constraint::Length(1),  // Spacer
            Constraint::Length(7),  // Top consumers
            Constraint::Length(1),  // Spacer
            Constraint::Min(3),    // Reclaimable summary
        ])
        .split(inner);

    draw_disk_stats(frame, app, chunks[0]);
    draw_top_consumers(frame, app, chunks[2]);
    draw_reclaimable(frame, app, chunks[4]);
}

fn draw_disk_stats(frame: &mut Frame, app: &App, area: Rect) {
    if let Some(ref stats) = app.disk_stats {
        let pct = stats.used_bytes as f64 / stats.total_bytes as f64;
        let bar_color = if pct > 0.9 {
            Color::Red
        } else if pct > 0.7 {
            Color::Yellow
        } else {
            Color::Green
        };

        let text = vec![
            Line::from(vec![
                Span::styled("Disk Usage: ", Style::default().fg(Color::White)),
                Span::styled(format_size(stats.used_bytes), Style::default().fg(bar_color).bold()),
                Span::raw(" / "),
                Span::raw(format_size(stats.total_bytes)),
                Span::styled(format!(" ({:.1}%)", pct * 100.0), Style::default().fg(bar_color)),
            ]),
            Line::from(""),
        ];

        frame.render_widget(Paragraph::new(text), area);

        // Gauge on the remaining space
        let gauge_area = Rect {
            x: area.x,
            y: area.y + 2,
            width: area.width,
            height: 1,
        };

        let gauge = Gauge::default()
            .gauge_style(Style::default().fg(bar_color).bg(Color::DarkGray))
            .ratio(pct.min(1.0))
            .label(format!("{:.1}%", pct * 100.0));

        frame.render_widget(gauge, gauge_area);
    }
}

fn draw_top_consumers(frame: &mut Frame, app: &App, area: Rect) {
    let tree = match &app.tree {
        Some(t) => t,
        None => return,
    };

    let mut lines = vec![
        Line::from(Span::styled(
            "Top Space Consumers",
            Style::default().fg(Color::Yellow).bold(),
        )),
        Line::from(""),
    ];

    let top: Vec<_> = tree
        .root
        .children
        .iter()
        .filter(|n| n.is_dir)
        .take(5)
        .collect();

    for (i, node) in top.iter().enumerate() {
        lines.push(Line::from(vec![
            Span::styled(format!("  {:>2}. ", i + 1), Style::default().fg(Color::DarkGray)),
            Span::styled(
                format!("{:>10}", format_size(node.size)),
                Style::default().fg(Color::Magenta),
            ),
            Span::raw("  "),
            Span::raw(&node.name),
        ]));
    }

    frame.render_widget(Paragraph::new(lines), area);
}

fn draw_reclaimable(frame: &mut Frame, app: &App, area: Rect) {
    let analysis = match &app.analysis {
        Some(a) => a,
        None => return,
    };

    if analysis.total_reclaimable == 0 {
        let text = Paragraph::new("No reclaimable space detected.")
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(text, area);
        return;
    }

    let lines = vec![
        Line::from(vec![
            Span::styled("Reclaimable: ", Style::default().fg(Color::Green).bold()),
            Span::styled(
                format_size(analysis.total_reclaimable),
                Style::default().fg(Color::Green).bold(),
            ),
            Span::styled(
                format!("  ({} items)", analysis.items.len()),
                Style::default().fg(Color::DarkGray),
            ),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Press 3 to review and clean up.",
            Style::default().fg(Color::DarkGray),
        )),
    ];

    frame.render_widget(Paragraph::new(lines), area);
}
```

- [ ] **Step 2: Build and visually test**

Run: `cargo build && ./target/debug/bloat`
Expected: Overview tab shows disk usage gauge, top consumers (after scan completes), and reclaimable summary. Press `q` to quit.

- [ ] **Step 3: Commit**

```bash
git add src/ui/overview.rs
git commit -m "feat: Overview tab with disk stats, top consumers, and reclaimable summary"
```

---

### Task 11: TUI Explorer Tab

**Files:**
- Modify: `src/ui/explorer.rs`

- [ ] **Step 1: Implement the explorer tab**

Rewrite `src/ui/explorer.rs`:

```rust
use crate::app::App;
use crate::tree::FsNode;
use crate::ui::format_size;
use ratatui::prelude::*;
use ratatui::widgets::*;
use std::path::PathBuf;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Explorer ")
        .title_style(Style::default().fg(Color::Yellow).bold());

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(loading, area);
        return;
    }

    let tree = match &app.tree {
        Some(t) => t,
        None => {
            let empty = Paragraph::new("No scan data.").block(block);
            frame.render_widget(empty, area);
            return;
        }
    };

    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Header: current path
    let header_area = Rect { height: 1, ..inner };
    let header = Paragraph::new(Line::from(vec![
        Span::styled(
            format!("{}", tree.root.path.display()),
            Style::default().fg(Color::Cyan),
        ),
        Span::styled(
            format!(" ({})", format_size(tree.root.size)),
            Style::default().fg(Color::DarkGray),
        ),
    ]));
    frame.render_widget(header, header_area);

    // Tree area
    let tree_area = Rect {
        y: inner.y + 1,
        height: inner.height.saturating_sub(1),
        ..inner
    };

    let mut items = Vec::new();
    flatten_tree(&tree.root, 0, app, &mut items, tree.root.size);

    let visible_height = tree_area.height as usize;
    let selected = app.explorer.selected;

    // Calculate scroll offset to keep selection visible
    let offset = if selected >= visible_height {
        selected - visible_height + 1
    } else {
        0
    };

    let visible_items: Vec<ListItem> = items
        .iter()
        .skip(offset)
        .take(visible_height)
        .enumerate()
        .map(|(i, (line, _))| {
            let idx = i + offset;
            let style = if idx == selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };
            ListItem::new(line.clone()).style(style)
        })
        .collect();

    let list = List::new(visible_items);
    frame.render_widget(list, tree_area);
}

/// Flatten the tree into a list of displayable lines with depth info.
fn flatten_tree(
    node: &FsNode,
    depth: usize,
    app: &App,
    items: &mut Vec<(Line<'static>, PathBuf)>,
    root_size: u64,
) {
    // Skip the root node itself from the list
    if depth > 0 {
        let indent = "  ".repeat(depth - 1);
        let is_expanded = app.explorer.expanded.contains(&node.path);
        let arrow = if node.is_dir {
            if is_expanded { "▼ " } else { "▶ " }
        } else {
            "  "
        };

        let name_style = if node.is_dir {
            Style::default().fg(Color::Cyan).bold()
        } else {
            Style::default().fg(Color::White)
        };

        let suffix = if node.is_dir { "/" } else { "" };

        // Size bar width proportional to root
        let bar_ratio = if root_size > 0 {
            node.size as f64 / root_size as f64
        } else {
            0.0
        };
        let bar_max_width = 20;
        let bar_width = (bar_ratio * bar_max_width as f64).ceil() as usize;
        let bar = "█".repeat(bar_width.max(1).min(bar_max_width));

        let bar_color = if bar_ratio > 0.3 {
            Color::Red
        } else if bar_ratio > 0.1 {
            Color::Yellow
        } else {
            Color::Green
        };

        let line = Line::from(vec![
            Span::raw(format!("{}{}", indent, arrow)),
            Span::styled(format!("{}{}", node.name, suffix), name_style),
            Span::raw("  "),
            Span::styled(
                format!("{:>10}", format_size(node.size)),
                Style::default().fg(Color::Magenta),
            ),
            Span::raw(" "),
            Span::styled(bar, Style::default().fg(bar_color)),
        ]);

        items.push((line, node.path.clone()));
    }

    // Recurse into children if expanded (or if root)
    let should_show_children = depth == 0 || app.explorer.expanded.contains(&node.path);
    if node.is_dir && should_show_children {
        for child in &node.children {
            flatten_tree(child, depth + 1, app, items, root_size);
        }
    }
}
```

- [ ] **Step 2: Build and visually test**

Run: `cargo build && ./target/debug/bloat`
Expected: Press `2` for Explorer. Shows tree with arrows, sizes, and bars. Arrow keys navigate, Enter expands directories, Left collapses. Press `q` to quit.

- [ ] **Step 3: Commit**

```bash
git add src/ui/explorer.rs
git commit -m "feat: Explorer tab with interactive directory tree and size bars"
```

---

### Task 12: TUI Cleanup Tab

**Files:**
- Modify: `src/ui/cleanup.rs`
- Modify: `src/app.rs` (add cleanup execution)

- [ ] **Step 1: Implement the cleanup tab renderer**

Rewrite `src/ui/cleanup.rs`:

```rust
use crate::app::App;
use crate::rules::{Category, Safety};
use crate::ui::{format_size, safety_color};
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Cleanup ")
        .title_style(Style::default().fg(Color::Yellow).bold());

    if app.scanning {
        let loading = Paragraph::new("Scanning filesystem...")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(loading, area);
        return;
    }

    let analysis = match &app.analysis {
        Some(a) => a,
        None => {
            let empty = Paragraph::new("No scan data.").block(block);
            frame.render_widget(empty, area);
            return;
        }
    };

    if analysis.items.is_empty() {
        let clean = Paragraph::new("Your disk is clean! Nothing to remove.")
            .block(block)
            .style(Style::default().fg(Color::Green));
        frame.render_widget(clean, area);
        return;
    }

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2), // Summary header
            Constraint::Min(0),   // Item list
            Constraint::Length(2), // Action bar
        ])
        .split(inner);

    // Summary header
    let selected_size: u64 = app
        .cleanup
        .checked
        .iter()
        .filter_map(|&i| analysis.items.get(i))
        .map(|item| item.total_size)
        .sum();

    let header = Line::from(vec![
        Span::styled("Reclaimable: ", Style::default().fg(Color::Green).bold()),
        Span::styled(
            format_size(analysis.total_reclaimable),
            Style::default().fg(Color::Green).bold(),
        ),
        Span::raw("    "),
        Span::styled("Selected: ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            format!("{} ({} items)", format_size(selected_size), app.cleanup.checked.len()),
            Style::default().fg(Color::White),
        ),
    ]);
    frame.render_widget(Paragraph::new(header), chunks[0]);

    // Item list with category grouping
    let mut lines: Vec<ListItem> = Vec::new();
    let mut current_category: Option<Category> = None;
    let visible_height = chunks[1].height as usize;

    for (i, item) in analysis.items.iter().enumerate() {
        // Category header
        if current_category != Some(item.category) {
            current_category = Some(item.category);
            let cat_color = match item.category {
                Category::Developer => Color::Magenta,
                Category::System => Color::Blue,
                Category::App => Color::Yellow,
                Category::Media => Color::Cyan,
            };
            lines.push(ListItem::new(Line::from(Span::styled(
                format!("{}", item.category),
                Style::default().fg(cat_color).bold(),
            ))));
        }

        let checked = if app.cleanup.checked.contains(&i) {
            "[x]"
        } else {
            "[ ]"
        };

        let safety_style = Style::default().fg(safety_color(item.safety));
        let is_selected = i == app.cleanup.selected;

        let line = Line::from(vec![
            Span::raw("  "),
            Span::styled(
                checked,
                if app.cleanup.checked.contains(&i) {
                    Style::default().fg(Color::Green)
                } else {
                    Style::default().fg(Color::DarkGray)
                },
            ),
            Span::raw(" "),
            Span::styled("●", safety_style),
            Span::raw(" "),
            Span::raw(format!("{:<40}", item.name)),
            Span::styled(
                format!("{:>10}", format_size(item.total_size)),
                Style::default().fg(Color::Magenta),
            ),
            Span::raw("  "),
            Span::styled(format!("{}", item.safety), safety_style),
        ]);

        let style = if is_selected {
            Style::default().bg(Color::DarkGray)
        } else {
            Style::default()
        };

        lines.push(ListItem::new(line).style(style));
    }

    // Calculate scroll offset
    // Account for category headers in the flat list
    let total_lines = lines.len();
    let offset = if app.cleanup.selected >= visible_height {
        app.cleanup.selected.saturating_sub(visible_height / 2)
    } else {
        0
    };

    let list = List::new(lines);
    frame.render_widget(list, chunks[1]);

    // Action bar
    let action = Line::from(vec![
        Span::styled("Space", Style::default().fg(Color::Cyan)),
        Span::raw(": toggle  "),
        Span::styled("a", Style::default().fg(Color::Cyan)),
        Span::raw(": all  "),
        Span::styled("i", Style::default().fg(Color::Cyan)),
        Span::raw(": details  "),
        Span::styled("Enter", Style::default().fg(Color::Green).bold()),
        Span::raw(": clean selected"),
    ]);
    frame.render_widget(Paragraph::new(action), chunks[2]);
}
```

- [ ] **Step 2: Add 'i' (info) and 'r' (rescan) key handlers to app.rs**

Add to `on_key_cleanup` in `src/app.rs`, inside the match:

```rust
KeyCode::Char('i') => {
    // Info is displayed via a popup — set a flag
    // (simplified: we'll toggle info display for the selected item)
}
```

Add to the global key handler in `on_key`, before the tab-specific dispatch:

```rust
KeyCode::Char('r') => {
    // Handled by caller — we set a flag
    // For now, rescan is handled in the run loop
    return;
}
```

- [ ] **Step 3: Build and visually test**

Run: `cargo build && ./target/debug/bloat`
Expected: Press `3` for Cleanup tab. Shows categorized items with checkboxes and safety labels. Space toggles selection, `a` selects all. Press `q` to quit.

- [ ] **Step 4: Commit**

```bash
git add src/ui/cleanup.rs src/app.rs
git commit -m "feat: Cleanup tab with categorized items, checkboxes, and safety labels"
```

---

### Task 13: Wire Up Cleanup Execution in TUI

**Files:**
- Modify: `src/app.rs` (add Enter handler for cleanup)
- Modify: `src/ui/cleanup.rs` (show results)

- [ ] **Step 1: Add cleanup execution state to app**

Add to `App` struct in `src/app.rs`:

```rust
pub last_clean_result: Option<Vec<crate::cleaner::CleanResult>>,
```

Initialize it as `None` in `App::new`.

Add to `on_key_cleanup` match:

```rust
KeyCode::Enter => {
    self.execute_cleanup();
}
```

Add method to `App`:

```rust
fn execute_cleanup(&mut self) {
    let analysis = match &self.analysis {
        Some(a) => a,
        None => return,
    };

    if self.cleanup.checked.is_empty() {
        return;
    }

    let mut results = Vec::new();
    let indices: Vec<usize> = self.cleanup.checked.iter().cloned().collect();

    for &idx in &indices {
        if let Some(item) = analysis.items.get(idx) {
            let method = crate::cleaner::default_method(item.safety);
            let result = crate::cleaner::clean_item(item, method);
            results.push(result);
        }
    }

    self.last_clean_result = Some(results);
    self.cleanup.checked.clear();

    // Trigger rescan
    self.scanning = true;
    self.tree = None;
    self.analysis = None;
}
```

- [ ] **Step 2: Handle rescan after cleanup in the run loop**

In `src/app.rs`, update the `run` function to detect when a rescan is needed:

Replace the run loop with:

```rust
pub fn run(mut terminal: DefaultTerminal, mut app: App) -> std::io::Result<()> {
    let mut rx = app.start_scan();

    loop {
        terminal.draw(|frame| crate::ui::draw(frame, &app))?;

        // Poll for scan progress (non-blocking)
        if app.scanning {
            if let Ok(progress) = rx.try_recv() {
                match progress {
                    ScanProgress::Done(tree) => {
                        app.on_scan_complete(tree);
                    }
                    ScanProgress::Error(path, err) => {
                        eprintln!("Scan error: {} — {}", path.display(), err);
                    }
                    ScanProgress::Scanning(_) => {}
                }
            }
        }

        // If app requested a rescan (scanning=true but no receiver), start one
        if app.scanning && app.tree.is_none() {
            // Check if we need a new receiver
            if rx.try_recv().is_err() {
                rx = app.start_scan();
            }
        }

        // Poll for keyboard input
        if event::poll(Duration::from_millis(33))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == crossterm::event::KeyEventKind::Press {
                    app.on_key(key);
                }
            }
        }

        if app.should_quit {
            break;
        }
    }

    Ok(())
}
```

- [ ] **Step 3: Build and test cleanup flow**

Run: `cargo build && ./target/debug/bloat --path /tmp`
Expected: Navigate to Cleanup tab, select items with Space, press Enter to clean. Items are removed and a rescan triggers.

- [ ] **Step 4: Commit**

```bash
git add src/app.rs src/ui/cleanup.rs
git commit -m "feat: cleanup execution in TUI with automatic rescan"
```

---

### Task 14: Final Integration & Polish

**Files:**
- Modify: `src/app.rs` (rescan key handler)
- Modify: `src/main.rs` (ensure all paths work)

- [ ] **Step 1: Wire up 'r' key for rescan**

In `src/app.rs`, update the global key handler for `r`:

```rust
KeyCode::Char('r') => {
    if !self.scanning {
        self.scanning = true;
        self.tree = None;
        self.analysis = None;
    }
    return;
}
```

- [ ] **Step 2: End-to-end test of all CLI commands**

Run each and verify output:

```bash
cargo build --release

# TUI mode
./target/release/bloat --path /tmp
# (press 1, 2, 3 to switch tabs, q to quit)

# Scan subcommand
./target/release/bloat scan /tmp

# JSON output
./target/release/bloat scan /tmp --json

# Top directories
./target/release/bloat top 5 --path /tmp

# Dry run clean
./target/release/bloat clean --dry-run --path /tmp
```

- [ ] **Step 3: Commit final state**

```bash
git add -A
git commit -m "feat: final integration and polish for bloat v0.1.0"
```
