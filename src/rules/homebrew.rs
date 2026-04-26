// Homebrew download cache — User tier.
//
// `brew --cache` resolves to ~/Library/Caches/Homebrew on Apple Silicon
// and /Users/<user>/Library/Caches/Homebrew on Intel; we just probe both.

use std::path::PathBuf;

use crate::tree::FsTree;

use super::probe::{make_probed, size_of};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct HomebrewCacheRule;

impl CleanupRule for HomebrewCacheRule {
    fn name(&self) -> &str { "Homebrew Cache" }
    fn description(&self) -> &str {
        "Downloaded bottles and source archives under `brew --cache`. Run `brew cleanup -s --prune=all` to remove."
    }
    fn impact(&self) -> &str { "Medium — old bottle downloads accumulate across upgrades" }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        // Probe well-known cache paths directly — never spawn `brew --cache`,
        // which costs ~1s of Ruby startup per scan.
        let mut paths: Vec<PathBuf> = Vec::new();
        if let Some(home) = dirs::home_dir() {
            for candidate in [
                home.join("Library/Caches/Homebrew"),
                PathBuf::from("/opt/homebrew/Library/Homebrew/cache"),
                PathBuf::from("/usr/local/Library/Homebrew/cache"),
            ] {
                if candidate.exists() {
                    paths.push(candidate);
                }
            }
        }

        let matches: Vec<(PathBuf, u64)> = paths
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();

        make_probed(
            "Homebrew Cache",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            false,
            None,
        )
        .into_iter()
        .collect()
    }
}

pub fn register(registry: &mut RuleRegistry) {
    registry.register(Box::new(HomebrewCacheRule));
}
