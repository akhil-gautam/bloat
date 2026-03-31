use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};

use jwalk::WalkDir;

use crate::tree::{FsNode, FsTree};

/// Progress events emitted by the async scanner.
pub enum ScanProgress {
    /// Periodic update with stats about the ongoing scan.
    Progress {
        files_found: u64,
        dirs_found: u64,
        bytes_found: u64,
        current_dir: String,
    },
    Done(FsTree),
    Error(PathBuf, String),
}

/// Blocking filesystem scan rooted at `root`.
///
/// Walks the tree with jwalk, skips symlinks, builds an FsNode tree
/// bottom-up, sorts children by size, and returns an FsTree.
pub fn scan(root: &Path) -> FsTree {
    let mut nodes: HashMap<PathBuf, FsNode> = HashMap::new();
    let mut skipped: Vec<PathBuf> = Vec::new();
    let mut all_paths: Vec<PathBuf> = Vec::new();

    for entry_result in WalkDir::new(root).skip_hidden(false) {
        let entry = match entry_result {
            Ok(e) => e,
            Err(err) => {
                let path = err.path().map(|p| p.to_path_buf()).unwrap_or_else(|| root.to_path_buf());
                skipped.push(path);
                continue;
            }
        };

        let path = entry.path();

        // Skip symlinks
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => {
                skipped.push(path.clone());
                continue;
            }
        };

        if metadata.file_type().is_symlink() {
            skipped.push(path.clone());
            continue;
        }

        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());

        let node = if metadata.is_dir() {
            FsNode::new_dir(name, path.clone())
        } else {
            FsNode::new_file(name, path.clone(), metadata.len())
        };

        nodes.insert(path.clone(), node);
        all_paths.push(path);
    }

    // Sort paths by depth descending so children are processed before parents.
    all_paths.sort_by(|a, b| {
        let da = a.components().count();
        let db = b.components().count();
        db.cmp(&da)
    });

    // Assemble tree bottom-up: remove each node, attach it to its parent.
    for path in &all_paths {
        if let Some(parent) = path.parent() {
            if parent == path {
                // root has no real parent to attach to
                continue;
            }
            if nodes.contains_key(parent) {
                if let Some(child) = nodes.remove(path) {
                    if let Some(parent_node) = nodes.get_mut(parent) {
                        parent_node.add_child(child);
                    }
                }
            }
        }
    }

    // The root node should be the only remaining entry keyed by `root`.
    let mut root_node = nodes
        .remove(root)
        .unwrap_or_else(|| FsNode::new_dir(
            root.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| root.to_string_lossy().into_owned()),
            root.to_path_buf(),
        ));

    root_node.sort_by_size();

    let mut tree = FsTree::new(root_node);
    tree.skipped_paths = skipped;
    tree
}

/// Spawns a background thread that walks the filesystem, sends periodic
/// progress updates, and finally sends `Done` with the assembled tree.
/// Pass `cancel` flag — set it to `true` to stop the scan early.
pub fn scan_async(
    root: PathBuf,
    tx: mpsc::Sender<ScanProgress>,
    cancel: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut nodes: HashMap<PathBuf, FsNode> = HashMap::new();
        let mut skipped: Vec<PathBuf> = Vec::new();
        let mut all_paths: Vec<PathBuf> = Vec::new();

        let mut files_found: u64 = 0;
        let mut dirs_found: u64 = 0;
        let mut bytes_found: u64 = 0;
        let mut last_progress = std::time::Instant::now();

        for entry_result in WalkDir::new(&root).skip_hidden(false) {
            let entry = match entry_result {
                Ok(e) => e,
                Err(err) => {
                    let path = err
                        .path()
                        .map(|p| p.to_path_buf())
                        .unwrap_or_else(|| root.to_path_buf());
                    skipped.push(path);
                    continue;
                }
            };

            let path = entry.path();

            let metadata = match entry.metadata() {
                Ok(m) => m,
                Err(_) => {
                    skipped.push(path.clone());
                    continue;
                }
            };

            if metadata.file_type().is_symlink() {
                skipped.push(path.clone());
                continue;
            }

            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.to_string_lossy().into_owned());

            if metadata.is_dir() {
                dirs_found += 1;
                nodes.insert(path.clone(), FsNode::new_dir(name, path.clone()));
            } else {
                let size = metadata.len();
                files_found += 1;
                bytes_found += size;
                nodes.insert(path.clone(), FsNode::new_file(name, path.clone(), size));
            }
            all_paths.push(path.clone());

            // Check for cancellation
            if cancel.load(Ordering::Relaxed) {
                break;
            }

            // Send progress every 50ms
            if last_progress.elapsed() >= std::time::Duration::from_millis(50) {
                let current_dir = if metadata.is_dir() {
                    path.to_string_lossy().into_owned()
                } else {
                    path.parent()
                        .map(|p| p.to_string_lossy().into_owned())
                        .unwrap_or_default()
                };
                let _ = tx.send(ScanProgress::Progress {
                    files_found,
                    dirs_found,
                    bytes_found,
                    current_dir,
                });
                last_progress = std::time::Instant::now();
            }
        }

        // Send final progress before tree assembly
        let _ = tx.send(ScanProgress::Progress {
            files_found,
            dirs_found,
            bytes_found,
            current_dir: "Assembling tree...".to_string(),
        });

        // Assemble tree bottom-up
        all_paths.sort_by(|a, b| {
            let da = a.components().count();
            let db = b.components().count();
            db.cmp(&da)
        });

        for path in &all_paths {
            if let Some(parent) = path.parent() {
                if parent == path.as_path() {
                    continue;
                }
                if nodes.contains_key(parent) {
                    if let Some(child) = nodes.remove(path) {
                        if let Some(parent_node) = nodes.get_mut(parent) {
                            parent_node.add_child(child);
                        }
                    }
                }
            }
        }

        let mut root_node = nodes.remove(&root).unwrap_or_else(|| {
            FsNode::new_dir(
                root.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| root.to_string_lossy().into_owned()),
                root.to_path_buf(),
            )
        });

        root_node.sort_by_size();

        let mut tree = FsTree::new(root_node);
        tree.skipped_paths = skipped;
        let _ = tx.send(ScanProgress::Done(tree));
    })
}

/// Disk space statistics for a filesystem.
#[derive(Debug, Clone)]
pub struct DiskStats {
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub used_bytes: u64,
}

/// Returns disk statistics for the filesystem containing `path`, or `None`
/// if the syscall fails.
pub fn disk_stats(path: &Path) -> Option<DiskStats> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(path.as_os_str().as_bytes()).ok()?;

    // SAFETY: `buf` is properly initialised to zero and the pointer is valid.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };

    if ret != 0 {
        return None;
    }

    let block = stat.f_frsize as u64;
    let total_bytes = stat.f_blocks as u64 * block;
    let free_bytes = stat.f_bfree as u64 * block;
    let used_bytes = total_bytes.saturating_sub(free_bytes);

    Some(DiskStats {
        total_bytes,
        free_bytes,
        used_bytes,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    /// Creates the standard test tree:
    /// ```
    /// tmp/
    ///   file1.txt  (5 bytes)
    ///   subdir/
    ///     file2.txt  (6 bytes)
    ///     nested/
    ///       file3.txt  (2 bytes)
    /// ```
    /// Returns the TempDir (keep alive) and its path.
    fn create_test_tree() -> TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();

        fs::write(root.join("file1.txt"), "hello").unwrap(); // 5 bytes
        let subdir = root.join("subdir");
        fs::create_dir(&subdir).unwrap();
        fs::write(subdir.join("file2.txt"), "world!").unwrap(); // 6 bytes
        let nested = subdir.join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("file3.txt"), "ab").unwrap(); // 2 bytes

        dir
    }

    #[test]
    fn test_scan_counts_files() {
        let dir = create_test_tree();
        let tree = scan(dir.path());
        // root should have 2 direct children: file1.txt and subdir
        assert_eq!(tree.root.children.len(), 2);
    }

    #[test]
    fn test_scan_computes_sizes() {
        let dir = create_test_tree();
        let tree = scan(dir.path());
        assert_eq!(tree.total_size(), 13); // 5 + 6 + 2
    }

    #[test]
    fn test_scan_sorts_by_size() {
        let dir = create_test_tree();
        let tree = scan(dir.path());
        // subdir total = 8 bytes, file1.txt = 5 bytes => subdir comes first
        assert_eq!(tree.root.children[0].name, "subdir");
        assert_eq!(tree.root.children[1].name, "file1.txt");
    }

    #[test]
    fn test_scan_nested_dirs() {
        let dir = create_test_tree();
        let tree = scan(dir.path());

        let subdir = tree
            .root
            .children
            .iter()
            .find(|c| c.name == "subdir")
            .expect("subdir not found");

        assert_eq!(subdir.size, 8); // 6 + 2
        assert_eq!(subdir.children.len(), 2); // file2.txt + nested
    }

    #[test]
    fn test_scan_async_sends_done() {
        let dir = create_test_tree();
        let root = dir.path().to_path_buf();

        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        let handle = scan_async(root, tx, cancel);
        handle.join().expect("thread panicked");

        // Drain messages and look for a Done variant.
        let mut found_done = false;
        let mut total: u64 = 0;
        for msg in rx.try_iter() {
            match msg {
                ScanProgress::Done(tree) => {
                    found_done = true;
                    total = tree.total_size();
                }
                ScanProgress::Progress { .. } => {} // progress messages are fine
                ScanProgress::Error(_, _) => {}
            }
        }

        assert!(found_done, "Did not receive Done message");
        assert_eq!(total, 13);
    }

    #[test]
    fn test_disk_stats_returns_some() {
        let stats = disk_stats(Path::new("/")).expect("disk_stats('/') returned None");
        assert!(stats.total_bytes > 0, "total_bytes should be > 0");
    }
}
