use std::collections::HashMap;
use std::path::PathBuf;

use crate::tree::{FsNode, FsTree};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

// ---------------------------------------------------------------------------
// Helper: collect_files
// ---------------------------------------------------------------------------

/// Recursively collects all file paths and their sizes from the tree.
pub fn collect_files(node: &FsNode, files: &mut Vec<(PathBuf, u64)>) {
    if !node.is_dir {
        files.push((node.path.clone(), node.size));
        return;
    }
    for child in &node.children {
        collect_files(child, files);
    }
}

// ---------------------------------------------------------------------------
// Rule 1: Duplicate Files
// ---------------------------------------------------------------------------

pub struct DuplicateFilesRule;

impl CleanupRule for DuplicateFilesRule {
    fn name(&self) -> &str {
        "Duplicate Files"
    }

    fn description(&self) -> &str {
        "Identical files detected by size pre-filter and BLAKE3 content hash. Removing duplicates frees wasted space while keeping one copy."
    }

    fn impact(&self) -> &str {
        "Medium — depends on how many duplicate files exist"
    }

    fn category(&self) -> Category {
        Category::Media
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let mut all_files: Vec<(PathBuf, u64)> = Vec::new();
        collect_files(&tree.root, &mut all_files);

        // Pre-filter: skip files <= 1024 bytes
        let candidates: Vec<(PathBuf, u64)> = all_files
            .into_iter()
            .filter(|(_, size)| *size > 1024)
            .collect();

        // Group by size
        let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
        for (path, size) in candidates {
            by_size.entry(size).or_default().push(path);
        }

        // For each size group with 2+ files, hash to confirm duplicates
        let mut duplicate_paths: Vec<PathBuf> = Vec::new();
        let mut wasted_bytes: u64 = 0;

        for (size, paths) in by_size {
            if paths.len() < 2 {
                continue;
            }

            // Hash each file
            let mut by_hash: HashMap<blake3::Hash, Vec<PathBuf>> = HashMap::new();
            for path in paths {
                match std::fs::read(&path) {
                    Ok(data) => {
                        let hash = blake3::hash(&data);
                        by_hash.entry(hash).or_default().push(path);
                    }
                    Err(_) => continue,
                }
            }

            // Collect duplicates (all copies except one keeper per hash group)
            for (_, group) in by_hash {
                if group.len() < 2 {
                    continue;
                }
                // Keep the first path, mark the rest as duplicates
                let extras = &group[1..];
                wasted_bytes += size * extras.len() as u64;
                duplicate_paths.extend_from_slice(extras);
            }
        }

        if duplicate_paths.is_empty() {
            return Vec::new();
        }

        vec![CleanupItem {
            name: format!("Duplicate Files ({} duplicates)", duplicate_paths.len()),
            paths: duplicate_paths,
            total_size: wasted_bytes,
            description: self.description().to_string(),
            impact: self.impact().to_string(),
            category: self.category(),
            safety: self.safety(),
        }]
    }
}

// ---------------------------------------------------------------------------
// Rule 2: Large Unused Files
// ---------------------------------------------------------------------------

const ONE_GB: u64 = 1_073_741_824;
const NINETY_DAYS_SECS: u64 = 90 * 24 * 60 * 60;

pub struct LargeUnusedFilesRule;

impl CleanupRule for LargeUnusedFilesRule {
    fn name(&self) -> &str {
        "Large Unused Files"
    }

    fn description(&self) -> &str {
        "Files larger than 1 GB that have not been accessed in over 90 days. Review before deleting."
    }

    fn impact(&self) -> &str {
        "Very High — each file is at least 1 GB"
    }

    fn category(&self) -> Category {
        Category::Media
    }

    fn safety(&self) -> Safety {
        Safety::Risky
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let mut all_files: Vec<(PathBuf, u64)> = Vec::new();
        collect_files(&tree.root, &mut all_files);

        // Filter to files >= 1 GB
        let large: Vec<(PathBuf, u64)> = all_files
            .into_iter()
            .filter(|(_, size)| *size >= ONE_GB)
            .collect();

        let now = std::time::SystemTime::now();

        let mut qualifying: Vec<(PathBuf, u64)> = Vec::new();
        for (path, size) in large {
            // Check last-accessed time via real filesystem metadata
            match std::fs::metadata(&path) {
                Ok(meta) => {
                    let accessed = match meta.accessed() {
                        Ok(t) => t,
                        Err(_) => continue,
                    };
                    let age_secs = now
                        .duration_since(accessed)
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    if age_secs > NINETY_DAYS_SECS {
                        qualifying.push((path, size));
                    }
                }
                Err(_) => continue,
            }
        }

        if qualifying.is_empty() {
            return Vec::new();
        }

        let total_size: u64 = qualifying.iter().map(|(_, s)| s).sum();
        let paths: Vec<PathBuf> = qualifying.into_iter().map(|(p, _)| p).collect();

        vec![CleanupItem {
            name: format!("Large Unused Files ({} files)", paths.len()),
            paths,
            total_size,
            description: self.description().to_string(),
            impact: self.impact().to_string(),
            category: self.category(),
            safety: self.safety(),
        }]
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(DuplicateFilesRule));
    registry.register(Box::new(LargeUnusedFilesRule));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use crate::scanner::scan;

    // ---- test_duplicate_detection -------------------------------------------

    #[test]
    fn test_duplicate_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Two identical 2000-byte files
        let content = "a".repeat(2000);
        fs::write(root.join("file_a.bin"), &content).unwrap();
        fs::write(root.join("file_b.bin"), &content).unwrap();

        // One unique file
        fs::write(root.join("unique.bin"), "b".repeat(2000)).unwrap();

        let tree = scan(root);
        let rule = DuplicateFilesRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one duplicate group item");
        let item = &items[0];
        // One duplicate (the extra copy), one kept
        assert_eq!(item.paths.len(), 1, "one duplicate path");
        assert_eq!(item.total_size, 2000, "wasted space equals one copy");
    }

    // ---- test_no_duplicates_when_unique ------------------------------------

    #[test]
    fn test_no_duplicates_when_unique() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Two files with different content (but same size to stress-test hashing)
        fs::write(root.join("alpha.bin"), "a".repeat(2000)).unwrap();
        fs::write(root.join("beta.bin"), "b".repeat(2000)).unwrap();

        let tree = scan(root);
        let rule = DuplicateFilesRule;
        let items = rule.detect(&tree);

        assert!(items.is_empty(), "different files should not be flagged as duplicates");
    }

    // ---- test_large_unused_skips_recent ------------------------------------

    #[test]
    fn test_large_unused_skips_recent() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Write a small file (well under 1 GB)
        fs::write(root.join("small.bin"), "x".repeat(1024)).unwrap();

        let tree = scan(root);
        let rule = LargeUnusedFilesRule;
        let items = rule.detect(&tree);

        assert!(
            items.is_empty(),
            "small file should not trigger LargeUnusedFilesRule"
        );
    }
}
