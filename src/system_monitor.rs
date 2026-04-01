use sysinfo::{
    CpuRefreshKind, Disks, MemoryRefreshKind, Networks, ProcessRefreshKind, RefreshKind, System,
    Users,
};
use std::collections::HashMap;
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
}

/// A full snapshot of system state.
pub struct SystemSnapshot {
    // CPU
    pub cpu_usage_per_core: Vec<CpuCoreInfo>,
    pub cpu_usage_total: f32,
    pub cpu_temp: Option<f32>,
    pub cpu_history: Vec<f32>,

    // Memory
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    pub mem_breakdown: Option<MemoryBreakdown>,

    // System
    pub load_avg: (f64, f64, f64),
    pub uptime: u64,
    pub total_processes: usize,
    pub total_threads: usize,

    // Network
    pub network: Option<NetworkStats>,

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

    // Cached slow data (refreshed every few seconds)
    cached_battery: Option<BatteryInfo>,
    cached_mem_breakdown: Option<MemoryBreakdown>,
    cached_gpu: Option<GpuInfo>,
    last_slow_refresh: Instant,
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
            cached_battery: None,
            cached_mem_breakdown: None,
            cached_gpu: None,
            last_slow_refresh: Instant::now()
                .checked_sub(std::time::Duration::from_secs(10))
                .unwrap_or(now),
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
            self.cached_gpu = parse_gpu_info();
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
                }
            })
            .collect();

        // Default sort: CPU descending (caller will re-sort based on tab state)
        processes.sort_by(|a, b| {
            b.cpu_percent
                .partial_cmp(&a.cpu_percent)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

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
        let disk_io = if should_refresh && self.prev_disk_time != now {
            let read_per_sec =
                ((total_read.saturating_sub(self.prev_disk_read)) as f64 / elapsed_disk) as u64;
            let write_per_sec =
                ((total_write.saturating_sub(self.prev_disk_write)) as f64 / elapsed_disk) as u64;
            Some(DiskIoStats {
                read_per_sec,
                write_per_sec,
            })
        } else {
            Some(DiskIoStats {
                read_per_sec: 0,
                write_per_sec: 0,
            })
        };
        if should_refresh {
            self.prev_disk_read = total_read;
            self.prev_disk_write = total_write;
            self.prev_disk_time = now;
        }

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
            mem_total,
            mem_used,
            swap_total,
            swap_used,
            mem_breakdown: self.cached_mem_breakdown.clone(),
            load_avg,
            uptime,
            total_processes,
            total_threads,
            network,
            disk_io,
            battery: self.cached_battery.clone(),
            volumes,
            gpu: self.cached_gpu.clone(),
            processes,
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

    // Try to find GPU name
    let name = text
        .lines()
        .find(|l| l.contains("IOClass") || l.contains("\"model\""))
        .and_then(|l| {
            let start = l.find('"')?;
            let rest = &l[start + 1..];
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        })
        .unwrap_or_else(|| "GPU".to_string());

    // Device Utilization %
    let utilization = text.lines().find_map(|l| {
        if l.contains("Device Utilization %") {
            l.split('=').nth(1)?.trim().parse::<f32>().ok()
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
