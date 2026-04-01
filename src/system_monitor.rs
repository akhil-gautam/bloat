use sysinfo::{
    CpuRefreshKind, Disks, MemoryRefreshKind, Networks, ProcessRefreshKind, RefreshKind, System,
    Users,
};
use std::collections::{HashMap, VecDeque};
use std::time::Instant;

// ---------------------------------------------------------------------------
// Public snapshot types
// ---------------------------------------------------------------------------

/// Per-core CPU information.
#[derive(Clone, Debug)]
pub struct CpuCoreInfo {
    pub usage: f32,
    pub frequency_mhz: u64,
}

/// macOS memory breakdown from vm_stat.
#[derive(Clone, Debug, Default)]
pub struct MemoryBreakdown {
    pub wired: u64,
    pub active: u64,
    pub inactive: u64,
    pub compressed: u64,
}

/// Network stats for the dominant interface.
#[derive(Clone, Debug, Default)]
pub struct NetworkStats {
    pub interface: String,
    pub bytes_sent: u64,
    pub bytes_recv: u64,
    pub sent_per_sec: u64,
    pub recv_per_sec: u64,
}

/// Aggregate disk I/O rates.
#[derive(Clone, Debug, Default)]
pub struct DiskIoStats {
    pub read_per_sec: u64,
    pub write_per_sec: u64,
}

/// Battery information parsed from pmset.
#[derive(Clone, Debug)]
pub struct BatteryInfo {
    pub percent: f32,
    pub charging: bool,
    pub time_remaining: Option<String>,
}

/// A mounted volume.
#[derive(Clone, Debug)]
pub struct DiskMount {
    pub name: String,
    pub mount_point: String,
    pub total: u64,
    pub used: u64,
    pub fs_type: String,
}

/// GPU information from ioreg.
#[derive(Clone, Debug)]
pub struct GpuInfo {
    pub name: String,
    pub utilization: Option<f32>,
    pub vram_used: Option<u64>,
    pub vram_total: Option<u64>,
}

/// Per-app network usage.
#[derive(Clone, Debug)]
pub struct NetAppInfo {
    pub name: String,
    pub pid: u32,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub connections: Vec<ConnectionInfo>,
}

/// A single network connection.
#[derive(Clone, Debug)]
pub struct ConnectionInfo {
    pub local: String,
    pub remote: String,
    pub state: String,
    pub protocol: String,
}

/// Process diff — what changed since the last 5-second diff window.
#[derive(Clone, Debug, Default)]
pub struct ProcessDiff {
    pub new_pids: Vec<(u32, String)>,           // (pid, name) — new since last diff
    pub exited_pids: Vec<(u32, String)>,         // (pid, name) — gone since last diff
    pub cpu_spikes: Vec<(u32, String, f32)>,     // (pid, name, delta%) — CPU jumped >20%
}

/// Per-process information.
#[derive(Clone, Debug)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub mem_bytes: u64,
    pub user: String,
    pub disk_read: u64,
    pub disk_write: u64,
    pub parent_pid: Option<u32>,
}

/// A full snapshot of system state.
pub struct SystemSnapshot {
    // CPU
    pub cpu_usage_per_core: Vec<CpuCoreInfo>,
    pub cpu_usage_total: f32,
    pub cpu_temp: Option<f32>,
    pub cpu_history: Vec<f32>,
    pub cpu_per_core_history: Vec<Vec<f32>>,

    // Memory
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    pub mem_breakdown: Option<MemoryBreakdown>,
    pub mem_pressure_level: u8,

    // System
    pub load_avg: (f64, f64, f64),
    pub uptime: u64,
    pub total_processes: usize,
    pub total_threads: usize,

    // Network
    pub network: Option<NetworkStats>,
    pub net_apps: Vec<NetAppInfo>,
    pub net_recv_history: Vec<u64>,
    pub net_sent_history: Vec<u64>,

    // Disk I/O
    pub disk_io: Option<DiskIoStats>,

    // Battery
    pub battery: Option<BatteryInfo>,

    // Volumes
    pub volumes: Vec<DiskMount>,

    // GPU
    pub gpu: Option<GpuInfo>,

    // Processes
    pub processes: Vec<ProcessInfo>,

    // Process diff (updated every 5 seconds)
    pub process_diff: ProcessDiff,
}

// ---------------------------------------------------------------------------
// Monitor
// ---------------------------------------------------------------------------

pub struct SystemMonitor {
    sys: System,
    users: Users,
    networks: Networks,
    disks: Disks,
    last_refresh: Instant,

    // Network rate tracking
    prev_net_bytes: HashMap<String, (u64, u64)>,
    prev_net_time: Instant,

    // Disk I/O rate tracking
    prev_disk_read: u64,
    prev_disk_write: u64,
    prev_disk_time: Instant,

    // CPU history (last 60 total CPU readings)
    cpu_history: Vec<f32>,

    // Per-core CPU history (last 60 readings per core)
    per_core_history: Vec<VecDeque<f32>>,

    // Network bandwidth history (last 60 per-second readings)
    net_recv_history: VecDeque<u64>,
    net_sent_history: VecDeque<u64>,

    // Cached slow data (refreshed every few seconds)
    cached_battery: Option<BatteryInfo>,
    cached_mem_breakdown: Option<MemoryBreakdown>,
    cached_mem_pressure_level: u8,
    cached_gpu: Option<GpuInfo>,
    cached_net_apps: Vec<NetAppInfo>,
    last_slow_refresh: Instant,

    // Process diff tracking
    prev_process_snapshot: HashMap<u32, (String, f32)>,  // pid -> (name, cpu%)
    last_diff_time: Instant,
    cached_process_diff: ProcessDiff,
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
        let mut networks = Networks::new_with_refreshed_list();
        networks.refresh(true);
        let mut disks = Disks::new_with_refreshed_list();
        disks.refresh(true);

        let now = Instant::now();
        let old_time = now
            .checked_sub(std::time::Duration::from_secs(10))
            .unwrap_or(now);
        Self {
            sys,
            users,
            networks,
            disks,
            last_refresh: now,
            prev_net_bytes: HashMap::new(),
            prev_net_time: now,
            prev_disk_read: 0,
            prev_disk_write: 0,
            prev_disk_time: now,
            cpu_history: Vec::new(),
            per_core_history: Vec::new(),
            net_recv_history: VecDeque::new(),
            net_sent_history: VecDeque::new(),
            cached_battery: None,
            cached_mem_breakdown: None,
            cached_mem_pressure_level: 100,
            cached_gpu: None,
            cached_net_apps: Vec::new(),
            last_slow_refresh: old_time,
            prev_process_snapshot: HashMap::new(),
            last_diff_time: old_time,
            cached_process_diff: ProcessDiff::default(),
        }
    }

    /// Refresh and return a snapshot. Only actually refreshes sysinfo if at least
    /// `min_interval` has passed since the last refresh.
    pub fn snapshot(&mut self, min_interval: std::time::Duration) -> SystemSnapshot {
        let now = Instant::now();
        let should_refresh = self.last_refresh.elapsed() >= min_interval;

        if should_refresh {
            self.sys.refresh_all();
            self.networks.refresh(true);
            self.disks.refresh(true);
            self.last_refresh = Instant::now();
        }

        // Refresh slow data every 5 seconds
        if self.last_slow_refresh.elapsed() >= std::time::Duration::from_secs(5) {
            self.cached_battery = parse_battery();
            self.cached_mem_breakdown = parse_vm_stat();
            self.cached_mem_pressure_level = std::process::Command::new("sysctl")
                .args(["-n", "kern.memorystatus_level"])
                .output()
                .ok()
                .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<u8>().ok())
                .unwrap_or(100); // 100 = no pressure
            self.cached_gpu = parse_gpu_info();
            self.cached_net_apps = parse_net_apps();
            self.last_slow_refresh = Instant::now();
        }

        // CPU
        let cpus = self.sys.cpus();
        let cpu_usage_per_core: Vec<CpuCoreInfo> = cpus
            .iter()
            .map(|c| CpuCoreInfo {
                usage: c.cpu_usage(),
                frequency_mhz: c.frequency(),
            })
            .collect();
        let cpu_usage_total = if cpus.is_empty() {
            0.0
        } else {
            cpu_usage_per_core.iter().map(|c| c.usage).sum::<f32>() / cpus.len() as f32
        };

        // CPU history
        self.cpu_history.push(cpu_usage_total);
        if self.cpu_history.len() > 60 {
            self.cpu_history.remove(0);
        }

        // Per-core CPU history
        while self.per_core_history.len() < cpu_usage_per_core.len() {
            self.per_core_history.push(VecDeque::new());
        }
        for (i, core) in cpu_usage_per_core.iter().enumerate() {
            self.per_core_history[i].push_back(core.usage);
            if self.per_core_history[i].len() > 60 {
                self.per_core_history[i].pop_front();
            }
        }
        let cpu_per_core_history: Vec<Vec<f32>> = self
            .per_core_history
            .iter()
            .map(|dq| dq.iter().copied().collect())
            .collect();

        // CPU temperature via sysinfo Components (best-effort)
        let cpu_temp = get_cpu_temp_sysctl();

        // Memory
        let mem_total = self.sys.total_memory();
        let mem_used = self.sys.used_memory();
        let swap_total = self.sys.total_swap();
        let swap_used = self.sys.used_swap();

        let load = System::load_average();
        let load_avg = (load.one, load.five, load.fifteen);
        let uptime = System::uptime();

        // Process / thread counts
        let total_processes = self.sys.processes().len();
        let total_threads: usize = self
            .sys
            .processes()
            .values()
            .map(|p| p.tasks().map_or(1, |t| t.len().max(1)))
            .sum();

        // Processes
        let mut processes: Vec<ProcessInfo> = self
            .sys
            .processes()
            .values()
            .map(|p| {
                let user = p
                    .user_id()
                    .and_then(|uid| {
                        self.users
                            .iter()
                            .find(|u| u.id() == uid)
                            .map(|u| u.name().to_string())
                    })
                    .unwrap_or_default();
                let du = p.disk_usage();
                ProcessInfo {
                    pid: p.pid().as_u32(),
                    name: p.name().to_string_lossy().to_string(),
                    cpu_percent: p.cpu_usage(),
                    mem_bytes: p.memory(),
                    user,
                    disk_read: du.read_bytes,
                    disk_write: du.written_bytes,
                    parent_pid: p.parent().map(|pid| pid.as_u32()),
                }
            })
            .collect();

        // Default sort: CPU descending (caller will re-sort based on tab state)
        processes.sort_by(|a, b| {
            b.cpu_percent
                .partial_cmp(&a.cpu_percent)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Process diff — recompute every 5 seconds
        if self.last_diff_time.elapsed() >= std::time::Duration::from_secs(5) {
            let current_snapshot: HashMap<u32, (String, f32)> = processes
                .iter()
                .map(|p| (p.pid, (p.name.clone(), p.cpu_percent)))
                .collect();

            let mut diff = ProcessDiff::default();

            if !self.prev_process_snapshot.is_empty() {
                // New pids: in current but not in previous
                for (&pid, (name, _)) in &current_snapshot {
                    if !self.prev_process_snapshot.contains_key(&pid) {
                        diff.new_pids.push((pid, name.clone()));
                    }
                }

                // Exited pids: in previous but not in current
                for (&pid, (name, _)) in &self.prev_process_snapshot {
                    if !current_snapshot.contains_key(&pid) {
                        diff.exited_pids.push((pid, name.clone()));
                    }
                }

                // CPU spikes: process exists in both and CPU jumped >20%
                for (&pid, (name, prev_cpu)) in &self.prev_process_snapshot {
                    if let Some((_, curr_cpu)) = current_snapshot.get(&pid) {
                        let delta = curr_cpu - prev_cpu;
                        if delta > 20.0 {
                            diff.cpu_spikes.push((pid, name.clone(), delta));
                        }
                    }
                }

                // Sort spikes by delta descending
                diff.cpu_spikes.sort_by(|a, b| {
                    b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal)
                });
            }

            self.prev_process_snapshot = current_snapshot;
            self.last_diff_time = Instant::now();
            self.cached_process_diff = diff;
        }

        // Network
        let elapsed_net = now.duration_since(self.prev_net_time).as_secs_f64().max(0.001);
        let network = self.compute_network(elapsed_net);
        if should_refresh {
            // Update previous bytes after computing rates
            for (name, data) in self.networks.iter() {
                let sent = data.total_transmitted();
                let recv = data.total_received();
                self.prev_net_bytes.insert(name.clone(), (sent, recv));
            }
            self.prev_net_time = now;
        }

        // Push network rates into history deques (cap at 60)
        let (recv_per_sec, sent_per_sec) = network
            .as_ref()
            .map(|n| (n.recv_per_sec, n.sent_per_sec))
            .unwrap_or((0, 0));
        self.net_recv_history.push_back(recv_per_sec);
        if self.net_recv_history.len() > 60 {
            self.net_recv_history.pop_front();
        }
        self.net_sent_history.push_back(sent_per_sec);
        if self.net_sent_history.len() > 60 {
            self.net_sent_history.pop_front();
        }

        // Disk I/O
        let elapsed_disk = now.duration_since(self.prev_disk_time).as_secs_f64().max(0.001);
        let (total_read, total_write) = self
            .sys
            .processes()
            .values()
            .fold((0u64, 0u64), |(r, w), p| {
                let du = p.disk_usage();
                (r + du.total_read_bytes, w + du.total_written_bytes)
            });
        // Disk I/O via iostat (more reliable than per-process counters on macOS)
        let disk_io = if should_refresh {
            parse_iostat().or(Some(DiskIoStats {
                read_per_sec: 0,
                write_per_sec: 0,
            }))
        } else {
            Some(DiskIoStats {
                read_per_sec: 0,
                write_per_sec: 0,
            })
        };

        // Volumes
        let volumes: Vec<DiskMount> = self
            .disks
            .iter()
            .map(|d| {
                let total = d.total_space();
                let avail = d.available_space();
                let used = total.saturating_sub(avail);
                DiskMount {
                    name: d.name().to_string_lossy().to_string(),
                    mount_point: d.mount_point().to_string_lossy().to_string(),
                    total,
                    used,
                    fs_type: d.file_system().to_string_lossy().to_string(),
                }
            })
            .collect();

        SystemSnapshot {
            cpu_usage_per_core,
            cpu_usage_total,
            cpu_temp,
            cpu_history: self.cpu_history.clone(),
            cpu_per_core_history,
            mem_total,
            mem_used,
            swap_total,
            swap_used,
            mem_breakdown: self.cached_mem_breakdown.clone(),
            mem_pressure_level: self.cached_mem_pressure_level,
            load_avg,
            uptime,
            total_processes,
            total_threads,
            network,
            net_recv_history: self.net_recv_history.iter().copied().collect(),
            net_sent_history: self.net_sent_history.iter().copied().collect(),
            disk_io,
            battery: self.cached_battery.clone(),
            volumes,
            gpu: self.cached_gpu.clone(),
            net_apps: self.cached_net_apps.clone(),
            processes,
            process_diff: self.cached_process_diff.clone(),
        }
    }

    fn compute_network(&self, elapsed: f64) -> Option<NetworkStats> {
        // Pick the interface with the most traffic (excluding loopback)
        let mut best: Option<(String, u64, u64, u64, u64)> = None;

        for (name, data) in self.networks.iter() {
            if name == "lo" || name.starts_with("lo") {
                continue;
            }
            let sent = data.total_transmitted();
            let recv = data.total_received();

            let (prev_sent, prev_recv) = self
                .prev_net_bytes
                .get(name.as_str())
                .copied()
                .unwrap_or((sent, recv));

            let sent_per_sec =
                ((sent.saturating_sub(prev_sent)) as f64 / elapsed) as u64;
            let recv_per_sec =
                ((recv.saturating_sub(prev_recv)) as f64 / elapsed) as u64;

            let traffic = sent_per_sec + recv_per_sec;
            let is_better = best
                .as_ref()
                .map(|(_, _, _, s, r)| traffic > s + r)
                .unwrap_or(true);

            if is_better {
                best = Some((name.clone(), sent, recv, sent_per_sec, recv_per_sec));
            }
        }

        best.map(|(interface, bytes_sent, bytes_recv, sent_per_sec, recv_per_sec)| {
            NetworkStats {
                interface,
                bytes_sent,
                bytes_recv,
                sent_per_sec,
                recv_per_sec,
            }
        })
    }
}

// ---------------------------------------------------------------------------
// macOS-specific helpers (non-blocking, cached)
// ---------------------------------------------------------------------------

/// Parse battery info from `pmset -g batt`.
fn parse_battery() -> Option<BatteryInfo> {
    let output = std::process::Command::new("pmset")
        .args(["-g", "batt"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();

    // Look for lines like: -InternalBattery-0 (id=...)  85%; discharging; 3:45 remaining
    for line in text.lines() {
        if !line.contains('%') {
            continue;
        }
        // Parse percent
        let percent = {
            let pct_pos = line.find('%')?;
            let start = line[..pct_pos].rfind(|c: char| !c.is_ascii_digit())? + 1;
            line[start..pct_pos].parse::<f32>().ok()?
        };

        let charging = line.contains("charging") && !line.contains("discharging");

        // Parse time remaining like "3:45 remaining"
        let time_remaining = if let Some(pos) = line.find("remaining") {
            let before = line[..pos].trim();
            if let Some(time_start) = before.rfind(|c: char| c == ';' || c == '\t') {
                let t = before[time_start + 1..].trim().to_string();
                if t.contains(':') { Some(t) } else { None }
            } else {
                None
            }
        } else {
            None
        };

        return Some(BatteryInfo {
            percent,
            charging,
            time_remaining,
        });
    }
    None
}

/// Parse `vm_stat` output to get memory breakdown on macOS.
fn parse_vm_stat() -> Option<MemoryBreakdown> {
    let output = std::process::Command::new("vm_stat")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();

    let page_size: u64 = 16384; // 16 KiB pages on Apple Silicon / modern macOS

    let mut wired: u64 = 0;
    let mut active: u64 = 0;
    let mut inactive: u64 = 0;
    let mut compressed: u64 = 0;

    for line in text.lines() {
        let parse_pages = |line: &str| -> Option<u64> {
            let val = line.split(':').nth(1)?.trim().trim_end_matches('.');
            val.parse::<u64>().ok()
        };

        if line.starts_with("Pages wired down") {
            wired = parse_pages(line).unwrap_or(0) * page_size;
        } else if line.starts_with("Pages active") {
            active = parse_pages(line).unwrap_or(0) * page_size;
        } else if line.starts_with("Pages inactive") {
            inactive = parse_pages(line).unwrap_or(0) * page_size;
        } else if line.starts_with("Pages occupied by compressor") {
            compressed = parse_pages(line).unwrap_or(0) * page_size;
        }
    }

    Some(MemoryBreakdown {
        wired,
        active,
        inactive,
        compressed,
    })
}

/// Parse GPU info from `ioreg`.
fn parse_gpu_info() -> Option<GpuInfo> {
    let output = std::process::Command::new("ioreg")
        .args(["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();

    if text.trim().is_empty() {
        return None;
    }

    // GPU name from "model" = "Apple M4"
    let name = text
        .lines()
        .find(|l| l.contains("\"model\""))
        .and_then(|l| {
            // Format: "model" = "Apple M4"
            let after_eq = l.split('=').nth(1)?;
            let trimmed = after_eq.trim().trim_matches('"');
            if trimmed.is_empty() { None } else { Some(trimmed.to_string()) }
        })
        .unwrap_or_else(|| {
            // Fallback: try system_profiler
            std::process::Command::new("system_profiler")
                .arg("SPDisplaysDataType")
                .output()
                .ok()
                .and_then(|o| {
                    let s = String::from_utf8_lossy(&o.stdout);
                    s.lines()
                        .find(|l| l.contains("Chipset Model:"))
                        .map(|l| l.split(':').nth(1).unwrap_or("GPU").trim().to_string())
                })
                .unwrap_or_else(|| "GPU".to_string())
        });

    // Device Utilization % from PerformanceStatistics dict
    // Format: "Device Utilization %"=13
    let utilization = text.lines().find_map(|l| {
        if let Some(pos) = l.find("Device Utilization %") {
            let after = &l[pos..];
            // Find "=XX" — the value right after the key
            if let Some(eq) = after.find('=') {
                let val_str = &after[eq + 1..];
                // Take digits until non-digit
                let num: String = val_str.chars().take_while(|c| c.is_ascii_digit()).collect();
                num.parse::<f32>().ok()
            } else {
                None
            }
        } else {
            None
        }
    });

    // VRAM
    let vram_total = text.lines().find_map(|l| {
        if l.contains("VRAM,totalMB") {
            l.split('=').nth(1)?.trim().parse::<u64>().ok().map(|mb| mb * 1024 * 1024)
        } else {
            None
        }
    });

    let vram_used = text.lines().find_map(|l| {
        if l.contains("VRAM,usedMB") {
            l.split('=').nth(1)?.trim().parse::<u64>().ok().map(|mb| mb * 1024 * 1024)
        } else {
            None
        }
    });

    Some(GpuInfo {
        name,
        utilization,
        vram_used,
        vram_total,
    })
}

/// Get CPU temperature via sysctl (Apple Silicon thermal level as a proxy).
fn get_cpu_temp_sysctl() -> Option<f32> {
    // Approach 1: ioreg for Apple Silicon — look for "Temperature" in AppleARMIODevice
    if let Some(temp) = try_ioreg_temp() {
        return Some(temp);
    }

    // Approach 2: sysctl machdep.xcpm.cpu_thermal_level (Intel Macs — returns 0-100 level, not °C)
    if let Ok(output) = std::process::Command::new("sysctl")
        .arg("-n")
        .arg("machdep.xcpm.cpu_thermal_level")
        .output()
    {
        let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if let Ok(level) = s.parse::<f32>() {
            if level > 0.0 {
                // Thermal level 0-100 → approximate °C (rough mapping)
                return Some(40.0 + level * 0.6);
            }
        }
    }

    None
}

fn try_ioreg_temp() -> Option<f32> {
    // On Apple Silicon, read die temperature from AppleARMIODevice sensors
    let output = std::process::Command::new("ioreg")
        .args(["-r", "-n", "AppleARMIODevice", "-w", "0"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    // Look for "die-temperature" or "Temperature" sensor readings
    // Format varies but often appears as "Temperature" = XX (in fixed-point)
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.contains("\"Temperature\"") || trimmed.contains("\"die-temperature\"") {
            // Try to extract number after "="
            if let Some(eq_pos) = trimmed.find('=') {
                let val_str = trimmed[eq_pos + 1..].trim().trim_matches('"');
                if let Ok(v) = val_str.parse::<f32>() {
                    // Some sensors report in centi-degrees or milli-degrees
                    if v > 1000.0 {
                        return Some(v / 100.0);
                    } else if v > 200.0 {
                        return Some(v / 10.0);
                    } else if v > 0.0 && v < 150.0 {
                        return Some(v);
                    }
                }
            }
        }
    }

    // Fallback: try to find any temperature-like value from SMC
    let output2 = std::process::Command::new("ioreg")
        .args(["-r", "-c", "AppleSMC", "-w", "0"])
        .output()
        .ok()?;
    let stdout2 = String::from_utf8_lossy(&output2.stdout);

    for line in stdout2.lines() {
        if line.contains("CPU") && line.contains("emperature") {
            if let Some(eq_pos) = line.find('=') {
                let val_str = line[eq_pos + 1..].trim().trim_matches('"').trim();
                if let Ok(v) = val_str.parse::<f32>() {
                    if v > 0.0 && v < 150.0 {
                        return Some(v);
                    }
                }
            }
        }
    }

    None
}

// ---------------------------------------------------------------------------
// Per-app network usage (lsof -i + nettop)
// ---------------------------------------------------------------------------

fn parse_net_apps() -> Vec<NetAppInfo> {
    let output = match std::process::Command::new("lsof")
        .args(["-i", "-n", "-P"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return Vec::new(),
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut apps: HashMap<u32, NetAppInfo> = HashMap::new();

    for line in stdout.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 9 {
            continue;
        }

        let name = parts[0].to_string();
        let pid: u32 = match parts[1].parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let protocol = parts[7].to_string();
        let conn_str = parts[8];

        let state = parts
            .get(9)
            .map(|s| s.trim_matches(|c: char| c == '(' || c == ')').to_string())
            .unwrap_or_default();

        let (local, remote) = if let Some(arrow) = conn_str.find("->") {
            (
                conn_str[..arrow].to_string(),
                conn_str[arrow + 2..].to_string(),
            )
        } else {
            (conn_str.to_string(), String::new())
        };

        let entry = apps.entry(pid).or_insert_with(|| NetAppInfo {
            name: name.clone(),
            pid,
            bytes_in: 0,
            bytes_out: 0,
            connections: Vec::new(),
        });

        if entry.connections.len() < 10 {
            entry.connections.push(ConnectionInfo {
                local,
                remote,
                state,
                protocol,
            });
        }
    }

    // Try nettop for bandwidth data
    if let Ok(output) = std::process::Command::new("nettop")
        .args(["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"])
        .output()
    {
        let nettop_out = String::from_utf8_lossy(&output.stdout);
        for line in nettop_out.lines().skip(1) {
            let parts: Vec<&str> = line.split(',').collect();
            if parts.len() < 3 {
                continue;
            }
            let name_pid = parts[0].trim();
            let pid: u32 = if let Some(dot) = name_pid.rfind('.') {
                name_pid[dot + 1..].parse().unwrap_or(0)
            } else {
                0
            };
            if pid == 0 {
                continue;
            }
            let bytes_in: u64 = parts[1].trim().parse().unwrap_or(0);
            let bytes_out: u64 = parts[2].trim().parse().unwrap_or(0);
            if let Some(app) = apps.get_mut(&pid) {
                app.bytes_in = bytes_in;
                app.bytes_out = bytes_out;
            }
        }
    }

    let mut result: Vec<NetAppInfo> = apps.into_values().collect();
    result.sort_by(|a, b| {
        let a_total = a.bytes_in + a.bytes_out + a.connections.len() as u64;
        let b_total = b.bytes_in + b.bytes_out + b.connections.len() as u64;
        b_total.cmp(&a_total)
    });
    result.retain(|a| !a.connections.is_empty());
    result.truncate(20);
    result
}

// ---------------------------------------------------------------------------
// Disk I/O via iostat
// ---------------------------------------------------------------------------

fn parse_iostat() -> Option<DiskIoStats> {
    // `iostat -d -c 1` gives one snapshot with MB/s for each disk
    // Format:
    //               disk0
    //     KB/t  tps  MB/s
    //    22.65  187  4.13
    let output = std::process::Command::new("iostat")
        .args(["-d", "-c", "1"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    // Sum MB/s across all disks (every 3rd column in the data row)
    let lines: Vec<&str> = stdout.lines().collect();
    if lines.len() < 3 {
        return None;
    }

    // The header line tells us column positions, data is the last line
    let data_line = lines.last()?;
    let values: Vec<f64> = data_line
        .split_whitespace()
        .filter_map(|s| s.parse::<f64>().ok())
        .collect();

    // Values come in groups of 3: KB/t, tps, MB/s per disk
    // Sum all MB/s values (index 2, 5, 8, ...)
    let mut total_mb_s = 0.0;
    for (i, v) in values.iter().enumerate() {
        if i % 3 == 2 {
            total_mb_s += v;
        }
    }

    // iostat only gives total throughput, not split read/write in this mode
    // Use it as read estimate; for write we need a different approach
    let bytes_per_sec = (total_mb_s * 1024.0 * 1024.0) as u64;

    Some(DiskIoStats {
        read_per_sec: bytes_per_sec,
        write_per_sec: 0, // iostat basic mode doesn't split r/w
    })
}
