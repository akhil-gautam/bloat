// Shared helpers for rules that probe known macOS paths directly,
// bypassing the FsTree walk. Used by the FDA / Admin tier rules whose
// targets sit outside any user-selected scan root.

use std::path::{Path, PathBuf};

use crate::permissions::Tier;
use super::{Category, CleanupItem, Safety};

/// Recursively sum file sizes under `path`, ignoring symlinks. Returns 0
/// if the path doesn't exist or can't be read.
pub fn size_of(path: &Path) -> u64 {
    if !path.exists() {
        return 0;
    }
    if path.is_file() {
        return path.metadata().map(|m| m.len()).unwrap_or(0);
    }
    let mut total: u64 = 0;
    for entry in jwalk::WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .flatten()
    {
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                total += meta.len();
            }
        }
    }
    total
}

/// Expand a glob pattern against the filesystem and return the matching
/// paths. Silently returns empty on failure.
pub fn glob_paths(pattern: &str) -> Vec<PathBuf> {
    glob::glob(pattern)
        .ok()
        .map(|it| it.flatten().collect())
        .unwrap_or_default()
}

/// Build a CleanupItem from a list of (path, size) pairs, attaching the
/// given tier and admin-flag. Returns None when there's nothing to clean.
pub fn make_probed(
    name: &str,
    matches: Vec<(PathBuf, u64)>,
    description: &str,
    impact: &str,
    category: Category,
    safety: Safety,
    requires_admin: bool,
    required_tier: Option<Tier>,
) -> Option<CleanupItem> {
    if matches.is_empty() {
        return None;
    }
    let total_size: u64 = matches.iter().map(|(_, s)| s).sum();
    let paths: Vec<PathBuf> = matches.into_iter().map(|(p, _)| p).collect();
    let display_name = if paths.len() > 1 {
        format!("{} ({} paths)", name, paths.len())
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
        requires_admin,
        required_tier,
    })
}

/// Convenience: size each existing path; drop missing ones; build the item.
pub fn probe_paths(
    name: &str,
    paths: &[PathBuf],
    description: &str,
    impact: &str,
    category: Category,
    safety: Safety,
    requires_admin: bool,
    required_tier: Option<Tier>,
) -> Option<CleanupItem> {
    let mut matches: Vec<(PathBuf, u64)> = Vec::new();
    for p in paths {
        if p.exists() {
            let s = size_of(p);
            if s > 0 {
                matches.push((p.clone(), s));
            }
        }
    }
    make_probed(
        name,
        matches,
        description,
        impact,
        category,
        safety,
        requires_admin,
        required_tier,
    )
}
