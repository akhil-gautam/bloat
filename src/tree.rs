use std::path::PathBuf;

/// A single node in the filesystem tree — either a file or a directory.
#[derive(Debug, Clone)]
pub struct FsNode {
    pub name: String,
    pub path: PathBuf,
    pub size: u64,
    pub is_dir: bool,
    pub children: Vec<FsNode>,
}

impl FsNode {
    pub fn new_file(name: String, path: PathBuf, size: u64) -> Self {
        Self {
            name,
            path,
            size,
            is_dir: false,
            children: Vec::new(),
        }
    }

    pub fn new_dir(name: String, path: PathBuf) -> Self {
        Self {
            name,
            path,
            size: 0,
            is_dir: true,
            children: Vec::new(),
        }
    }

    /// Add a child node and update this directory's size.
    pub fn add_child(&mut self, child: FsNode) {
        self.size += child.size;
        self.children.push(child);
    }

    /// Sort children by size descending.
    pub fn sort_by_size(&mut self) {
        self.children.sort_by(|a, b| b.size.cmp(&a.size));
        for child in &mut self.children {
            child.sort_by_size();
        }
    }

    /// Count total number of nodes (including self).
    pub fn node_count(&self) -> usize {
        1 + self.children.iter().map(|c| c.node_count()).sum::<usize>()
    }
}

/// The full filesystem tree with metadata.
#[derive(Debug)]
pub struct FsTree {
    pub root: FsNode,
    pub skipped_paths: Vec<PathBuf>,
}

impl FsTree {
    pub fn new(root: FsNode) -> Self {
        Self {
            root,
            skipped_paths: Vec::new(),
        }
    }

    /// Get total size of the tree.
    pub fn total_size(&self) -> u64 {
        self.root.size
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_file() {
        let f = FsNode::new_file("hello.txt".into(), PathBuf::from("/tmp/hello.txt"), 1024);
        assert_eq!(f.name, "hello.txt");
        assert_eq!(f.size, 1024);
        assert!(!f.is_dir);
        assert!(f.children.is_empty());
    }

    #[test]
    fn test_new_dir_with_children() {
        let mut dir = FsNode::new_dir("mydir".into(), PathBuf::from("/tmp/mydir"));
        let f1 = FsNode::new_file("a.txt".into(), PathBuf::from("/tmp/mydir/a.txt"), 100);
        let f2 = FsNode::new_file("b.txt".into(), PathBuf::from("/tmp/mydir/b.txt"), 200);
        dir.add_child(f1);
        dir.add_child(f2);

        assert_eq!(dir.size, 300);
        assert_eq!(dir.children.len(), 2);
    }

    #[test]
    fn test_sort_by_size() {
        let mut dir = FsNode::new_dir("root".into(), PathBuf::from("/tmp/root"));
        dir.add_child(FsNode::new_file("small.txt".into(), PathBuf::from("/tmp/root/small.txt"), 10));
        dir.add_child(FsNode::new_file("big.txt".into(), PathBuf::from("/tmp/root/big.txt"), 1000));
        dir.add_child(FsNode::new_file("med.txt".into(), PathBuf::from("/tmp/root/med.txt"), 500));
        dir.sort_by_size();

        assert_eq!(dir.children[0].name, "big.txt");
        assert_eq!(dir.children[1].name, "med.txt");
        assert_eq!(dir.children[2].name, "small.txt");
    }

    #[test]
    fn test_node_count() {
        let mut dir = FsNode::new_dir("root".into(), PathBuf::from("/root"));
        let mut sub = FsNode::new_dir("sub".into(), PathBuf::from("/root/sub"));
        sub.add_child(FsNode::new_file("f.txt".into(), PathBuf::from("/root/sub/f.txt"), 50));
        dir.add_child(sub);
        dir.add_child(FsNode::new_file("g.txt".into(), PathBuf::from("/root/g.txt"), 100));

        assert_eq!(dir.node_count(), 4);
    }

    #[test]
    fn test_fs_tree_total_size() {
        let mut root = FsNode::new_dir("root".into(), PathBuf::from("/root"));
        root.add_child(FsNode::new_file("a.txt".into(), PathBuf::from("/root/a.txt"), 500));
        root.add_child(FsNode::new_file("b.txt".into(), PathBuf::from("/root/b.txt"), 300));
        let tree = FsTree::new(root);

        assert_eq!(tree.total_size(), 800);
    }
}
