use std::path::{Path, PathBuf};
use jwalk::WalkDir;

use crate::rules::{CleanupItem, Safety};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct CleanResult {
    pub item_name: String,
    pub freed_bytes: u64,
    pub paths_removed: usize,
    pub paths_failed: Vec<(PathBuf, String)>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DeleteMethod {
    Trash,
    Permanent,
    /// Delete via `rm -rf` wrapped in a single `osascript ... with administrator
    /// privileges` call. One auth prompt covers every path in this CleanResult.
    Admin,
}

// ---------------------------------------------------------------------------
// Deletion primitives
// ---------------------------------------------------------------------------

pub fn trash_path(path: &Path) -> Result<(), String> {
    trash::delete(path).map_err(|e| e.to_string())
}

pub fn permanent_delete(path: &Path) -> Result<(), String> {
    if path.is_dir() {
        std::fs::remove_dir_all(path).map_err(|e| e.to_string())
    } else {
        std::fs::remove_file(path).map_err(|e| e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Core clean function
// ---------------------------------------------------------------------------

pub fn clean_item(item: &CleanupItem, method: DeleteMethod) -> CleanResult {
    if method == DeleteMethod::Admin {
        return clean_item_admin(item);
    }

    let mut freed_bytes: u64 = 0;
    let mut paths_removed: usize = 0;
    let mut paths_failed: Vec<(PathBuf, String)> = Vec::new();

    for path in &item.paths {
        // Skip paths that no longer exist
        if !path.exists() {
            continue;
        }

        // Measure size before deletion
        let size = if path.is_dir() {
            dir_size(path)
        } else {
            path.metadata().map(|m| m.len()).unwrap_or(0)
        };

        // Attempt deletion
        let result = match method {
            DeleteMethod::Trash => trash_path(path),
            DeleteMethod::Permanent => permanent_delete(path),
            DeleteMethod::Admin => unreachable!(),
        };

        match result {
            Ok(()) => {
                freed_bytes += size;
                paths_removed += 1;
            }
            Err(e) => {
                paths_failed.push((path.clone(), e));
            }
        }
    }

    CleanResult {
        item_name: item.name.clone(),
        freed_bytes,
        paths_removed,
        paths_failed,
    }
}

/// Delete every path in `item` under one administrator-privileges prompt.
///
/// We size each path before deletion (still readable to the current user
/// for most admin-tier paths), then issue a single `osascript` call that
/// runs `rm -rf` over the joined, shell-quoted argument list.
fn clean_item_admin(item: &CleanupItem) -> CleanResult {
    // Special path: APFS local snapshots, encoded as virtual paths
    // "__apfs_snapshot__/<date>" by ApfsLocalSnapshotsRule.
    if item.paths.iter().all(|p| {
        p.to_string_lossy().starts_with("__apfs_snapshot__/")
    }) {
        return clean_apfs_snapshots(item);
    }

    let mut freed_bytes: u64 = 0;
    let mut paths_failed: Vec<(PathBuf, String)> = Vec::new();
    let mut existing: Vec<&PathBuf> = Vec::new();

    for path in &item.paths {
        if !path.exists() {
            continue;
        }
        let size = if path.is_dir() {
            dir_size(path)
        } else {
            path.metadata().map(|m| m.len()).unwrap_or(0)
        };
        freed_bytes += size;
        existing.push(path);
    }

    if existing.is_empty() {
        return CleanResult {
            item_name: item.name.clone(),
            freed_bytes: 0,
            paths_removed: 0,
            paths_failed: Vec::new(),
        };
    }

    let quoted: Vec<String> = existing
        .iter()
        .map(|p| shell_quote(&p.to_string_lossy()))
        .collect();
    let cmd = format!("/bin/rm -rf {}", quoted.join(" "));

    match crate::memory_actions::run_admin(&cmd) {
        Ok(_) => {
            // Re-check; anything still present counts as a failure.
            let mut removed = 0;
            for p in &existing {
                if p.exists() {
                    paths_failed.push(((*p).clone(), "still present after admin rm".into()));
                } else {
                    removed += 1;
                }
            }
            CleanResult {
                item_name: item.name.clone(),
                freed_bytes,
                paths_removed: removed,
                paths_failed,
            }
        }
        Err(e) => CleanResult {
            item_name: item.name.clone(),
            freed_bytes: 0,
            paths_removed: 0,
            paths_failed: existing.into_iter().map(|p| (p.clone(), e.clone())).collect(),
        },
    }
}

/// Delete each APFS local snapshot encoded as `__apfs_snapshot__/<date>`
/// using a single batched `tmutil deletelocalsnapshots` call per date.
fn clean_apfs_snapshots(item: &CleanupItem) -> CleanResult {
    let dates: Vec<String> = item
        .paths
        .iter()
        .filter_map(|p| {
            p.to_string_lossy()
                .strip_prefix("__apfs_snapshot__/")
                .map(str::to_string)
        })
        .collect();

    if dates.is_empty() {
        return CleanResult {
            item_name: item.name.clone(),
            freed_bytes: 0,
            paths_removed: 0,
            paths_failed: Vec::new(),
        };
    }

    let cmd = dates
        .iter()
        .map(|d| format!("/usr/bin/tmutil deletelocalsnapshots {}", shell_quote(d)))
        .collect::<Vec<_>>()
        .join(" && ");

    match crate::memory_actions::run_admin(&cmd) {
        Ok(_) => CleanResult {
            item_name: item.name.clone(),
            freed_bytes: 0,
            paths_removed: dates.len(),
            paths_failed: Vec::new(),
        },
        Err(e) => CleanResult {
            item_name: item.name.clone(),
            freed_bytes: 0,
            paths_removed: 0,
            paths_failed: item.paths.iter().map(|p| (p.clone(), e.clone())).collect(),
        },
    }
}

/// Single-quote a string for /bin/sh, escaping embedded single quotes.
fn shell_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

// ---------------------------------------------------------------------------
// Method selection
// ---------------------------------------------------------------------------

/// Always returns Trash — permanent deletion is strictly opt-in.
pub fn default_method(_safety: Safety) -> DeleteMethod {
    DeleteMethod::Trash
}

/// Pick the right deletion method for an item, accounting for admin-tier
/// rules whose targets the user cannot reach without elevation.
pub fn method_for(item: &CleanupItem) -> DeleteMethod {
    if item.requires_admin {
        DeleteMethod::Admin
    } else {
        default_method(item.safety)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Recursively sum the sizes of all files under `path`.
pub fn dir_size(path: &Path) -> u64 {
    WalkDir::new(path)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.metadata().ok())
        .filter(|meta| meta.is_file())
        .map(|meta| meta.len())
        .sum()
}

/// Return a summary of what would be cleaned without touching the filesystem.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::{Category, Safety};
    use std::fs;
    use tempfile::TempDir;

    /// Creates a temporary directory containing two small files and wraps it
    /// in a CleanupItem so tests have a ready-made target.
    fn make_test_item(tmp: &TempDir) -> CleanupItem {
        let dir = tmp.path().join("test_target");
        fs::create_dir(&dir).expect("create dir");
        fs::write(dir.join("file_a.txt"), b"hello").expect("write file_a");
        fs::write(dir.join("file_b.txt"), b"world").expect("write file_b");

        CleanupItem {
            name: "test_item".to_string(),
            paths: vec![dir],
            total_size: 10,
            description: "test".to_string(),
            impact: "low".to_string(),
            category: Category::Developer,
            safety: Safety::Safe,
            requires_admin: false,
            required_tier: None,
        }
    }

    #[test]
    fn test_permanent_delete() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let item = make_test_item(&tmp);
        let path = item.paths[0].clone();

        assert!(path.exists(), "path should exist before deletion");

        let result = clean_item(&item, DeleteMethod::Permanent);

        assert_eq!(result.paths_removed, 1);
        assert!(result.paths_failed.is_empty());
        assert!(!path.exists(), "path should be gone after permanent delete");
    }

    #[test]
    fn test_clean_nonexistent_path() {
        let item = CleanupItem {
            name: "ghost_item".to_string(),
            paths: vec![PathBuf::from("/tmp/__nonexistent_memclean_test_path__")],
            total_size: 0,
            description: "does not exist".to_string(),
            impact: "none".to_string(),
            category: Category::System,
            safety: Safety::Safe,
            requires_admin: false,
            required_tier: None,
        };

        let result = clean_item(&item, DeleteMethod::Permanent);

        assert_eq!(result.paths_removed, 0, "nonexistent paths should be skipped");
        assert!(result.paths_failed.is_empty(), "skipped paths should not be in paths_failed");
    }

    #[test]
    fn test_dry_run() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let item = make_test_item(&tmp);
        let items = vec![item];

        let summary = dry_run(&items);

        assert_eq!(summary.len(), 1);
        let (name, _size, count, safety) = &summary[0];
        assert_eq!(name, "test_item");
        assert_eq!(*count, 1);
        assert_eq!(*safety, Safety::Safe);
    }

    #[test]
    fn test_default_method() {
        assert_eq!(default_method(Safety::Safe), DeleteMethod::Trash);
        assert_eq!(default_method(Safety::Caution), DeleteMethod::Trash);
        assert_eq!(default_method(Safety::Risky), DeleteMethod::Trash);
    }
}
