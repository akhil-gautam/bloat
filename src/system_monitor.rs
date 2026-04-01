use sysinfo::{CpuRefreshKind, MemoryRefreshKind, ProcessRefreshKind, RefreshKind, System, Users};
use std::time::Instant;

/// A snapshot of system resource usage.
pub struct SystemSnapshot {
    pub cpu_usage_per_core: Vec<f32>,
    pub cpu_usage_total: f32,
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    pub load_avg: (f64, f64, f64),
    pub uptime: u64,
    pub processes: Vec<ProcessInfo>,
}

#[derive(Clone)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub mem_bytes: u64,
    pub user: String,
}

/// Keeps a `sysinfo::System` instance and refreshes on demand.
pub struct SystemMonitor {
    sys: System,
    users: Users,
    last_refresh: Instant,
}

impl SystemMonitor {
    pub fn new() -> Self {
        let mut sys = System::new_with_specifics(
            RefreshKind::nothing()
                .with_cpu(CpuRefreshKind::everything())
                .with_memory(MemoryRefreshKind::everything())
                .with_processes(ProcessRefreshKind::everything()),
        );
        // First refresh populates baseline (CPU deltas need two calls)
        sys.refresh_all();
        std::thread::sleep(std::time::Duration::from_millis(200));
        sys.refresh_all();

        let users = Users::new_with_refreshed_list();

        Self {
            sys,
            users,
            last_refresh: Instant::now(),
        }
    }

    /// Refresh and return a snapshot. Only actually refreshes if at least
    /// `min_interval` has passed since the last refresh.
    pub fn snapshot(&mut self, min_interval: std::time::Duration) -> SystemSnapshot {
        if self.last_refresh.elapsed() >= min_interval {
            self.sys.refresh_all();
            self.last_refresh = Instant::now();
        }

        let cpus = self.sys.cpus();
        let cpu_usage_per_core: Vec<f32> = cpus.iter().map(|c| c.cpu_usage()).collect();
        let cpu_usage_total = if cpus.is_empty() {
            0.0
        } else {
            cpu_usage_per_core.iter().sum::<f32>() / cpus.len() as f32
        };

        let mem_total = self.sys.total_memory();
        let mem_used = self.sys.used_memory();
        let swap_total = self.sys.total_swap();
        let swap_used = self.sys.used_swap();

        let load = System::load_average();
        let load_avg = (load.one, load.five, load.fifteen);
        let uptime = System::uptime();

        // Collect top processes by CPU usage
        let mut processes: Vec<ProcessInfo> = self
            .sys
            .processes()
            .values()
            .map(|p| {
                let user = p
                    .user_id()
                    .and_then(|uid| {
                        self.users.iter().find(|u| u.id() == uid).map(|u| u.name().to_string())
                    })
                    .unwrap_or_default();
                ProcessInfo {
                    pid: p.pid().as_u32(),
                    name: p.name().to_string_lossy().to_string(),
                    cpu_percent: p.cpu_usage(),
                    mem_bytes: p.memory(),
                    user,
                }
            })
            .collect();

        // Sort by CPU descending
        processes.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap_or(std::cmp::Ordering::Equal));
        processes.truncate(30); // Keep top 30

        SystemSnapshot {
            cpu_usage_per_core,
            cpu_usage_total,
            mem_total,
            mem_used,
            swap_total,
            swap_used,
            load_avg,
            uptime,
            processes,
        }
    }
}
