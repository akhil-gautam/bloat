// QuickLook + font caches — User tier.

use std::path::PathBuf;

use crate::tree::FsTree;

use super::probe::{make_probed, size_of};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct QuickLookCacheRule;

impl CleanupRule for QuickLookCacheRule {
    fn name(&self) -> &str { "QuickLook Thumbnails" }
    fn description(&self) -> &str {
        "QuickLook thumbnail cache under ~/Library/Caches/com.apple.QuickLook.thumbnailcache. macOS rebuilds it on demand."
    }
    fn impact(&self) -> &str { "Low to Medium — accumulates thumbnails of every previewed file" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let p = home.join("Library/Caches/com.apple.QuickLook.thumbnailcache");
        let s = size_of(&p);
        if s == 0 {
            return Vec::new();
        }
        make_probed(
            "QuickLook Thumbnails",
            vec![(p, s)],
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

pub struct FontCacheRule;

impl CleanupRule for FontCacheRule {
    fn name(&self) -> &str { "Font Caches" }
    fn description(&self) -> &str {
        "User font registry caches under ~/Library/Caches/com.apple.ATS. Rebuilt automatically on next login."
    }
    fn impact(&self) -> &str { "Low — usually under 100 MB but fixes flaky font rendering" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let candidates: Vec<PathBuf> = vec![
            home.join("Library/Caches/com.apple.ATS"),
            home.join("Library/Caches/com.apple.FontRegistry"),
        ];
        let matches: Vec<(PathBuf, u64)> = candidates
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();
        make_probed(
            "Font Caches",
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
    registry.register(Box::new(QuickLookCacheRule));
    registry.register(Box::new(FontCacheRule));
}
