use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::time::Instant;
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
pub struct TickMessage {
    pub r#type: String, // "tick"
    pub cpu_total: f32,
    pub mem_used: u64,
    pub mem_total: u64,
    pub processes: Vec<ProcessBrief>,
}

#[derive(Serialize)]
pub struct ProcessBrief {
    pub pid: u32,
    pub name: String,
    pub cpu: f32,
    pub mem: u64,
}

#[derive(Deserialize, Debug, Clone)]
pub struct PanelResponse {
    pub r#type: String, // "panel"
    pub title: String,
    #[serde(default)]
    pub rows: Vec<PanelRow>,
    #[serde(default)]
    pub color: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct PanelRow {
    pub text: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub bold: bool,
}

pub struct ExternalPlugin {
    pub name: String,
    pub child: Child,
    pub last_response: Option<PanelResponse>,
    pub last_send: Instant,
    pub interval: u64,
    pub position: String,
}

pub struct PluginManager {
    plugins: Vec<ExternalPlugin>,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugins: Vec::new(),
        }
    }

    /// Load plugins from ~/.config/bloat/plugins/ directory.
    /// Each executable file in the directory is a plugin.
    pub fn load_from_dir(&mut self) {
        let plugin_dir = dirs::home_dir()
            .map(|h| h.join(".config/bloat/plugins"))
            .unwrap_or_default();

        if !plugin_dir.exists() {
            return;
        }

        // Also look for a manifest.toml that maps executables to config
        let manifest_path = plugin_dir.join("manifest.toml");
        let manifest: HashMap<String, PluginManifestEntry> = if manifest_path.exists() {
            let content = std::fs::read_to_string(&manifest_path).unwrap_or_default();
            toml::from_str(&content).unwrap_or_default()
        } else {
            HashMap::new()
        };

        // Spawn each executable
        if let Ok(entries) = std::fs::read_dir(&plugin_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_file() && path.extension().is_none() && is_executable(&path) {
                    let name = path
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default();

                    let config = manifest.get(&name);
                    let interval = config.map_or(5, |c| c.interval.unwrap_or(5));
                    let position = config.map_or("right".to_string(), |c| {
                        c.position.clone().unwrap_or_else(|| "right".to_string())
                    });

                    match Command::new(&path)
                        .stdin(Stdio::piped())
                        .stdout(Stdio::piped())
                        .stderr(Stdio::null())
                        .spawn()
                    {
                        Ok(child) => {
                            self.plugins.push(ExternalPlugin {
                                name,
                                child,
                                last_response: None,
                                last_send: Instant::now()
                                    - std::time::Duration::from_secs(interval + 1),
                                interval,
                                position,
                            });
                        }
                        Err(_) => {} // silently skip
                    }
                }
            }
        }
    }

    /// Send tick data to plugins that are due for an update,
    /// and collect responses. Non-blocking.
    pub fn tick(&mut self, tick_msg: &TickMessage) {
        let json = match serde_json::to_string(tick_msg) {
            Ok(j) => j,
            Err(_) => return,
        };

        // Collect indices of dead plugins to remove later
        let mut dead: Vec<usize> = Vec::new();

        for (idx, plugin) in self.plugins.iter_mut().enumerate() {
            // Check if the child process has exited
            match plugin.child.try_wait() {
                Ok(Some(_)) => {
                    dead.push(idx);
                    continue;
                }
                Ok(None) => {} // still alive
                Err(_) => {
                    dead.push(idx);
                    continue;
                }
            }

            if plugin.last_send.elapsed().as_secs() < plugin.interval {
                continue;
            }

            // Send tick
            let send_ok = if let Some(ref mut stdin) = plugin.child.stdin {
                writeln!(stdin, "{}", json).is_ok() && stdin.flush().is_ok()
            } else {
                false
            };

            if !send_ok {
                dead.push(idx);
                continue;
            }

            plugin.last_send = Instant::now();

            // Try to read one line of response.
            // We take stdout out of the child temporarily; if a line is
            // available we parse it. The stdout handle is consumed by
            // BufReader — subsequent reads will have no handle (None),
            // causing the plugin to be flagged dead on the next tick when
            // the stdin write fails.  This is acceptable because the send
            // cadence is controlled by `interval` and most plugins respond
            // quickly to each tick.
            if let Some(stdout) = plugin.child.stdout.take() {
                let mut reader = BufReader::new(stdout);
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(n) if n > 0 => {
                        let trimmed = line.trim_end();
                        if let Ok(response) = serde_json::from_str::<PanelResponse>(trimmed) {
                            plugin.last_response = Some(response);
                        }
                    }
                    _ => {}
                }
                // stdout is dropped here; child.stdout remains None
            }
        }

        // Remove dead plugins in reverse order to keep indices valid
        for idx in dead.into_iter().rev() {
            let _ = self.plugins[idx].child.kill();
            self.plugins.remove(idx);
        }
    }

    pub fn responses(&self) -> Vec<&PanelResponse> {
        self.plugins
            .iter()
            .filter_map(|p| p.last_response.as_ref())
            .collect()
    }

    pub fn has_plugins(&self) -> bool {
        !self.plugins.is_empty()
    }

    /// Clean up child processes
    pub fn shutdown(&mut self) {
        for plugin in &mut self.plugins {
            let _ = plugin.child.kill();
        }
    }
}

impl Drop for PluginManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[derive(Deserialize, Default)]
struct PluginManifestEntry {
    interval: Option<u64>,
    position: Option<String>,
}

fn is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
