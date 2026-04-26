// System-wide cleanups requiring administrator privileges.
//
// Every CleanupItem produced here has `requires_admin = true` so the
// cleaner routes its deletion through the batched osascript helper —
// one auth prompt per cleanup run, regardless of path count.

use std::path::PathBuf;
use std::process::Command;

use crate::permissions::{Capabilities, Tier};
use crate::tree::FsTree;

use super::probe::{glob_paths, make_probed, size_of};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct SystemCachesRule {
    caps: Capabilities,
}
pub struct SystemLogsRule {
    caps: Capabilities,
}
pub struct DiagnosticReportsRule {
    caps: Capabilities,
}
pub struct ApfsLocalSnapshotsRule {
    caps: Capabilities,
}

impl CleanupRule for SystemCachesRule {
    fn name(&self) -> &str { "System Caches (/Library/Caches)" }
    fn description(&self) -> &str {
        "Top-level /Library/Caches entries shared across users. macOS recreates them as needed."
    }
    fn impact(&self) -> &str { "High — system-wide caches add up over time" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.admin && !crate::permissions::admin_is_cached() {
            // Don't enumerate to avoid a slow walk we'd never use.
            return Vec::new();
        }
        let paths = glob_paths("/Library/Caches/*");
        let matches: Vec<(PathBuf, u64)> = paths
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();
        make_probed(
            "System Caches",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            true,
            Some(Tier::Admin),
        )
        .into_iter()
        .collect()
    }
}

impl CleanupRule for SystemLogsRule {
    fn name(&self) -> &str { "System Logs (/private/var/log)" }
    fn description(&self) -> &str {
        "Rotated system log files under /private/var/log. The current log stays untouched on the next syslog rotation."
    }
    fn impact(&self) -> &str { "Medium — chatty subsystems can leave gigabytes" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.admin && !crate::permissions::admin_is_cached() {
            return Vec::new();
        }
        let mut paths = glob_paths("/private/var/log/*.gz");
        paths.extend(glob_paths("/private/var/log/*/*.gz"));
        paths.extend(glob_paths("/private/var/log/asl/*.asl"));
        let matches: Vec<(PathBuf, u64)> = paths
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();
        make_probed(
            "System Logs",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            true,
            Some(Tier::Admin),
        )
        .into_iter()
        .collect()
    }
}

impl CleanupRule for DiagnosticReportsRule {
    fn name(&self) -> &str { "Diagnostic Reports" }
    fn description(&self) -> &str {
        "Crash reports under /Library/Logs/DiagnosticReports. Submit them to Apple if reproducing a bug; otherwise safe to remove."
    }
    fn impact(&self) -> &str { "Low to Medium — frequent crashes accumulate" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.admin && !crate::permissions::admin_is_cached() {
            return Vec::new();
        }
        let paths = glob_paths("/Library/Logs/DiagnosticReports/*");
        let matches: Vec<(PathBuf, u64)> = paths
            .into_iter()
            .filter_map(|p| {
                let s = size_of(&p);
                if s > 0 { Some((p, s)) } else { None }
            })
            .collect();
        make_probed(
            "Diagnostic Reports",
            matches,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            true,
            Some(Tier::Admin),
        )
        .into_iter()
        .collect()
    }
}

impl CleanupRule for ApfsLocalSnapshotsRule {
    fn name(&self) -> &str { "APFS Local Snapshots" }
    fn description(&self) -> &str {
        "Time Machine local snapshots on /. Listed via `tmutil listlocalsnapshots /` and removed via `tmutil deletelocalsnapshots <date>`."
    }
    fn impact(&self) -> &str { "Very High — invisible to Finder; can hold tens of GB" }
    fn category(&self) -> Category { Category::System }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.admin && !crate::permissions::admin_is_cached() {
            return Vec::new();
        }
        let out = match Command::new("tmutil").args(["listlocalsnapshots", "/"]).output() {
            Ok(o) if o.status.success() => o,
            _ => return Vec::new(),
        };
        // Each line looks like: com.apple.TimeMachine.2026-04-21-235501.local
        let snaps: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.trim().strip_prefix("com.apple.TimeMachine."))
            .filter_map(|s| s.strip_suffix(".local"))
            .map(|s| s.to_string())
            .collect();
        if snaps.is_empty() {
            return Vec::new();
        }
        // We can't accurately size APFS snapshots from userland, so we
        // surface a synthetic 0-byte item with paths set to the snapshot
        // dates. The Admin deletion path detects these specially.
        let paths: Vec<PathBuf> = snaps.iter().map(|s| PathBuf::from(format!("__apfs_snapshot__/{}", s))).collect();
        Some(CleanupItem {
            name: format!("APFS Local Snapshots ({} snaps)", snaps.len()),
            paths,
            total_size: 0,
            description: ApfsLocalSnapshotsRule::description(self).to_string(),
            impact: ApfsLocalSnapshotsRule::impact(self).to_string(),
            category: Category::System,
            safety: Safety::Caution,
            requires_admin: true,
            required_tier: Some(Tier::Admin),
        })
        .into_iter()
        .collect()
    }
}

pub fn register(registry: &mut RuleRegistry, caps: Capabilities) {
    registry.register(Box::new(SystemCachesRule { caps }));
    registry.register(Box::new(SystemLogsRule { caps }));
    registry.register(Box::new(DiagnosticReportsRule { caps }));
    registry.register(Box::new(ApfsLocalSnapshotsRule { caps }));
}
