pub mod dev;
pub mod system;
pub mod apps;
pub mod media;
pub mod probe;
pub mod mail;
pub mod messages;
pub mod photos;
pub mod ios_backups;
pub mod simulators;
pub mod homebrew;
pub mod quicklook_fonts;
pub mod system_admin;

use crate::tree::FsTree;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Category {
    Developer,
    System,
    App,
    Media,
}

impl std::fmt::Display for Category {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Category::Developer => write!(f, "Developer"),
            Category::System => write!(f, "System"),
            Category::App => write!(f, "Applications"),
            Category::Media => write!(f, "Media"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Safety {
    Safe,
    Caution,
    Risky,
}

impl std::fmt::Display for Safety {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Safety::Safe => write!(f, "SAFE"),
            Safety::Caution => write!(f, "CAUTION"),
            Safety::Risky => write!(f, "RISKY"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CleanupItem {
    pub name: String,
    pub paths: Vec<PathBuf>,
    pub total_size: u64,
    pub description: String,
    pub impact: String,
    pub category: Category,
    pub safety: Safety,
    /// True when deletion requires administrator privileges (Admin tier).
    /// The cleaner routes these through a single batched osascript prompt.
    pub requires_admin: bool,
    /// Required permission tier to even *detect* this item. UI uses this
    /// to show locked rules with a hint to grant access. None = User tier.
    pub required_tier: Option<crate::permissions::Tier>,
}

pub trait CleanupRule: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn impact(&self) -> &str;
    fn category(&self) -> Category;
    fn safety(&self) -> Safety;
    fn detect(&self, tree: &FsTree) -> Vec<CleanupItem>;
}

pub struct RuleRegistry {
    rules: Vec<Box<dyn CleanupRule>>,
}

impl RuleRegistry {
    pub fn new() -> Self {
        Self { rules: Vec::new() }
    }

    pub fn register(&mut self, rule: Box<dyn CleanupRule>) {
        self.rules.push(rule);
    }

    pub fn rules(&self) -> &[Box<dyn CleanupRule>] {
        &self.rules
    }

    /// Tree-walking rules only. Used by the CLI subcommands and tests so
    /// behaviour stays scoped to whatever path was scanned.
    pub fn with_defaults() -> Self {
        let mut registry = Self::new();
        dev::register(&mut registry);
        system::register(&mut registry);
        apps::register(&mut registry);
        media::register(&mut registry);
        registry
    }

    /// Full registry including probe-based rules (Mail/Messages/Photos/etc.)
    /// gated by the supplied capabilities. Used by the TUI.
    pub fn with_caps(caps: crate::permissions::Capabilities) -> Self {
        let mut registry = Self::with_defaults();
        simulators::register(&mut registry);
        homebrew::register(&mut registry);
        quicklook_fonts::register(&mut registry);
        mail::register(&mut registry, caps);
        messages::register(&mut registry, caps);
        photos::register(&mut registry, caps);
        ios_backups::register(&mut registry, caps);
        system_admin::register(&mut registry, caps);
        registry
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safety_ordering() {
        assert!(Safety::Safe < Safety::Caution);
        assert!(Safety::Caution < Safety::Risky);
        assert!(Safety::Safe < Safety::Risky);
    }

    #[test]
    fn test_registry_register_and_count() {
        let registry = RuleRegistry::with_defaults();
        assert!(!registry.rules().is_empty());
    }
}
