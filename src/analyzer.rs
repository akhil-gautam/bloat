use crate::rules::{Category, CleanupItem, RuleRegistry};
use crate::tree::FsTree;
use std::collections::HashMap;

#[derive(Debug)]
pub struct AnalysisResult {
    pub items: Vec<CleanupItem>,
    pub total_reclaimable: u64,
}

impl AnalysisResult {
    pub fn by_category(&self) -> HashMap<Category, Vec<&CleanupItem>> {
        let mut grouped: HashMap<Category, Vec<&CleanupItem>> = HashMap::new();
        for item in &self.items {
            grouped.entry(item.category).or_default().push(item);
        }
        grouped
    }

    pub fn category_size(&self, category: Category) -> u64 {
        self.items.iter().filter(|i| i.category == category).map(|i| i.total_size).sum()
    }
}

pub fn analyze(tree: &FsTree, registry: &RuleRegistry) -> AnalysisResult {
    let mut items = Vec::new();
    for rule in registry.rules() {
        items.extend(rule.detect(tree));
    }
    items.sort_by(|a, b| b.total_size.cmp(&a.total_size));
    let total_reclaimable = items.iter().map(|i| i.total_size).sum();
    AnalysisResult { items, total_reclaimable }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::Category;
    use crate::scanner::scan;
    use std::fs;

    #[test]
    fn test_analyze_finds_node_modules() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        let nm = root.join("node_modules");
        fs::create_dir(&nm).unwrap();
        fs::write(nm.join("dep.js"), "x".repeat(500)).unwrap();

        let tree = scan(root);
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        assert!(!result.items.is_empty(), "should find at least one item");
        assert!(result.total_reclaimable > 0, "total_reclaimable should be > 0");
    }

    #[test]
    fn test_analyze_sorts_by_size() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        // node_modules — big
        let nm = root.join("node_modules");
        fs::create_dir(&nm).unwrap();
        fs::write(nm.join("big_dep.js"), "x".repeat(10_000)).unwrap();

        // .Trash — small
        let trash = root.join(".Trash");
        fs::create_dir(&trash).unwrap();
        fs::write(trash.join("old_file.txt"), "y".repeat(100)).unwrap();

        let tree = scan(root);
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        assert!(result.items.len() >= 2, "should detect at least 2 items");
        assert!(
            result.items[0].total_size >= result.items[1].total_size,
            "items should be sorted by size descending"
        );
    }

    #[test]
    fn test_analyze_by_category() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        let nm = root.join("node_modules");
        fs::create_dir(&nm).unwrap();
        fs::write(nm.join("dep.js"), "x".repeat(1000)).unwrap();

        let tree = scan(root);
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        let grouped = result.by_category();
        assert!(
            grouped.contains_key(&Category::Developer),
            "grouped results should contain Category::Developer"
        );
    }

    #[test]
    fn test_analyze_empty_tree() {
        let dir = tempfile::tempdir().expect("tempdir");

        let tree = scan(dir.path());
        let registry = RuleRegistry::with_defaults();
        let result = analyze(&tree, &registry);

        assert_eq!(result.total_reclaimable, 0, "empty dir should have 0 reclaimable");
        assert!(result.items.is_empty(), "empty dir should have no items");
    }
}
