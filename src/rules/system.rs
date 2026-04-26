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
        category: Category::System,
        safety,
        requires_admin: false,
        required_tier: None,
    })
}

// ---------------------------------------------------------------------------
// Rule 1: Library Caches
// ---------------------------------------------------------------------------

pub struct LibraryCachesRule;

impl CleanupRule for LibraryCachesRule {
    fn name(&self) -> &str {
        "Library Caches"
    }

    fn description(&self) -> &str {
        "Application caches stored under ~/Library/Caches. macOS recreates them as needed."
    }

    fn impact(&self) -> &str {
        "High — caches can accumulate gigabytes of stale data over time"
    }

    fn category(&self) -> Category {
        Category::System
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Caches" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("Library/Caches")
        });

        make_item(
            "Library Caches",
            matches,
            self.description(),
            self.impact(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 2: Old Logs
// ---------------------------------------------------------------------------

pub struct OldLogsRule;

impl CleanupRule for OldLogsRule {
    fn name(&self) -> &str {
        "Old Logs"
    }

    fn description(&self) -> &str {
        "Application log files stored under ~/Library/Logs. Safe to delete; apps recreate logs as needed."
    }

    fn impact(&self) -> &str {
        "Low to Medium — logs can pile up over time for chatty applications"
    }

    fn category(&self) -> Category {
        Category::System
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Logs" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("Library/Logs")
        });

        make_item(
            "Old Logs",
            matches,
            self.description(),
            self.impact(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 3: Trash
// ---------------------------------------------------------------------------

pub struct TrashRule;

impl CleanupRule for TrashRule {
    fn name(&self) -> &str {
        "Trash"
    }

    fn description(&self) -> &str {
        "Files in the macOS Trash (~/.Trash). Empty the Trash to permanently reclaim this space."
    }

    fn impact(&self) -> &str {
        "Variable — depends on what the user has moved to the Trash"
    }

    fn category(&self) -> Category {
        Category::System
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| node.name == ".Trash");

        make_item(
            "Trash",
            matches,
            self.description(),
            self.impact(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 4: iOS Backups
// ---------------------------------------------------------------------------

pub struct IosBackupsRule;

impl CleanupRule for IosBackupsRule {
    fn name(&self) -> &str {
        "iOS Backups"
    }

    fn description(&self) -> &str {
        "iPhone/iPad backups stored under ~/Library/Application Support/MobileSync/Backup. Remove old backups you no longer need."
    }

    fn impact(&self) -> &str {
        "Very High — full device backups can be several GB each"
    }

    fn category(&self) -> Category {
        Category::System
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Backup" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("MobileSync/Backup")
        });

        make_item(
            "iOS Backups",
            matches,
            self.description(),
            self.impact(),
            self.safety(),
        )
        .into_iter()
        .collect()
    }
}

// ---------------------------------------------------------------------------
// Rule 5: Time Machine Local Snapshots
// ---------------------------------------------------------------------------

pub struct TimeMachineLocalRule;

impl CleanupRule for TimeMachineLocalRule {
    fn name(&self) -> &str {
        "Time Machine Local Snapshots"
    }

    fn description(&self) -> &str {
        "Local Time Machine snapshots stored in .MobileBackups. macOS manages these automatically, but they can consume significant space."
    }

    fn impact(&self) -> &str {
        "High — local snapshots can occupy gigabytes of storage"
    }

    fn category(&self) -> Category {
        Category::System
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| node.name == ".MobileBackups");

        make_item(
            "Time Machine Local Snapshots",
            matches,
            self.description(),
            self.impact(),
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
    registry.register(Box::new(LibraryCachesRule));
    registry.register(Box::new(OldLogsRule));
    registry.register(Box::new(TrashRule));
    registry.register(Box::new(IosBackupsRule));
    registry.register(Box::new(TimeMachineLocalRule));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use crate::scanner::scan;

    // ---- test_trash_detection -----------------------------------------------

    #[test]
    fn test_trash_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        let trash = root.join(".Trash");
        fs::create_dir(&trash).unwrap();
        fs::write(trash.join("old_file.txt"), "some deleted content").unwrap();

        let tree = scan(root);
        let rule = TrashRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one Trash item");
        let item = &items[0];
        assert_eq!(item.safety, Safety::Safe);
        assert_eq!(item.paths.len(), 1);
        assert!(item.total_size > 0, "total_size should reflect the file inside");
    }

    // ---- test_no_trash_when_empty_dir ----------------------------------------

    #[test]
    fn test_no_trash_when_empty_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // No .Trash directory — only a regular file.
        fs::write(root.join("hello.txt"), "hi").unwrap();

        let tree = scan(root);
        let rule = TrashRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty(), "should not detect anything when no .Trash dir exists");
    }
}
