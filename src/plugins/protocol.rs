//! Protocol types for the external (script-based) plugin system.
//!
//! External plugins are shell scripts that receive a JSON tick message and
//! return a JSON panel response. This module defines the types used for that
//! communication. The `PluginManager` manages loading and running them.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Messages sent TO plugins
// ---------------------------------------------------------------------------

/// Per-process summary sent with each tick.
#[derive(Debug, Clone, Serialize)]
pub struct ProcessBrief {
    pub pid: u32,
    pub name: String,
    pub cpu: f32,
    pub mem: u64,
}

/// The tick message serialised to JSON and sent to each plugin's stdin.
#[derive(Debug, Clone, Serialize)]
pub struct TickMessage {
    pub r#type: String,
    pub cpu_total: f32,
    pub mem_used: u64,
    pub mem_total: u64,
    pub processes: Vec<ProcessBrief>,
}

// ---------------------------------------------------------------------------
// Messages received FROM plugins
// ---------------------------------------------------------------------------

/// A single row of text in a plugin panel.
#[derive(Debug, Clone, Deserialize)]
pub struct PanelRow {
    pub text: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub bold: bool,
}

/// The panel response returned by a plugin (parsed from JSON on stdout).
#[derive(Debug, Clone, Deserialize)]
pub struct PanelResponse {
    pub title: String,
    #[serde(default)]
    pub rows: Vec<PanelRow>,
    #[serde(default)]
    pub color: Option<String>,
}

// ---------------------------------------------------------------------------
// Plugin manager
// ---------------------------------------------------------------------------

/// Manages external script-based plugins.
///
/// Each plugin is a script that reads a JSON `TickMessage` from stdin and
/// writes a JSON `PanelResponse` to stdout. Scripts are discovered from
/// `~/.config/bloat/plugins/` (executable files ending in `.sh` or any
/// executable without extension).
pub struct PluginManager {
    plugin_paths: Vec<std::path::PathBuf>,
    cached_responses: Vec<PanelResponse>,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugin_paths: Vec::new(),
            cached_responses: Vec::new(),
        }
    }

    /// Discover plugin scripts in `~/.config/bloat/plugins/`.
    pub fn load_from_dir(&mut self) {
        let dir = match dirs::home_dir() {
            Some(h) => h.join(".config/bloat/plugins"),
            None => return,
        };
        if !dir.exists() {
            return;
        }
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                // Check if executable
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(meta) = path.metadata() {
                        if meta.permissions().mode() & 0o111 != 0 {
                            self.plugin_paths.push(path);
                        }
                    }
                }
                #[cfg(not(unix))]
                {
                    self.plugin_paths.push(path);
                }
            }
        }
    }

    /// Called on each UI tick while on the System tab. Runs each plugin
    /// script with the tick message and updates cached responses.
    pub fn tick(&mut self, msg: &TickMessage) {
        if self.plugin_paths.is_empty() {
            return;
        }
        let json = match serde_json::to_string(msg) {
            Ok(j) => j,
            Err(_) => return,
        };
        let mut responses = Vec::new();
        for path in &self.plugin_paths {
            use std::io::Write;
            let mut child = match std::process::Command::new(path)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()
            {
                Ok(c) => c,
                Err(_) => continue,
            };
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(json.as_bytes());
            }
            let output = match child.wait_with_output() {
                Ok(o) => o,
                Err(_) => continue,
            };
            let text = String::from_utf8_lossy(&output.stdout);
            if let Ok(resp) = serde_json::from_str::<PanelResponse>(text.trim()) {
                responses.push(resp);
            }
        }
        self.cached_responses = responses;
    }

    /// Returns references to the most recently computed panel responses.
    pub fn responses(&self) -> Vec<&PanelResponse> {
        self.cached_responses.iter().collect()
    }
}

impl Default for PluginManager {
    fn default() -> Self {
        Self::new()
    }
}
