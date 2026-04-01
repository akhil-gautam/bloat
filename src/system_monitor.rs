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

/// NVMe / disk latency estimate derived from iostat.
#[derive(Clone, Debug)]
pub struct DiskLatency {
    pub device: String,
    pub avg_read_us: f64,   // microseconds (estimated)
    pub avg_write_us: f64,  // microseconds (estimated)
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

/// Per-thread information fetched via `ps -M`.
#[derive(Clone, Debug)]
pub struct ThreadInfo {
    pub tid: u64,
    pub cpu_percent: f32,
    pub state: String,
    pub name: String,
}

/// Parse threads for a given PID using `ps -M -p <PID>`.
/// Returns an empty Vec on any error or if the process no longer exists.
pub fn get_threads_for_pid(pid: u32) -> Vec<ThreadInfo> {
    let output = match std::process::Command::new("ps")
        .args(["-M", "-p", &pid.to_string(), "-o", "tid,pcpu,stat,comm"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return Vec::new(),
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let mut threads = Vec::new();

    for (line_idx, line) in text.lines().enumerate() {
        // Skip the header line
        if line_idx == 0 {
            continue;
        }
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.splitn(4, char::is_whitespace)
            .filter(|s| !s.is_empty())
            .collect();

        if parts.len() < 3 {
            continue;
        }

        let tid: u64 = match parts[0].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let cpu: f32 = parts[1].parse().unwrap_or(0.0);
        let stat = parts[2].to_string();
        let name = parts.get(3).map(|s| s.trim().to_string()).unwrap_or_default();

        // Normalise the stat field to a human-readable state
        let state = if stat.starts_with('R') {
            "running".to_string()
        } else if stat.starts_with('S') || stat.starts_with('I') {
            "sleeping".to_string()
        } else if stat.starts_with('Z') {
            "zombie".to_string()
        } else if stat.starts_with('T') {
            "stopped".to_string()
        } else {
            stat
        };

        threads.push(ThreadInfo { tid, cpu_percent: cpu, state, name });
    }

    threads
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
    /// Detected runtime environment (e.g. "Node", "Python", "Ruby").
    pub runtime: Option<String>,
    /// Detected service name (e.g. "Rails", "Webpack", "Redis").
    pub service: Option<String>,
    /// TCP ports this process is listening on.
    pub listening_ports: Vec<u16>,
}

/// A full snapshot of system state.
pub struct SystemSnapshot {
    // CPU
    pub cpu_usage_per_core: Vec<CpuCoreInfo>,
    pub cpu_usage_total: f32,
    pub cpu_user_pct: f32,
    pub cpu_system_pct: f32,
    pub cpu_idle_pct: f32,
    pub cpu_temp: Option<f32>,
    pub cpu_history: Vec<f32>,
    pub cpu_per_core_history: Vec<Vec<f32>>,

    // Thermal throttle
    pub throttled: bool,
    pub cpu_freq_current: Option<u64>,  // Current avg frequency MHz
    pub cpu_freq_max: Option<u64>,      // Max frequency MHz

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
    pub disk_latency: Option<DiskLatency>,

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

    // Thread list for the currently expanded PID (empty if none)
    pub threads: Vec<ThreadInfo>,
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
    cached_cpu_split: Option<(f32, f32, f32)>,  // (user, system, idle)
    cached_throttle: (bool, Option<u64>, Option<u64>),  // (throttled, current_mhz, max_mhz)
    cached_gpu: Option<GpuInfo>,
    cached_net_apps: Vec<NetAppInfo>,
    cached_disk_latency: Option<DiskLatency>,
    last_slow_refresh: Instant,

    // Process diff tracking
    prev_process_snapshot: HashMap<u32, (String, f32)>,  // pid -> (name, cpu%)
    last_diff_time: Instant,
    cached_process_diff: ProcessDiff,

    // Listening ports cache (pid -> sorted port list)
    cached_listening_ports: HashMap<u32, Vec<u16>>,

    // Thread cache for the expanded process
    pub cached_threads: Vec<ThreadInfo>,
    pub cached_threads_pid: Option<u32>,
    last_thread_refresh: Instant,
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
            cpu_history: Vec::new(),
            per_core_history: Vec::new(),
            net_recv_history: VecDeque::new(),
            net_sent_history: VecDeque::new(),
            cached_battery: None,
            cached_mem_breakdown: None,
            cached_mem_pressure_level: 100,
            cached_cpu_split: None,
            cached_throttle: (false, None, None),
            cached_gpu: None,
            cached_net_apps: Vec::new(),
            cached_disk_latency: None,
            last_slow_refresh: old_time,
            prev_process_snapshot: HashMap::new(),
            last_diff_time: old_time,
            cached_process_diff: ProcessDiff::default(),
            cached_listening_ports: HashMap::new(),
            cached_threads: Vec::new(),
            cached_threads_pid: None,
            last_thread_refresh: old_time,
        }
    }

    /// Refresh and return a snapshot. Only actually refreshes sysinfo if at least
    /// `min_interval` has passed since the last refresh.
    /// If `expanded_pid` is provided, thread info for that PID is refreshed when
    /// necessary (pid changed or 2 seconds elapsed) and included in the snapshot.
    pub fn snapshot(&mut self, min_interval: std::time::Duration) -> SystemSnapshot {
        self.snapshot_with_threads(min_interval, None)
    }

    pub fn snapshot_with_threads(
        &mut self,
        min_interval: std::time::Duration,
        expanded_pid: Option<u32>,
    ) -> SystemSnapshot {
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
            self.cached_listening_ports = parse_listening_ports();
            self.cached_cpu_split = parse_cpu_split();
            self.cached_throttle = detect_throttle();
            self.cached_disk_latency = parse_disk_latency();
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
                let name = p.name().to_string_lossy().to_string();
                let cmd: Vec<String> = p.cmd().iter().map(|a| a.to_string_lossy().to_string()).collect();
                let pid = p.pid().as_u32();
                let runtime = detect_runtime(&name);
                let service = detect_service(&name, &cmd);
                let listening_ports = self
                    .cached_listening_ports
                    .get(&pid)
                    .cloned()
                    .unwrap_or_default();
                ProcessInfo {
                    pid,
                    name,
                    cpu_percent: p.cpu_usage(),
                    mem_bytes: p.memory(),
                    user,
                    disk_read: du.read_bytes,
                    disk_write: du.written_bytes,
                    parent_pid: p.parent().map(|pid| pid.as_u32()),
                    runtime,
                    service,
                    listening_ports,
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

        let (cpu_user_pct, cpu_system_pct, cpu_idle_pct) =
            self.cached_cpu_split.unwrap_or((0.0, 0.0, 0.0));
        let (throttled, cpu_freq_current, cpu_freq_max) = self.cached_throttle;

        // Refresh thread cache when the expanded PID changes or every 2 seconds
        let needs_thread_refresh = match (expanded_pid, self.cached_threads_pid) {
            (None, _) => false,
            (Some(new_pid), Some(old_pid)) if new_pid == old_pid => {
                self.last_thread_refresh.elapsed() >= std::time::Duration::from_secs(2)
            }
            (Some(_), _) => true,
        };

        if expanded_pid.is_none() {
            // Nothing expanded — clear the cache
            if self.cached_threads_pid.is_some() {
                self.cached_threads.clear();
                self.cached_threads_pid = None;
            }
        } else if needs_thread_refresh {
            let pid = expanded_pid.unwrap();
            self.cached_threads = get_threads_for_pid(pid);
            self.cached_threads_pid = Some(pid);
            self.last_thread_refresh = Instant::now();
        }

        let threads = self.cached_threads.clone();

        SystemSnapshot {
            cpu_usage_per_core,
            cpu_usage_total,
            cpu_user_pct,
            cpu_system_pct,
            cpu_idle_pct,
            cpu_temp,
            cpu_history: self.cpu_history.clone(),
            cpu_per_core_history,
            throttled,
            cpu_freq_current,
            cpu_freq_max,
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
            disk_latency: self.cached_disk_latency.clone(),
            battery: self.cached_battery.clone(),
            volumes,
            gpu: self.cached_gpu.clone(),
            net_apps: self.cached_net_apps.clone(),
            processes,
            process_diff: self.cached_process_diff.clone(),
            threads,
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
// Runtime / service detection helpers
// ---------------------------------------------------------------------------

/// Detect the language runtime from a process name.
fn detect_runtime(name: &str) -> Option<String> {
    let lower = name.to_lowercase();
    if lower.contains("node") {
        Some("Node".to_string())
    } else if lower.contains("python") {
        Some("Python".to_string())
    } else if lower.contains("ruby") {
        Some("Ruby".to_string())
    } else if lower == "java" || lower.contains("java") {
        Some("Java".to_string())
    } else if lower == "go" || lower == "gopls" {
        Some("Go".to_string())
    } else if lower == "rustc" || lower == "cargo" {
        Some("Rust".to_string())
    } else if lower.contains("beam") {
        Some("Elixir/Erlang".to_string())
    } else if lower == "php" {
        Some("PHP".to_string())
    } else if lower == "deno" {
        Some("Deno".to_string())
    } else if lower == "bun" {
        Some("Bun".to_string())
    } else {
        None
    }
}

/// Detect the service name from a process name and its command-line arguments.
fn detect_service(name: &str, cmd: &[String]) -> Option<String> {
    let name_lower = name.to_lowercase();

    // Name-based service detection (fast path)
    if name_lower == "redis-server" {
        return Some("Redis".to_string());
    }
    if name_lower == "postgres" || name_lower == "postmaster" {
        return Some("PostgreSQL".to_string());
    }
    if name_lower == "mongod" {
        return Some("MongoDB".to_string());
    }
    if name_lower == "nginx" {
        return Some("Nginx".to_string());
    }

    // Argument-based service detection — check all argv entries
    let args_lower: Vec<String> = cmd.iter().map(|a| a.to_lowercase()).collect();

    // next + server together → Next.js (check before plain "next")
    let has_next = args_lower.iter().any(|a| a.contains("next"));
    let has_server = args_lower.iter().any(|a| a.contains("server"));
    if has_next && has_server {
        return Some("Next.js".to_string());
    }

    for arg in &args_lower {
        if arg.contains("rails") {
            return Some("Rails".to_string());
        }
        if arg.contains("sidekiq") {
            return Some("Sidekiq".to_string());
        }
        if arg.contains("webpack") {
            return Some("Webpack".to_string());
        }
        if arg.contains("vite") {
            return Some("Vite".to_string());
        }
        if arg.contains("puma") {
            return Some("Puma".to_string());
        }
        if arg.contains("unicorn") {
            return Some("Unicorn".to_string());
        }
        if arg.contains("gunicorn") {
            return Some("Gunicorn".to_string());
        }
        if arg.contains("uvicorn") {
            return Some("Uvicorn".to_string());
        }
        if arg.contains("celery") {
            return Some("Celery".to_string());
        }
    }

    None
}

// ---------------------------------------------------------------------------
// Listening port discovery via lsof
// ---------------------------------------------------------------------------

/// Parse `lsof -i -P -n -sTCP:LISTEN` and return a map of PID → listening ports.
fn parse_listening_ports() -> HashMap<u32, Vec<u16>> {
    let output = match std::process::Command::new("lsof")
        .args(["-i", "-P", "-n", "-sTCP:LISTEN"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return HashMap::new(),
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut map: HashMap<u32, Vec<u16>> = HashMap::new();

    for line in stdout.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        // Typical lsof columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        // NAME field (last) looks like "TCP *:3000 (LISTEN)" or "127.0.0.1:3000 (LISTEN)"
        if parts.len() < 9 {
            continue;
        }

        let pid: u32 = match parts[1].parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        // The address/name field — find the one that contains a colon (host:port)
        // In this lsof invocation it is usually parts[8]
        let addr = parts[8];
        // Extract port: everything after the last ':'
        if let Some(colon) = addr.rfind(':') {
            let port_str = &addr[colon + 1..];
            if let Ok(port) = port_str.parse::<u16>() {
                map.entry(pid).or_default().push(port);
            }
        }
    }

    // Deduplicate and sort each entry
    for ports in map.values_mut() {
        ports.sort_unstable();
        ports.dedup();
    }

    map
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

// ---------------------------------------------------------------------------
// Disk latency estimation via iostat
// ---------------------------------------------------------------------------

/// Estimate per-device read/write latency from `iostat -d -c 2 -w 1`.
///
/// `iostat` gives: KB/t (KB per transfer), tps (transfers/sec), MB/s.
/// Latency ≈ (KB/t * 1024) / (MB/s * 1024 * 1024) seconds
///           = KB/t / (MB/s * 1024) seconds
///           = KB/t / (MB/s * 1024) * 1_000_000 microseconds
///
/// We use the second sample (index 1) which reflects the most recent interval.
/// If MB/s is 0 we fall back to a simple `1 / tps * 1_000_000` estimate.
/// Returns the stats for the first (primary) disk found.
fn parse_disk_latency() -> Option<DiskLatency> {
    // Run two samples with a 1-second window; output arrives after ~1 s.
    // We run this only in the slow-refresh path (every 5 s) so the 1 s wait
    // is acceptable.
    let output = std::process::Command::new("iostat")
        .args(["-d", "-c", "2", "-w", "1"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);

    // Expected format (two header + two data repetitions):
    //               disk0
    //     KB/t  tps  MB/s
    //    22.65  187  4.13
    //
    //               disk0
    //     KB/t  tps  MB/s
    //     5.12   42  0.21
    //
    // We want the last data row (second sample).
    let lines: Vec<&str> = stdout.lines().collect();

    // Collect device name from the first disk-header line (starts with whitespace + "disk")
    let device = lines.iter()
        .find(|l| {
            let t = l.trim();
            t.starts_with("disk") || t.contains("disk0")
        })
        .map(|l| {
            // Take the first word that starts with "disk"
            l.split_whitespace()
                .find(|w| w.starts_with("disk"))
                .unwrap_or("disk0")
                .to_string()
        })
        .unwrap_or_else(|| "disk0".to_string());

    // Collect all numeric data rows (skip header lines containing "KB/t")
    let data_rows: Vec<Vec<f64>> = lines.iter()
        .filter(|l| !l.trim().is_empty() && !l.contains("KB/t") && !l.trim().starts_with("disk"))
        .map(|l| {
            l.split_whitespace()
                .filter_map(|s| s.parse::<f64>().ok())
                .collect::<Vec<f64>>()
        })
        .filter(|v| !v.is_empty())
        .collect();

    // Take the last data row (second sample, most recent interval)
    let row = data_rows.last()?;
    if row.len() < 3 {
        return None;
    }

    // Values per disk in groups of 3: KB/t, tps, MB/s
    // Use first disk only (indices 0,1,2)
    let kb_per_t = row[0];
    let tps = row[1];
    let mb_s = row[2];

    let latency_us = if mb_s > 0.001 {
        // latency = (KB/t) / (MB/s * 1024) * 1_000_000 µs
        (kb_per_t / (mb_s * 1024.0)) * 1_000_000.0
    } else if tps > 0.5 {
        // Fallback: 1/tps seconds → µs
        (1.0 / tps) * 1_000_000.0
    } else {
        return None;
    };

    // iostat doesn't separate read vs write in basic mode; report the same
    // estimate for both directions.
    Some(DiskLatency {
        device,
        avg_read_us: latency_us,
        avg_write_us: latency_us,
    })
}

// ---------------------------------------------------------------------------
// CPU user/system/idle split via `top`
// ---------------------------------------------------------------------------

/// Parse CPU time breakdown from `top -l 1 -n 0 -s 0`.
/// Returns `(user_pct, system_pct, idle_pct)` or None on failure.
fn parse_cpu_split() -> Option<(f32, f32, f32)> {
    let output = std::process::Command::new("top")
        .args(["-l", "1", "-n", "0", "-s", "0"])
        .output()
        .ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    // Typical line: "CPU usage: 12.50% user, 8.33% sys, 79.16% idle"
    for line in stdout.lines() {
        if line.contains("CPU usage:") {
            let user = parse_pct_before(line, "% user").or_else(|| parse_pct_before(line, "% us"));
            let sys  = parse_pct_before(line, "% sys").or_else(|| parse_pct_before(line, "% sy"));
            let idle = parse_pct_before(line, "% idle").or_else(|| parse_pct_before(line, "% id"));
            if let (Some(u), Some(s), Some(i)) = (user, sys, idle) {
                return Some((u, s, i));
            }
        }
    }
    None
}

/// Find a percentage number immediately before `suffix` in `s`.
fn parse_pct_before(s: &str, suffix: &str) -> Option<f32> {
    let pos = s.find(suffix)?;
    let before = &s[..pos];
    // Walk backwards over digits and '.'
    let start = before
        .rfind(|c: char| !c.is_ascii_digit() && c != '.')
        .map(|i| i + 1)
        .unwrap_or(0);
    before[start..].parse::<f32>().ok()
}

// ---------------------------------------------------------------------------
// Thermal throttle detection
// ---------------------------------------------------------------------------

/// Read a sysctl key and return it as u64.
fn sysctl_u64(key: &str) -> Option<u64> {
    let output = std::process::Command::new("sysctl")
        .args(["-n", key])
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().ok()
}

/// Detect CPU throttling.
/// Returns `(throttled, current_freq_mhz, max_freq_mhz)`.
fn detect_throttle() -> (bool, Option<u64>, Option<u64>) {
    let current = sysctl_u64("hw.cpufrequency");
    let max     = sysctl_u64("hw.cpufrequency_max");
    match (current, max) {
        (Some(c), Some(m)) if m > 0 => {
            let throttled = c < m * 9 / 10;
            (throttled, Some(c / 1_000_000), Some(m / 1_000_000))
        }
        _ => {
            // Apple Silicon: hw.cpufrequency is absent. Fall back to comparing
            // the current average core frequency reported by sysinfo against the
            // nominal max from `sysctl hw.cpufrequency_max` (Intel path above
            // already handles this). On AS we have no root-free way to get the
            // true current P-cluster frequency, so we just report no data.
            (false, None, None)
        }
    }
}
