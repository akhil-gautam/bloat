use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::DefaultTerminal;

use crate::analyzer::{self, AnalysisResult};
use crate::rules::RuleRegistry;
use crate::scanner::{self, DiskStats, ScanProgress};
use crate::tree::{FsNode, FsTree};

// ---------------------------------------------------------------------------
// Tab enum
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Tab {
    Overview,
    Explorer,
    Cleanup,
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

pub struct App {
    pub tab: Tab,
    pub scan_path: PathBuf,
    pub disk_stats: Option<DiskStats>,
    pub tree: Option<FsTree>,
    pub analysis: Option<AnalysisResult>,
    pub scanning: bool,
    pub explorer: ExplorerState,
    pub cleanup: CleanupState,
    pub show_help: bool,
    pub should_quit: bool,
}

impl App {
    pub fn new(scan_path: PathBuf) -> Self {
        let disk_stats = scanner::disk_stats(&scan_path);
        Self {
            tab: Tab::Overview,
            scan_path,
            disk_stats,
            tree: None,
            analysis: None,
            scanning: false,
            explorer: ExplorerState::new(),
            cleanup: CleanupState::new(),
            show_help: false,
            should_quit: false,
        }
    }

    /// Starts an async scan. Returns the receiver end of the progress channel.
    pub fn start_scan(&mut self) -> mpsc::Receiver<ScanProgress> {
        self.scanning = true;
        self.tree = None;
        self.analysis = None;

        let (tx, rx) = mpsc::channel();
        scanner::scan_async(self.scan_path.clone(), tx);
        rx
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
        // Global keys
        match key.code {
            KeyCode::Char('q') => {
                self.should_quit = true;
                return;
            }
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.should_quit = true;
                return;
            }
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
            KeyCode::Tab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Explorer,
                    Tab::Explorer => Tab::Cleanup,
                    Tab::Cleanup => Tab::Overview,
                };
                return;
            }
            KeyCode::BackTab => {
                self.tab = match self.tab {
                    Tab::Overview => Tab::Cleanup,
                    Tab::Explorer => Tab::Overview,
                    Tab::Cleanup => Tab::Explorer,
                };
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
        }
    }

    fn on_key_overview(&mut self, _key: KeyEvent) {
        // no-op for now
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
            _ => {}
        }
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

pub fn run(mut terminal: DefaultTerminal, mut app: App) -> std::io::Result<()> {
    // Start scanning immediately on launch
    let mut rx = Some(app.start_scan());

    loop {
        // Draw
        terminal.draw(|frame| {
            crate::ui::draw(frame, &app);
        })?;

        // Poll scan progress
        if let Some(receiver) = &rx {
            match receiver.try_recv() {
                Ok(ScanProgress::Done(tree)) => {
                    app.on_scan_complete(tree);
                    rx = None;
                }
                Ok(ScanProgress::Error(path, msg)) => {
                    // Log error but keep scanning flag — the Done message
                    // will eventually arrive (or not).
                    eprintln!("Scan error at {}: {}", path.display(), msg);
                }
                Ok(ScanProgress::Scanning(_)) | Err(mpsc::TryRecvError::Empty) => {
                    // still scanning or no new message yet
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    // Sender dropped without Done — treat as finished
                    app.scanning = false;
                    rx = None;
                }
            }
        }

        // Poll keyboard input at ~30fps
        if event::poll(std::time::Duration::from_millis(33))? {
            if let Event::Key(key) = event::read()? {
                app.on_key(key);
            }
        }

        if app.should_quit {
            break;
        }
    }

    Ok(())
}
