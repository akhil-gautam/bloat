// Photos.app cleanup rules — require Full Disk Access.
//
// We only target the derivative caches and the recently-deleted scratch
// area; original assets are never enumerated for deletion here.

use crate::permissions::{Capabilities, Tier};
use crate::tree::FsTree;

use super::probe::{glob_paths, probe_paths};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct PhotosCachesRule {
    caps: Capabilities,
}

impl CleanupRule for PhotosCachesRule {
    fn name(&self) -> &str { "Photos Library Caches" }
    fn description(&self) -> &str {
        "Derivative caches inside ~/Pictures/Photos Library.photoslibrary/resources/. Photos rebuilds them on demand."
    }
    fn impact(&self) -> &str { "Medium to High — derivatives often reach several GB" }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let pattern = format!(
            "{}/Pictures/Photos Library.photoslibrary/resources/derivatives",
            home.display()
        );
        let paths = glob_paths(&pattern);
        probe_paths(
            "Photos Library Caches",
            &paths,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            false,
            Some(Tier::FullDiskAccess),
        )
        .into_iter()
        .collect()
    }
}

pub fn register(registry: &mut RuleRegistry, caps: Capabilities) {
    registry.register(Box::new(PhotosCachesRule { caps }));
}
