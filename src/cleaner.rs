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

// ---------------------------------------------------------------------------
// Method selection
// ---------------------------------------------------------------------------

/// Always returns Trash — permanent deletion is strictly opt-in.
pub fn default_method(_safety: Safety) -> DeleteMethod {
    DeleteMethod::Trash
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
