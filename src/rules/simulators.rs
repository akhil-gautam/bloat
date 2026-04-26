// Xcode CoreSimulator cleanup — User tier (paths owned by current user).

use std::path::PathBuf;

use crate::tree::FsTree;

use super::probe::{glob_paths, make_probed, size_of};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct SimulatorCachesRule;

impl CleanupRule for SimulatorCachesRule {
    fn name(&self) -> &str { "Simulator Caches" }
    fn description(&self) -> &str {
        "Per-simulator caches under ~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches and the global ~/Library/Developer/CoreSimulator/Caches."
    }
    fn impact(&self) -> &str { "High — accumulates per Xcode and per simulator OS" }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };

        let mut paths: Vec<PathBuf> = Vec::new();
        let global = home.join("Library/Developer/CoreSimulator/Caches");
        if global.exists() {
            paths.push(global);
        }
        let pattern = format!(
            "{}/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches",
            home.display()
        );
        paths.extend(glob_paths(&pattern));

        let matches: Vec<(PathBuf, u64)> = paths
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();

        make_probed(
            "Simulator Caches",
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
    registry.register(Box::new(SimulatorCachesRule));
}
