use std::collections::HashMap;
use std::time::Instant;

use super::config::PanelDef;

#[derive(Debug, Clone)]
pub struct PanelOutput {
    pub name: String,
    pub lines: Vec<String>,
    pub position: String,
    pub color: Option<String>,
    pub last_updated: Instant,
    pub error: Option<String>,
}

pub struct PluginRunner {
    panels: Vec<PanelDef>,
    outputs: HashMap<String, PanelOutput>,
    last_run: HashMap<String, Instant>,
}

impl PluginRunner {
    pub fn new(panels: Vec<PanelDef>) -> Self {
        Self {
            panels,
            outputs: HashMap::new(),
            last_run: HashMap::new(),
        }
    }

    /// Check which panels need refreshing and run their commands.
    /// Returns updated outputs. Runs commands synchronously; should be
    /// called from the slow-refresh background thread.
    pub fn tick(&mut self) -> &HashMap<String, PanelOutput> {
        for panel in &self.panels {
            let should_run = self
                .last_run
                .get(&panel.name)
                .map_or(true, |t| t.elapsed().as_secs() >= panel.interval);

            if should_run {
                let output = std::process::Command::new("sh")
                    .args(["-c", &panel.command])
                    .output();

                match output {
                    Ok(o) => {
                        let stdout = String::from_utf8_lossy(&o.stdout);
                        let lines: Vec<String> = stdout
                            .lines()
                            .take(20) // Cap at 20 lines
                            .map(|l| l.to_string())
                            .collect();
                        self.outputs.insert(
                            panel.name.clone(),
                            PanelOutput {
                                name: panel.name.clone(),
                                lines,
                                position: panel.position.clone(),
                                color: panel.color.clone(),
                                last_updated: Instant::now(),
                                error: if o.status.success() {
                                    None
                                } else {
                                    Some(
                                        String::from_utf8_lossy(&o.stderr)
                                            .trim()
                                            .to_string(),
                                    )
                                },
                            },
                        );
                    }
                    Err(e) => {
                        self.outputs.insert(
                            panel.name.clone(),
                            PanelOutput {
                                name: panel.name.clone(),
                                lines: Vec::new(),
                                position: panel.position.clone(),
                                color: panel.color.clone(),
                                last_updated: Instant::now(),
                                error: Some(e.to_string()),
                            },
                        );
                    }
                }
                self.last_run.insert(panel.name.clone(), Instant::now());
            }
        }
        &self.outputs
    }

    pub fn outputs(&self) -> &HashMap<String, PanelOutput> {
        &self.outputs
    }

    pub fn has_panels(&self) -> bool {
        !self.panels.is_empty()
    }
}

/// Run all panels whose interval has elapsed, given a snapshot of the last-run
/// times. Returns a Vec of updated PanelOutputs.
/// This function is intended to be called from the background slow-refresh
/// thread and owns its own `PluginRunner` state between calls via the
/// caller-maintained `last_run` map.
pub fn run_plugins(
    panels: &[PanelDef],
    last_run: &HashMap<String, Instant>,
) -> (Vec<PanelOutput>, HashMap<String, Instant>) {
    let mut outputs = Vec::new();
    let mut new_last_run = last_run.clone();

    for panel in panels {
        let should_run = last_run
            .get(&panel.name)
            .map_or(true, |t| t.elapsed().as_secs() >= panel.interval);

        if should_run {
            let output = std::process::Command::new("sh")
                .args(["-c", &panel.command])
                .output();

            let panel_output = match output {
                Ok(o) => {
                    let stdout = String::from_utf8_lossy(&o.stdout);
                    let lines: Vec<String> = stdout
                        .lines()
                        .take(20)
                        .map(|l| l.to_string())
                        .collect();
                    PanelOutput {
                        name: panel.name.clone(),
                        lines,
                        position: panel.position.clone(),
                        color: panel.color.clone(),
                        last_updated: Instant::now(),
                        error: if o.status.success() {
                            None
                        } else {
                            Some(String::from_utf8_lossy(&o.stderr).trim().to_string())
                        },
                    }
                }
                Err(e) => PanelOutput {
                    name: panel.name.clone(),
                    lines: Vec::new(),
                    position: panel.position.clone(),
                    color: panel.color.clone(),
                    last_updated: Instant::now(),
                    error: Some(e.to_string()),
                },
            };

            outputs.push(panel_output);
            new_last_run.insert(panel.name.clone(), Instant::now());
        }
    }

    (outputs, new_last_run)
}
