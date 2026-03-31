use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;

use crate::analyzer::{self, AnalysisResult};
use crate::rules::RuleRegistry;
use crate::scanner::{self, DiskStats, ScanProgress};
use crate::tree::{FsNode, FsTree};

// ---------------------------------------------------------------------------
// Screen / Tab enums
// ---------------------------------------------------------------------------

/// Top-level screen — folder selection happens before the main TUI.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Screen {
    FolderSelect,
    Main,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Tab {
    Overview,
    Explorer,
    Cleanup,
    Logs,
}

// ---------------------------------------------------------------------------
// OverviewState
// ---------------------------------------------------------------------------

pub struct OverviewState {
    pub selected: usize,
    pub checked: HashSet<usize>,
}

impl OverviewState {
    pub fn new() -> Self {
        Self {
            selected: 0,
            checked: HashSet::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Deletion log
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct LogEntry {
    pub timestamp: String,
    pub name: String,
    pub size: u64,
    pub method: String, // "Trash" or "Permanent"
    pub success: bool,
    pub error: Option<String>,
}

// ---------------------------------------------------------------------------
// FolderSelectState
// ---------------------------------------------------------------------------

/// A selectable folder entry.
#[derive(Debug, Clone)]
pub struct FolderEntry {
    pub name: String,
    pub path: PathBuf,
    pub checked: bool,
    pub exists: bool,
}

pub struct FolderSelectState {
    pub folders: Vec<FolderEntry>,
    pub selected: usize,
}

impl FolderSelectState {
    pub fn new(home: &PathBuf) -> Self {
        let candidates = vec![
            ("Desktop", home.join("Desktop")),
            ("Downloads", home.join("Downloads")),
            ("Documents", home.join("Documents")),
            ("Movies", home.join("Movies")),
            ("Music", home.join("Music")),
            ("Pictures", home.join("Pictures")),
            ("Library", home.join("Library")),
            ("Applications", home.join("Applications")),
            ("Developer", home.join("Developer")),
            ("projects", home.join("projects")),
            ("Entire Home Directory", home.clone()),
        ];

        let folders: Vec<FolderEntry> = candidates
            .into_iter()
            .map(|(name, path)| {
                let exists = path.exists();
                FolderEntry {
                    name: name.to_string(),
                    path,
                    checked: false,
                    exists,
                }
            })
            .collect();

        Self {
            folders,
            selected: 0,
        }
    }

    /// Return paths of all checked folders, or home if "Entire Home" is checked.
    pub fn selected_paths(&self) -> Vec<PathBuf> {
        // If "Entire Home Directory" (last item) is checked, just return home
        if let Some(last) = self.folders.last() {
            if last.checked {
                return vec![last.path.clone()];
            }
        }
        self.folders
            .iter()
            .filter(|f| f.checked && f.exists)
            .map(|f| f.path.clone())
            .collect()
    }
}

// ---------------------------------------------------------------------------
// ExplorerState
// ---------------------------------------------------------------------------

pub struct ExplorerState {
    pub selected: usize,
    pub expanded: HashSet<PathBuf>,
    pub search: Option<String>,
}

impl ExplorerState {
    pub fn new() -> Self {
        Self {
            selected: 0,
            expanded: HashSet::new(),
            search: None,
        }
    }
}

// ---------------------------------------------------------------------------
// CleanupState
// ---------------------------------------------------------------------------

pub struct CleanupState {
    pub selected: usize,
    pub checked: HashSet<usize>,
}

impl CleanupState {
    pub fn new() -> Self {
        Self {
            selected: 0,
            checked: HashSet::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

/// Live stats from an in-progress scan.
#[derive(Debug, Clone, Default)]
pub struct ScanStats {
    pub files_found: u64,
    pub dirs_found: u64,
    pub bytes_found: u64,
    pub current_dir: String,
}

pub struct App {
    pub screen: Screen,
    pub tab: Tab,
    pub scan_path: PathBuf,
    pub disk_stats: Option<DiskStats>,
    pub tree: Option<FsTree>,
    pub analysis: Option<AnalysisResult>,
    pub scanning: bool,
    pub scan_stats: ScanStats,
    pub scan_cancel: Arc<AtomicBool>,
    pub folder_select: FolderSelectState,
    pub overview: OverviewState,
    pub explorer: ExplorerState,
    pub cleanup: CleanupState,
    pub show_help: bool,
    pub should_quit: bool,
    pub last_clean_result: Option<Vec<crate::cleaner::CleanResult>>,
    pub logs: Vec<LogEntry>,
}

impl App {
    pub fn new(scan_path: PathBuf) -> Self {
        let disk_stats = scanner::disk_stats(&scan_path);
        let folder_select = FolderSelectState::new(&scan_path);
        Self {
            screen: Screen::FolderSelect,
            tab: Tab::Overview,
            scan_path,
            disk_stats,
            tree: None,
            analysis: None,
            scanning: false,
            scan_stats: ScanStats::default(),
            scan_cancel: Arc::new(AtomicBool::new(false)),
            folder_select,
            overview: OverviewState::new(),
            explorer: ExplorerState::new(),
            cleanup: CleanupState::new(),
            show_help: false,
            should_quit: false,
            last_clean_result: None,
            logs: Vec::new(),
        }
    }

    /// Starts an async scan. Returns the receiver end of the progress channel.
    pub fn start_scan(&mut self) -> mpsc::Receiver<ScanProgress> {
        self.scanning = true;
        self.tree = None;
        self.analysis = None;
        self.scan_stats = ScanStats::default();
        self.scan_cancel = Arc::new(AtomicBool::new(false));

        let (tx, rx) = mpsc::channel();
        scanner::scan_async(self.scan_path.clone(), tx, self.scan_cancel.clone());
        rx
    }

    /// Cancel the current scan.
    pub fn cancel_scan(&mut self) {
        self.scan_cancel.store(true, Ordering::Relaxed);
    }

    /// Start scanning the selected folders. Merges multiple paths into one scan
    /// by picking the common parent or scanning the home dir.
    pub fn start_selected_scan(&mut self) -> Option<mpsc::Receiver<ScanProgress>> {
        let paths = self.folder_select.selected_paths();
        if paths.is_empty() {
            return None;
        }
        // For simplicity, if multiple folders selected, scan from home dir
        // but in the future we could do multiple scans and merge.
        // For now: if exactly one path, scan it. Otherwise scan home.
        if paths.len() == 1 {
            self.scan_path = paths[0].clone();
        }
        // else scan_path stays as home dir (default)
        self.disk_stats = scanner::disk_stats(&self.scan_path);
        self.screen = Screen::Main;
        Some(self.start_scan())
    }

    /// Called when the background scan completes with the resulting tree.
    pub fn on_scan_complete(&mut self, tree: FsTree) {
        let registry = RuleRegistry::with_defaults();
        self.analysis = Some(analyzer::analyze(&tree, &registry));
        self.tree = Some(tree);
        self.scanning = false;
    }

    /// Dispatch a key event to the appropriate handler.
    pub fn on_key(&mut self, key: KeyEvent) {
        // Quit keys always work
        match key.code {
            KeyCode::Char('q') if self.screen == Screen::Main => {
                self.should_quit = true;
                return;
            }
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.should_quit = true;
                return;
            }
            _ => {}
        }

        // Folder selection screen
        if self.screen == Screen::FolderSelect {
            self.on_key_folder_select(key);
            return;
        }

        // Esc cancels scan
        if key.code == KeyCode::Esc && self.scanning {
            self.cancel_scan();
            return;
        }

        // Global keys (main screen)
        match key.code {
            KeyCode::Char('?') => {
                self.show_help = !self.show_help;
                return;
            }
            KeyCode::Char('1') => {
                self.tab = Tab::Overview;
                return;
            }
            KeyCode::Char('2') => {
                self.tab = Tab::Explorer;
                return;
            }
            KeyCode::Char('3') => {
                self.tab = Tab::Cleanup;
                return;
            }
            KeyCode::Char('4') => {
                self.tab = Tab::Logs;
                return;
            }
            KeyCode::Tab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Explorer,
                    Tab::Explorer => Tab::Cleanup,
                    Tab::Cleanup => Tab::Logs,
                    Tab::Logs => Tab::Overview,
                };
                return;
            }
            KeyCode::BackTab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Logs,
                    Tab::Explorer => Tab::Overview,
                    Tab::Cleanup => Tab::Explorer,
                    Tab::Logs => Tab::Cleanup,
                };
                return;
            }
            KeyCode::Char('r') => {
                if !self.scanning {
                    self.scanning = true;
                    self.tree = None;
                    self.analysis = None;
                }
                return;
            }
            _ => {}
        }

        // If help overlay is showing, any other key closes it
        if self.show_help {
            self.show_help = false;
            return;
        }

        // Tab-specific keys
        match self.tab {
            Tab::Overview => self.on_key_overview(key),
            Tab::Explorer => self.on_key_explorer(key),
            Tab::Cleanup => self.on_key_cleanup(key),
            Tab::Logs => {} // Logs is read-only
        }
    }

    fn on_key_folder_select(&mut self, key: KeyEvent) {
        let count = self.folder_select.folders.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.folder_select.selected > 0 {
                    self.folder_select.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.folder_select.selected + 1 < count {
                    self.folder_select.selected += 1;
                }
            }
            KeyCode::Char(' ') => {
                let idx = self.folder_select.selected;
                let is_last = idx == count - 1; // "Entire Home Directory"
                if is_last {
                    // Toggle entire home — uncheck all others
                    let checked = !self.folder_select.folders[idx].checked;
                    for f in &mut self.folder_select.folders {
                        f.checked = false;
                    }
                    self.folder_select.folders[idx].checked = checked;
                } else {
                    self.folder_select.folders[idx].checked =
                        !self.folder_select.folders[idx].checked;
                    // Uncheck "Entire Home" if a specific folder is checked
                    if let Some(last) = self.folder_select.folders.last_mut() {
                        last.checked = false;
                    }
                }
            }
            KeyCode::Char('a') => {
                // Select all individual folders (not "entire home")
                let all_checked = self.folder_select.folders[..count - 1]
                    .iter()
                    .filter(|f| f.exists)
                    .all(|f| f.checked);
                for f in &mut self.folder_select.folders[..count - 1] {
                    f.checked = !all_checked && f.exists;
                }
                if let Some(last) = self.folder_select.folders.last_mut() {
                    last.checked = false;
                }
            }
            KeyCode::Enter => {
                // Start scan if anything is selected
                // This is handled by the run loop checking a flag
            }
            KeyCode::Char('q') => {
                self.should_quit = true;
            }
            _ => {}
        }
    }

    fn on_key_overview(&mut self, key: KeyEvent) {
        let count = self.tree.as_ref().map_or(0, |t| t.root.children.len().min(5));
        if count == 0 {
            return;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.overview.selected > 0 {
                    self.overview.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.overview.selected + 1 < count {
                    self.overview.selected += 1;
                }
            }
            KeyCode::Char(' ') => {
                let idx = self.overview.selected;
                if self.overview.checked.contains(&idx) {
                    self.overview.checked.remove(&idx);
                } else {
                    self.overview.checked.insert(idx);
                }
            }
            KeyCode::Char('d') | KeyCode::Enter => {
                self.delete_overview_selected();
            }
            _ => {}
        }
    }

    fn delete_overview_selected(&mut self) {
        if self.overview.checked.is_empty() {
            return;
        }

        let tree = match &self.tree {
            Some(t) => t,
            None => return,
        };

        let top: Vec<_> = tree.root.children.iter().take(5).collect();
        let indices: Vec<usize> = self.overview.checked.iter().cloned().collect();
        let now = chrono_now();

        for &idx in &indices {
            if let Some(node) = top.get(idx) {
                let item = crate::rules::CleanupItem {
                    name: node.name.clone(),
                    paths: vec![node.path.clone()],
                    total_size: node.size,
                    description: "Deleted from Overview".to_string(),
                    impact: "".to_string(),
                    category: crate::rules::Category::System,
                    safety: crate::rules::Safety::Caution,
                };
                let method = crate::cleaner::DeleteMethod::Trash;
                let result = crate::cleaner::clean_item(&item, method);

                self.logs.push(LogEntry {
                    timestamp: now.clone(),
                    name: node.name.clone(),
                    size: node.size,
                    method: "Trash".to_string(),
                    success: result.paths_failed.is_empty(),
                    error: result.paths_failed.first().map(|(_, e)| e.clone()),
                });
            }
        }

        self.overview.checked.clear();
        self.overview.selected = 0;
        // Trigger rescan
        self.scanning = true;
        self.tree = None;
        self.analysis = None;
    }

    fn on_key_explorer(&mut self, key: KeyEvent) {
        let count = self.explorer_visible_count();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.explorer.selected > 0 {
                    self.explorer.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if count > 0 && self.explorer.selected < count - 1 {
                    self.explorer.selected += 1;
                }
            }
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => {
                if let Some(path) = self.explorer_selected_path() {
                    self.explorer.expanded.insert(path);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                if let Some(path) = self.explorer_selected_path() {
                    self.explorer.expanded.remove(&path);
                }
            }
            _ => {}
        }
    }

    fn on_key_cleanup(&mut self, key: KeyEvent) {
        let count = self
            .analysis
            .as_ref()
            .map(|a| a.items.len())
            .unwrap_or(0);

        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if self.cleanup.selected > 0 {
                    self.cleanup.selected -= 1;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if count > 0 && self.cleanup.selected < count - 1 {
                    self.cleanup.selected += 1;
                }
            }
            KeyCode::Char(' ') => {
                let idx = self.cleanup.selected;
                if self.cleanup.checked.contains(&idx) {
                    self.cleanup.checked.remove(&idx);
                } else {
                    self.cleanup.checked.insert(idx);
                }
            }
            KeyCode::Char('a') => {
                if self.cleanup.checked.len() == count {
                    // All checked — uncheck all
                    self.cleanup.checked.clear();
                } else {
                    // Check all
                    self.cleanup.checked = (0..count).collect();
                }
            }
            KeyCode::Enter => {
                self.execute_cleanup();
            }
            _ => {}
        }
    }

    fn execute_cleanup(&mut self) {
        let analysis = match &self.analysis {
            Some(a) => a,
            None => return,
        };
        if self.cleanup.checked.is_empty() {
            return;
        }
        let mut results = Vec::new();
        let indices: Vec<usize> = self.cleanup.checked.iter().cloned().collect();
        let now = chrono_now();
        for &idx in &indices {
            if let Some(item) = analysis.items.get(idx) {
                let method = crate::cleaner::default_method(item.safety);
                let result = crate::cleaner::clean_item(item, method);
                self.logs.push(LogEntry {
                    timestamp: now.clone(),
                    name: item.name.clone(),
                    size: item.total_size,
                    method: format!("{:?}", method),
                    success: result.paths_failed.is_empty(),
                    error: result.paths_failed.first().map(|(_, e)| e.clone()),
                });
                results.push(result);
            }
        }
        self.last_clean_result = Some(results);
        self.cleanup.checked.clear();
        // Trigger rescan
        self.scanning = true;
        self.tree = None;
        self.analysis = None;
    }

    // -----------------------------------------------------------------------
    // Explorer helpers
    // -----------------------------------------------------------------------

    /// Count the number of visible items in the explorer tree.
    pub fn explorer_visible_count(&self) -> usize {
        match &self.tree {
            None => 0,
            Some(tree) => self.count_visible(&tree.root),
        }
    }

    fn count_visible(&self, node: &FsNode) -> usize {
        // The node itself is visible
        let mut count = 1;
        if node.is_dir && self.explorer.expanded.contains(&node.path) {
            for child in &node.children {
                count += self.count_visible(child);
            }
        }
        count
    }

    /// Get the path of the currently selected item in the explorer.
    pub fn explorer_selected_path(&self) -> Option<PathBuf> {
        let tree = self.tree.as_ref()?;
        self.find_by_index(&tree.root, self.explorer.selected, &mut 0)
    }

    fn find_by_index(&self, node: &FsNode, target: usize, current: &mut usize) -> Option<PathBuf> {
        if *current == target {
            return Some(node.path.clone());
        }
        *current += 1;

        if node.is_dir && self.explorer.expanded.contains(&node.path) {
            for child in &node.children {
                if let Some(path) = self.find_by_index(child, target, current) {
                    return Some(path);
                }
            }
        }

        None
    }
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

/// Simple timestamp without pulling in chrono crate.
fn chrono_now() -> String {
    use std::process::Command;
    Command::new("date")
        .arg("+%H:%M:%S")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "??:??:??".to_string())
}

pub fn run(mut terminal: DefaultTerminal, mut app: App) -> std::io::Result<()> {
    let mut rx: Option<mpsc::Receiver<ScanProgress>> = None;

    loop {
        // If scanning requested but no active receiver, start a scan.
        // This handles: 'r' key, post-cleanup rescan, post-delete rescan.
        if app.scanning && app.tree.is_none() && rx.is_none() {
            rx = Some(app.start_scan());
        }

        terminal.draw(|frame| crate::ui::draw(frame, &app))?;

        // Drain scan progress if scanning
        if app.scanning {
            if let Some(ref receiver) = rx {
                loop {
                    match receiver.try_recv() {
                        Ok(ScanProgress::Done(tree)) => {
                            app.on_scan_complete(tree);
                            break;
                        }
                        Ok(ScanProgress::Progress {
                            files_found,
                            dirs_found,
                            bytes_found,
                            current_dir,
                        }) => {
                            app.scan_stats = ScanStats {
                                files_found,
                                dirs_found,
                                bytes_found,
                                current_dir,
                            };
                        }
                        Ok(ScanProgress::Error(_, _)) => {}
                        Err(mpsc::TryRecvError::Disconnected) => {
                            // Scanner thread ended — clear receiver
                            app.scanning = false;
                            rx = None;
                            break;
                        }
                        Err(mpsc::TryRecvError::Empty) => break,
                    }
                }
            }
        }

        if event::poll(std::time::Duration::from_millis(33))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == crossterm::event::KeyEventKind::Press {
                    let was_folder_select = app.screen == Screen::FolderSelect;
                    app.on_key(key);

                    // Enter on folder select → start scanning
                    if was_folder_select && key.code == KeyCode::Enter {
                        if let Some(new_rx) = app.start_selected_scan() {
                            rx = Some(new_rx);
                        }
                    }

                    // If a rescan was requested (cleanup, delete, 'r'),
                    // clear the old receiver so the top-of-loop logic starts a new one.
                    if app.scanning && app.tree.is_none() {
                        rx = None;
                    }
                }
            }
        }

        if app.should_quit {
            break;
        }
    }

    Ok(())
}
