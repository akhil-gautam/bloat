pub mod dev;
pub mod system;
pub mod apps;

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

    pub fn with_defaults() -> Self {
        let mut registry = Self::new();
        dev::register(&mut registry);
        system::register(&mut registry);
        apps::register(&mut registry);
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
