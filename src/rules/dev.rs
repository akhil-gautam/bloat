use std::path::PathBuf;

use crate::tree::FsNode;
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};
use crate::tree::FsTree;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Recursively find directories matching the given predicate.
/// When a match is found, we do NOT recurse into it (to avoid double-counting).
/// Returns a `Vec<(PathBuf, u64)>` of (path, size) pairs.
fn find_dirs<F>(node: &FsNode, predicate: &F) -> Vec<(PathBuf, u64)>
where
    F: Fn(&FsNode) -> bool,
{
    let mut results = Vec::new();

    if node.is_dir && predicate(node) {
        results.push((node.path.clone(), node.size));
        // Do not recurse into the matched directory.
        return results;
    }

    for child in &node.children {
        results.extend(find_dirs(child, predicate));
    }

    results
}

/// Build a `CleanupItem` from a list of `(path, size)` matches.
/// Returns `None` if the list is empty.
/// Appends "(N dirs)" to the name when there are multiple matches.
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

    let display_name = if paths.len() > 1 {
        format!("{} ({} dirs)", name, paths.len())
    } else {
        name.to_string()
    };

    Some(CleanupItem {
        name: display_name,
        paths,
        total_size,
        description: description.to_string(),
        impact: impact.to_string(),
        category,
        safety,
    })
}

// ---------------------------------------------------------------------------
// Rule 1: node_modules
// ---------------------------------------------------------------------------

pub struct NodeModulesRule;

impl CleanupRule for NodeModulesRule {
    fn name(&self) -> &str {
        "Node Modules"
    }

    fn description(&self) -> &str {
        "npm/yarn/pnpm dependency directories. Safe to delete; reinstall with `npm install`."
    }

    fn impact(&self) -> &str {
        "High — node_modules can be hundreds of MB per project"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| node.name == "node_modules");
        make_item(
            "Node Modules",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 2: Xcode DerivedData
// ---------------------------------------------------------------------------

pub struct XcodeDerivedDataRule;

impl CleanupRule for XcodeDerivedDataRule {
    fn name(&self) -> &str {
        "Xcode DerivedData"
    }

    fn description(&self) -> &str {
        "Xcode build artefacts stored under ~/Library/Developer/Xcode/DerivedData. Safe to delete; Xcode rebuilds on next build."
    }

    fn impact(&self) -> &str {
        "High — can grow to several GB over time"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        // Look for a node named "DerivedData" whose path contains
        // Developer/Xcode (case-insensitive path segment check).
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "DerivedData" {
                return false;
            }
            let path_str = node.path.to_string_lossy().to_lowercase();
            path_str.contains("developer") && path_str.contains("xcode")
        });

        make_item(
            "Xcode DerivedData",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 3: Cargo target
// ---------------------------------------------------------------------------

pub struct CargoTargetRule;

impl CleanupRule for CargoTargetRule {
    fn name(&self) -> &str {
        "Cargo Build Artifacts"
    }

    fn description(&self) -> &str {
        "Rust `target/` directories. Rebuild with `cargo build`."
    }

    fn impact(&self) -> &str {
        "High — incremental builds can consume gigabytes per project"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        // A `target/` dir is a Cargo target only when its parent contains Cargo.toml.
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "target" {
                return false;
            }
            if let Some(parent) = node.path.parent() {
                return parent.join("Cargo.toml").exists();
            }
            false
        });

        make_item(
            "Cargo Build Artifacts",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 4: Gradle build
// ---------------------------------------------------------------------------

pub struct GradleBuildRule;

impl CleanupRule for GradleBuildRule {
    fn name(&self) -> &str {
        "Gradle Build Artifacts"
    }

    fn description(&self) -> &str {
        "Gradle cache and build output directories. Rebuild with `./gradlew build`."
    }

    fn impact(&self) -> &str {
        "Medium — caches and outputs can reach hundreds of MB"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != ".gradle" && node.name != "build" {
                return false;
            }
            if let Some(parent) = node.path.parent() {
                return parent.join("build.gradle").exists()
                    || parent.join("build.gradle.kts").exists();
            }
            false
        });

        make_item(
            "Gradle Build Artifacts",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 5: Python cache
// ---------------------------------------------------------------------------

pub struct PythonCacheRule;

impl CleanupRule for PythonCacheRule {
    fn name(&self) -> &str {
        "Python Cache & Environments"
    }

    fn description(&self) -> &str {
        "Python bytecode caches (__pycache__), virtual environments (.venv), and test cache (.tox). Safe to remove."
    }

    fn impact(&self) -> &str {
        "Medium — virtual envs can be hundreds of MB each"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            matches!(node.name.as_str(), "__pycache__" | ".venv" | ".tox")
        });

        make_item(
            "Python Cache & Environments",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 6: CocoaPods cache
// ---------------------------------------------------------------------------

pub struct CocoaPodsRule;

impl CleanupRule for CocoaPodsRule {
    fn name(&self) -> &str {
        "CocoaPods Cache"
    }

    fn description(&self) -> &str {
        "CocoaPods download cache stored under ~/Library/Caches/CocoaPods. Safe to delete; re-fetched on next `pod install`."
    }

    fn impact(&self) -> &str {
        "Medium — can accumulate stale pod downloads"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "CocoaPods" {
                return false;
            }
            let path_str = node.path.to_string_lossy().to_lowercase();
            path_str.contains("library") && path_str.contains("caches")
        });

        make_item(
            "CocoaPods Cache",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 7: Swift Package Manager build
// ---------------------------------------------------------------------------

pub struct SwiftBuildRule;

impl CleanupRule for SwiftBuildRule {
    fn name(&self) -> &str {
        "Swift Package Build Artifacts"
    }

    fn description(&self) -> &str {
        "Swift Package Manager `.build/` directories. Rebuild with `swift build`."
    }

    fn impact(&self) -> &str {
        "Medium — build products can grow significantly for large packages"
    }

    fn category(&self) -> Category {
        Category::Developer
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != ".build" {
                return false;
            }
            if let Some(parent) = node.path.parent() {
                return parent.join("Package.swift").exists();
            }
            false
        });

        make_item(
            "Swift Package Build Artifacts",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(NodeModulesRule));
    registry.register(Box::new(XcodeDerivedDataRule));
    registry.register(Box::new(CargoTargetRule));
    registry.register(Box::new(GradleBuildRule));
    registry.register(Box::new(PythonCacheRule));
    registry.register(Box::new(CocoaPodsRule));
    registry.register(Box::new(SwiftBuildRule));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use crate::scanner::scan;

    // ---- test_node_modules_detection ----------------------------------------

    #[test]
    fn test_node_modules_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        let nm = root.join("node_modules");
        fs::create_dir(&nm).unwrap();
        // Write a 1000-byte file inside node_modules.
        fs::write(nm.join("big_dep.js"), "x".repeat(1000)).unwrap();

        let tree = scan(root);
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one node_modules item");
        let item = &items[0];
        assert_eq!(item.total_size, 1000);
        assert_eq!(item.safety, Safety::Safe);
        assert_eq!(item.paths.len(), 1);
    }

    // ---- test_no_false_positives_on_empty -----------------------------------

    #[test]
    fn test_no_false_positives_on_empty() {
        let dir = tempfile::tempdir().expect("tempdir");
        // Only write a regular file — no node_modules.
        fs::write(dir.path().join("hello.txt"), "hi").unwrap();

        let tree = scan(dir.path());
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty(), "should not detect anything");
    }

    // ---- test_cargo_target_detection ----------------------------------------

    #[test]
    fn test_cargo_target_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Create a fake Rust project layout.
        fs::write(root.join("Cargo.toml"), "[package]\nname = \"foo\"").unwrap();
        let target = root.join("target");
        fs::create_dir(&target).unwrap();
        let debug = target.join("debug");
        fs::create_dir(&debug).unwrap();
        fs::write(debug.join("foo"), "binary_content").unwrap();

        let tree = scan(root);
        let rule = CargoTargetRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one Cargo target item");
        let item = &items[0];
        assert_eq!(item.safety, Safety::Caution);
        assert_eq!(item.paths.len(), 1);
    }

    // ---- test_python_cache_detection ----------------------------------------

    #[test]
    fn test_python_cache_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Create __pycache__ and .venv directories.
        let pycache = root.join("__pycache__");
        fs::create_dir(&pycache).unwrap();
        fs::write(pycache.join("module.pyc"), "bytecode").unwrap();

        let venv = root.join(".venv");
        fs::create_dir(&venv).unwrap();
        fs::write(venv.join("python3"), "python_binary").unwrap();

        let tree = scan(root);
        let rule = PythonCacheRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should produce one CleanupItem");
        let item = &items[0];
        assert_eq!(item.paths.len(), 2, "should contain 2 paths (__pycache__ + .venv)");
    }

    // ---- test_multiple_node_modules -----------------------------------------

    #[test]
    fn test_multiple_node_modules() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Create 3 projects, each with node_modules.
        for project in &["project_a", "project_b", "project_c"] {
            let proj_dir = root.join(project);
            fs::create_dir(&proj_dir).unwrap();
            let nm = proj_dir.join("node_modules");
            fs::create_dir(&nm).unwrap();
            fs::write(nm.join("dep.js"), "code").unwrap();
        }

        let tree = scan(root);
        let rule = NodeModulesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should produce one combined CleanupItem");
        let item = &items[0];
        assert_eq!(item.paths.len(), 3, "should have 3 paths");
        assert!(
            item.name.contains("3 dirs"),
            "name should contain '3 dirs', got: {}",
            item.name
        );
    }
}
