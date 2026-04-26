// iOS device backups + DeviceSupport — FDA tier.
//
// These paths sit inside ~/Library, which TCC protects on modern macOS,
// so without FDA we can't even enumerate the per-device directories. The
// existing Tree-walking iOS rule in system.rs catches this when the user
// scans their home dir; this version surfaces the items unconditionally.

use crate::permissions::{Capabilities, Tier};
use crate::tree::FsTree;

use super::probe::{glob_paths, probe_paths};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct IosBackupsFdaRule {
    caps: Capabilities,
}
pub struct IosDeviceSupportRule {
    caps: Capabilities,
}

impl CleanupRule for IosBackupsFdaRule {
    fn name(&self) -> &str { "iOS Backups (FDA)" }
    fn description(&self) -> &str {
        "Per-device iPhone/iPad backups under ~/Library/Application Support/MobileSync/Backup."
    }
    fn impact(&self) -> &str { "Very High — full device backups commonly exceed 10 GB" }
    fn category(&self) -> Category { Category::System }
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
            "{}/Library/Application Support/MobileSync/Backup/*",
            home.display()
        );
        let paths = glob_paths(&pattern);
        probe_paths(
            "iOS Backups (FDA)",
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

impl CleanupRule for IosDeviceSupportRule {
    fn name(&self) -> &str { "Xcode iOS DeviceSupport" }
    fn description(&self) -> &str {
        "Per-iOS-version symbol bundles cached by Xcode under ~/Library/Developer/Xcode/iOS DeviceSupport."
    }
    fn impact(&self) -> &str { "High — old iOS versions stick around forever" }
    fn category(&self) -> Category { Category::Developer }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let pattern = format!(
            "{}/Library/Developer/Xcode/iOS DeviceSupport/*",
            home.display()
        );
        let paths = glob_paths(&pattern);
        probe_paths(
            "Xcode iOS DeviceSupport",
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
    registry.register(Box::new(IosBackupsFdaRule { caps }));
    registry.register(Box::new(IosDeviceSupportRule { caps }));
}
