use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Deserialize)]
pub struct PluginConfig {
    #[serde(default)]
    pub panel: Vec<PanelDef>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PanelDef {
    pub name: String,
    pub command: String,
    #[serde(default = "default_interval")]
    pub interval: u64, // seconds
    #[serde(default = "default_position")]
    pub position: String, // "left" or "right"
    #[serde(default)]
    pub color: Option<String>, // "green", "yellow", "cyan", etc.
}

fn default_interval() -> u64 {
    5
}
fn default_position() -> String {
    "right".to_string()
}

pub fn load_config() -> PluginConfig {
    let config_path = dirs::home_dir()
        .map(|h| h.join(".config/bloat/plugins.toml"))
        .unwrap_or_else(|| PathBuf::from("plugins.toml"));

    if !config_path.exists() {
        return PluginConfig { panel: Vec::new() };
    }

    let content = std::fs::read_to_string(&config_path).unwrap_or_default();
    toml::from_str(&content).unwrap_or_else(|_| PluginConfig { panel: Vec::new() })
}
