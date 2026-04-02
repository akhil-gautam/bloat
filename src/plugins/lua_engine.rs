//! Lua scripting support for the plugin system.
//!
//! Lua scripts placed in `~/.config/bloat/lua/` define custom panels with
//! a `panel` metadata table and a `collect(data)` function. Each script runs
//! in its own isolated Lua VM to prevent global state pollution.

use std::path::PathBuf;
use std::time::Instant;

// ---------------------------------------------------------------------------
// Public output types
// ---------------------------------------------------------------------------

/// A single line of text rendered inside a Lua-defined panel.
#[derive(Debug, Clone)]
pub struct LuaPanelLine {
    pub text: String,
    pub color: Option<String>,
    pub bold: bool,
}

/// The full output produced by one Lua script after a `collect()` call.
#[derive(Debug, Clone)]
pub struct LuaPanel {
    pub name: String,
    pub lines: Vec<LuaPanelLine>,
    pub position: String,
    pub color: Option<String>,
}

// ---------------------------------------------------------------------------
// Internal per-script state
// ---------------------------------------------------------------------------

/// Everything needed to (re-)run a single Lua script.
struct LuaScript {
    /// Display name taken from the `panel.name` field.
    name: String,
    /// Refresh interval in seconds.
    interval: u64,
    /// Layout position: "left" or "right".
    position: String,
    /// Optional panel border colour.
    color: Option<String>,
    /// The compiled Lua source, kept so the VM can be recreated on demand.
    source: String,
    /// When this script was last executed.
    last_run: Instant,
}

// ---------------------------------------------------------------------------
// LuaEngine
// ---------------------------------------------------------------------------

/// Manages a collection of Lua scripts, each in its own VM.
pub struct LuaEngine {
    scripts: Vec<LuaScript>,
    outputs: Vec<LuaPanel>,
}

impl LuaEngine {
    pub fn new() -> Self {
        Self {
            scripts: Vec::new(),
            outputs: Vec::new(),
        }
    }

    /// Discover and load all `*.lua` files from `~/.config/bloat/lua/`.
    pub fn load_scripts(&mut self) {
        let lua_dir = match dirs::home_dir() {
            Some(h) => h.join(".config/bloat/lua"),
            None => return,
        };

        if !lua_dir.exists() {
            return;
        }

        let entries = match std::fs::read_dir(&lua_dir) {
            Ok(e) => e,
            Err(_) => return,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |e| e == "lua") {
                self.load_script(&path);
            }
        }
    }

    /// Parse a single Lua script file and register it.
    fn load_script(&mut self, path: &PathBuf) {
        let source = match std::fs::read_to_string(path) {
            Ok(s) => s,
            Err(_) => return,
        };

        let file_stem = path
            .file_stem()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        // Create a throw-away VM just to read the `panel` metadata table.
        let lua = mlua::Lua::new();

        if lua.load(&source).set_name(&file_stem).exec().is_err() {
            // Script has a syntax/runtime error at load time — skip silently.
            return;
        }

        let panel_table: mlua::Table = match lua.globals().get("panel") {
            Ok(t) => t,
            Err(_) => return, // `panel` global not defined
        };

        let name: String = panel_table
            .get("name")
            .unwrap_or_else(|_| file_stem.clone());
        let interval: u64 = panel_table.get("interval").unwrap_or(5);
        let position: String = panel_table
            .get("position")
            .unwrap_or_else(|_| "right".to_string());
        let color: Option<String> = panel_table.get("color").ok();

        // Seed last_run far enough in the past so the first tick fires immediately.
        let last_run = Instant::now()
            .checked_sub(std::time::Duration::from_secs(interval + 1))
            .unwrap_or_else(Instant::now);

        self.scripts.push(LuaScript {
            name,
            interval,
            position,
            color,
            source,
            last_run,
        });
    }

    // ---------------------------------------------------------------------------
    // Tick
    // ---------------------------------------------------------------------------

    /// Run any scripts whose interval has elapsed, then return all current outputs.
    ///
    /// `processes` is a slice of `(pid, name, cpu_percent, mem_bytes)`.
    pub fn tick(
        &mut self,
        cpu_total: f32,
        mem_used: u64,
        mem_total: u64,
        processes: &[(u32, String, f32, u64)],
    ) -> &[LuaPanel] {
        for script in &mut self.scripts {
            if script.last_run.elapsed().as_secs() < script.interval {
                continue;
            }

            // Create a fresh Lua VM for this script execution.
            let lua = mlua::Lua::new();

            // Load the script source to define `panel` + `collect`.
            if lua
                .load(&script.source)
                .set_name(&script.name)
                .exec()
                .is_err()
            {
                script.last_run = Instant::now();
                continue;
            }

            // Build the data table and call collect().
            let lines = match build_and_call(&lua, cpu_total, mem_used, mem_total, processes) {
                Some(l) => l,
                None => {
                    script.last_run = Instant::now();
                    continue;
                }
            };

            // Update or insert the output panel for this script.
            let panel = LuaPanel {
                name: script.name.clone(),
                lines,
                position: script.position.clone(),
                color: script.color.clone(),
            };

            if let Some(existing) = self.outputs.iter_mut().find(|p| p.name == script.name) {
                *existing = panel;
            } else {
                self.outputs.push(panel);
            }

            script.last_run = Instant::now();
        }

        &self.outputs
    }

    pub fn outputs(&self) -> &[LuaPanel] {
        &self.outputs
    }

    pub fn has_scripts(&self) -> bool {
        !self.scripts.is_empty()
    }
}

impl Default for LuaEngine {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build the `data` table, call `collect(data)`, and parse the returned lines.
/// Returns `None` on any Lua error (errors are swallowed so we never panic).
fn build_and_call(
    lua: &mlua::Lua,
    cpu_total: f32,
    mem_used: u64,
    mem_total: u64,
    processes: &[(u32, String, f32, u64)],
) -> Option<Vec<LuaPanelLine>> {
    // --- Build data table ---
    let data = lua.create_table().ok()?;
    data.set("cpu_total", cpu_total).ok()?;
    data.set("mem_used", mem_used).ok()?;
    data.set("mem_total", mem_total).ok()?;

    let procs = lua.create_table().ok()?;
    for (i, (pid, name, cpu, mem)) in processes.iter().enumerate() {
        let p = lua.create_table().ok()?;
        p.set("pid", *pid).ok()?;
        p.set("name", name.as_str()).ok()?;
        p.set("cpu", *cpu).ok()?;
        p.set("mem", *mem).ok()?;
        procs.set(i + 1, p).ok()?;
    }
    data.set("processes", procs).ok()?;

    // --- Call collect(data) ---
    let collect: mlua::Function = lua.globals().get("collect").ok()?;
    let result: mlua::Table = collect.call(data).ok()?;

    // --- Parse returned table into Vec<LuaPanelLine> ---
    let mut lines = Vec::new();
    let len = result.len().ok()? as i64;
    for i in 1..=len {
        let row: mlua::Table = match result.get(i) {
            Ok(t) => t,
            Err(_) => continue,
        };

        let text: String = match row.get("text") {
            Ok(t) => t,
            Err(_) => continue,
        };

        let color: Option<String> = row.get("color").ok();
        let bold: bool = row.get("bold").unwrap_or(false);

        lines.push(LuaPanelLine { text, color, bold });
    }

    Some(lines)
}
