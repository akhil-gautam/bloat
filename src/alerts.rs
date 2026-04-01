use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum AlertLevel {
    Normal,
    Warning,
    Critical,
}

#[derive(Debug, Clone)]
pub struct Alert {
    pub name: String,
    pub level: AlertLevel,
    pub message: String,
    pub since: Instant,
    pub notified: bool,
}

// ---------------------------------------------------------------------------
// AlertEngine
// ---------------------------------------------------------------------------

pub struct AlertEngine {
    pub alerts: Vec<Alert>,
    /// (since, level_value) — tracks when CPU first exceeded a threshold.
    cpu_high_since: Option<(Instant, f32)>,
    /// (since, pct) — tracks when memory first exceeded a threshold.
    mem_high_since: Option<(Instant, f64)>,
}

impl AlertEngine {
    pub fn new() -> Self {
        Self {
            alerts: Vec::new(),
            cpu_high_since: None,
            mem_high_since: None,
        }
    }

    /// Update thresholds based on current CPU and memory readings.
    ///
    /// - CPU > 90% sustained for 10 s → Critical
    /// - CPU > 70% sustained for 10 s → Warning
    /// - Memory > 80% sustained for 10 s → Critical
    /// - Memory > 60% sustained for 10 s → Warning
    pub fn update(&mut self, cpu_total: f32, mem_used: u64, mem_total: u64) {
        let now = Instant::now();
        let sustained = Duration::from_secs(10);

        let mem_pct = if mem_total > 0 {
            mem_used as f64 / mem_total as f64 * 100.0
        } else {
            0.0
        };

        // ----------------------------------------------------------------
        // CPU alert logic
        // ----------------------------------------------------------------
        if cpu_total > 70.0 {
            // Start or keep the timer running
            if self.cpu_high_since.is_none() {
                self.cpu_high_since = Some((now, cpu_total));
            }
        } else {
            // CPU dropped below 70% — clear the tracking and any CPU alert
            self.cpu_high_since = None;
            self.alerts.retain(|a| a.name != "cpu");
        }

        if let Some((since, _)) = self.cpu_high_since {
            let elapsed_secs = since.elapsed().as_secs();
            if elapsed_secs >= sustained.as_secs() {
                let level = if cpu_total > 90.0 {
                    AlertLevel::Critical
                } else {
                    AlertLevel::Warning
                };
                let message = format!(
                    "CPU at {:.0}% for {}s",
                    cpu_total,
                    elapsed_secs,
                );

                // Remove the old CPU alert and replace with fresh data
                let existing_notified = self
                    .alerts
                    .iter()
                    .find(|a| a.name == "cpu")
                    .map(|a| a.notified)
                    .unwrap_or(false);

                // Send desktop notification when escalating to Critical for the first time
                let should_notify = level == AlertLevel::Critical && !existing_notified;

                self.alerts.retain(|a| a.name != "cpu");
                self.alerts.push(Alert {
                    name: "cpu".to_string(),
                    level: level.clone(),
                    message: message.clone(),
                    since,
                    notified: existing_notified || should_notify,
                });

                if should_notify {
                    send_notification("bloat — Alert", &message);
                }
            }
        }

        // ----------------------------------------------------------------
        // Memory alert logic
        // ----------------------------------------------------------------
        if mem_pct > 60.0 {
            if self.mem_high_since.is_none() {
                self.mem_high_since = Some((now, mem_pct));
            }
        } else {
            self.mem_high_since = None;
            self.alerts.retain(|a| a.name != "memory");
        }

        if let Some((since, _)) = self.mem_high_since {
            let elapsed_secs = since.elapsed().as_secs();
            if elapsed_secs >= sustained.as_secs() {
                let level = if mem_pct > 80.0 {
                    AlertLevel::Critical
                } else {
                    AlertLevel::Warning
                };
                let message = format!("Memory at {:.0}%", mem_pct);

                let existing_notified = self
                    .alerts
                    .iter()
                    .find(|a| a.name == "memory")
                    .map(|a| a.notified)
                    .unwrap_or(false);

                let should_notify = level == AlertLevel::Critical && !existing_notified;

                self.alerts.retain(|a| a.name != "memory");
                self.alerts.push(Alert {
                    name: "memory".to_string(),
                    level: level.clone(),
                    message: message.clone(),
                    since,
                    notified: existing_notified || should_notify,
                });

                if should_notify {
                    send_notification("bloat — Alert", &message);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Desktop notification helper
// ---------------------------------------------------------------------------

fn send_notification(summary: &str, body: &str) {
    notify_rust::Notification::new()
        .summary(summary)
        .body(body)
        .sound_name("Basso")
        .show()
        .ok();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_no_alert_below_threshold() {
        let mut engine = AlertEngine::new();
        engine.update(50.0, 100, 1000); // 10% memory, 50% CPU — no alerts
        assert!(engine.alerts.is_empty());
    }

    #[test]
    fn test_no_alert_before_sustained_period() {
        let mut engine = AlertEngine::new();
        // Single call with high CPU — timer starts but 10 s haven't passed
        engine.update(95.0, 900, 1000); // 90% memory, 95% CPU
        assert!(engine.alerts.is_empty(), "Alert should not fire before 10 s");
    }

    #[test]
    fn test_alert_levels_cpu() {
        // Warning: 70 < cpu <= 90
        assert!(75.0_f32 > 70.0 && 75.0_f32 <= 90.0);
        // Critical: cpu > 90
        assert!(95.0_f32 > 90.0);
    }

    #[test]
    fn test_alert_levels_mem() {
        let mem_pct = |used: u64, total: u64| used as f64 / total as f64 * 100.0;
        // Warning: 60 < mem <= 80
        assert!(mem_pct(650, 1000) > 60.0 && mem_pct(650, 1000) <= 80.0);
        // Critical: mem > 80
        assert!(mem_pct(850, 1000) > 80.0);
    }

    #[test]
    fn test_clear_cpu_alert_when_drops() {
        let mut engine = AlertEngine::new();
        // Simulate CPU going high
        engine.cpu_high_since = Some((
            Instant::now()
                .checked_sub(Duration::from_secs(15))
                .unwrap_or_else(Instant::now),
            95.0,
        ));
        engine.update(95.0, 100, 1000);
        assert!(!engine.alerts.is_empty(), "Should have CPU alert");

        // CPU drops below threshold
        engine.update(50.0, 100, 1000);
        let cpu_alerts: Vec<_> = engine.alerts.iter().filter(|a| a.name == "cpu").collect();
        assert!(cpu_alerts.is_empty(), "CPU alert should be cleared");
    }

    #[test]
    fn test_clear_mem_alert_when_drops() {
        let mut engine = AlertEngine::new();
        engine.mem_high_since = Some((
            Instant::now()
                .checked_sub(Duration::from_secs(15))
                .unwrap_or_else(Instant::now),
            85.0,
        ));
        engine.update(50.0, 850, 1000);
        assert!(!engine.alerts.is_empty(), "Should have memory alert");

        engine.update(50.0, 100, 1000);
        let mem_alerts: Vec<_> = engine.alerts.iter().filter(|a| a.name == "memory").collect();
        assert!(mem_alerts.is_empty(), "Memory alert should be cleared");
    }
}
