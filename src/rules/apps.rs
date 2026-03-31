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
// Rule 1: Browser Cache
// ---------------------------------------------------------------------------

pub struct BrowserCacheRule;

impl CleanupRule for BrowserCacheRule {
    fn name(&self) -> &str {
        "Browser Cache"
    }

    fn description(&self) -> &str {
        "Cache directories for Chrome, Safari, Firefox, and Arc browsers. Safe to delete; browsers rebuild their caches automatically."
    }

    fn impact(&self) -> &str {
        "High — browser caches can grow to hundreds of MB or more"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let browser_identifiers = [
            "Google/Chrome",
            "com.apple.Safari",
            "Firefox",
            "company.thebrowser.Browser",
        ];

        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Cache" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            browser_identifiers
                .iter()
                .any(|id| path_str.contains(id))
        });

        make_item(
            "Browser Cache",
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
// Rule 2: Slack Cache
// ---------------------------------------------------------------------------

pub struct SlackCacheRule;

impl CleanupRule for SlackCacheRule {
    fn name(&self) -> &str {
        "Slack Cache"
    }

    fn description(&self) -> &str {
        "Slack application cache and Service Worker directories under com.tinyspeck.slackmacgap. Safe to delete; Slack re-downloads as needed."
    }

    fn impact(&self) -> &str {
        "Medium — Slack caches can reach hundreds of MB"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Cache" && node.name != "Service Worker" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("com.tinyspeck.slackmacgap")
        });

        make_item(
            "Slack Cache",
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
// Rule 3: Spotify Cache
// ---------------------------------------------------------------------------

pub struct SpotifyCacheRule;

impl CleanupRule for SpotifyCacheRule {
    fn name(&self) -> &str {
        "Spotify Cache"
    }

    fn description(&self) -> &str {
        "Spotify's local track cache stored under ~/Library/Caches/com.spotify.client. Safe to delete; Spotify re-downloads tracks on demand."
    }

    fn impact(&self) -> &str {
        "High — Spotify caches streamed tracks and can grow to several GB"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "com.spotify.client" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("Caches")
        });

        make_item(
            "Spotify Cache",
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
// Rule 4: Docker
// ---------------------------------------------------------------------------

pub struct DockerRule;

impl CleanupRule for DockerRule {
    fn name(&self) -> &str {
        "Docker Data"
    }

    fn description(&self) -> &str {
        "Docker image layers, volumes, and container data. Use `docker system prune` to clean unused resources rather than deleting directly."
    }

    fn impact(&self) -> &str {
        "Very High — Docker images and volumes can consume tens of GB"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Docker" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            // Match Docker under Library/Containers OR directly at the home level
            path_str.contains("Library/Containers") || {
                // Home-level Docker: path ends with /Docker and parent looks like a home dir
                node.path
                    .parent()
                    .map(|p| {
                        let parent_str = p.to_string_lossy();
                        !parent_str.contains("Library")
                    })
                    .unwrap_or(false)
            }
        });

        make_item(
            "Docker Data",
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
// Rule 5: Homebrew Cache
// ---------------------------------------------------------------------------

pub struct HomebrewCacheRule;

impl CleanupRule for HomebrewCacheRule {
    fn name(&self) -> &str {
        "Homebrew Cache"
    }

    fn description(&self) -> &str {
        "Homebrew download cache stored under ~/Library/Caches/Homebrew. Safe to delete; Homebrew re-downloads packages as needed."
    }

    fn impact(&self) -> &str {
        "Medium — old formulae and cask downloads accumulate over time"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Safe
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            if node.name != "Homebrew" {
                return false;
            }
            let path_str = node.path.to_string_lossy();
            path_str.contains("Caches")
        });

        make_item(
            "Homebrew Cache",
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
// Rule 6: Package Manager Cache
// ---------------------------------------------------------------------------

pub struct PackageManagerCacheRule;

impl CleanupRule for PackageManagerCacheRule {
    fn name(&self) -> &str {
        "Package Manager Cache"
    }

    fn description(&self) -> &str {
        "Cached packages for npm (_cacache in .npm), pip (pip under Caches), and Cargo registry (~/.cargo/registry). Safe to regenerate, but re-downloading takes time."
    }

    fn impact(&self) -> &str {
        "High — combined package caches can reach gigabytes"
    }

    fn category(&self) -> Category {
        Category::App
    }

    fn safety(&self) -> Safety {
        Safety::Caution
    }

    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem> {
        let matches = find_dirs(&tree.root, &|node: &FsNode| {
            let path_str = node.path.to_string_lossy();

            // npm: _cacache under .npm
            if node.name == "_cacache" && path_str.contains(".npm") {
                return true;
            }

            // pip: pip under Caches
            if node.name == "pip" && path_str.contains("Caches") {
                return true;
            }

            // cargo: registry under .cargo
            if node.name == "registry" && path_str.contains(".cargo") {
                return true;
            }

            false
        });

        make_item(
            "Package Manager Cache",
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
    registry.register(Box::new(BrowserCacheRule));
    registry.register(Box::new(SlackCacheRule));
    registry.register(Box::new(SpotifyCacheRule));
    registry.register(Box::new(DockerRule));
    registry.register(Box::new(HomebrewCacheRule));
    registry.register(Box::new(PackageManagerCacheRule));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use crate::scanner::scan;

    // ---- test_docker_detection -----------------------------------------------

    #[test]
    fn test_docker_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Simulate Docker dir under Library/Containers
        let containers = root.join("Library").join("Containers");
        fs::create_dir_all(&containers).unwrap();
        let docker = containers.join("Docker");
        fs::create_dir(&docker).unwrap();
        fs::write(docker.join("docker.img"), "image_data".repeat(100)).unwrap();

        let tree = scan(root);
        let rule = DockerRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one Docker item");
        let item = &items[0];
        assert_eq!(item.safety, Safety::Caution);
        assert_eq!(item.paths.len(), 1);
    }

    // ---- test_homebrew_cache_detection ----------------------------------------

    #[test]
    fn test_homebrew_cache_detection() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // Simulate Homebrew cache under Library/Caches/Homebrew/downloads
        let homebrew_cache = root.join("Library").join("Caches").join("Homebrew");
        let downloads = homebrew_cache.join("downloads");
        fs::create_dir_all(&downloads).unwrap();
        fs::write(downloads.join("wget-1.21.tar.gz"), "archive_data".repeat(50)).unwrap();

        let tree = scan(root);
        let rule = HomebrewCacheRule;
        let items = rule.detect(&tree);

        assert_eq!(items.len(), 1, "should detect one Homebrew Cache item");
        let item = &items[0];
        assert_eq!(item.safety, Safety::Safe);
        assert_eq!(item.paths.len(), 1);
        assert!(item.total_size > 0, "total_size should reflect the file inside");
    }
}
