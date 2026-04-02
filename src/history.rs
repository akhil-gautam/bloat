use std::collections::VecDeque;
use std::time::SystemTime;

#[derive(Clone, Debug)]
pub enum AnomalyEvent {
    CpuSpike { value: f32, threshold: f32 },
    MemoryJump { delta_bytes: u64 },
    NewHeavyProcess { pid: u32, name: String, cpu: f32 },
    NetworkSpike { direction: String, bytes_per_sec: u64, avg: u64 },
}

#[derive(Clone, Debug)]
pub struct HistoryPoint {
    pub timestamp: SystemTime,
    pub cpu_total: f32,
    pub mem_used: u64,
    pub mem_total: u64,
    pub top_processes: Vec<(u32, String, f32, u64)>,
    pub anomalies: Vec<AnomalyEvent>,
    pub net_recv_rate: u64,
    pub net_sent_rate: u64,
}

pub struct History {
    points: VecDeque<HistoryPoint>,
    capacity: usize,
    cpu_window: VecDeque<f32>,
    mem_window: VecDeque<u64>,
    net_recv_window: VecDeque<u64>,
    net_sent_window: VecDeque<u64>,
}

impl History {
    pub fn new(capacity: usize) -> Self {
        Self {
            points: VecDeque::new(),
            capacity,
            cpu_window: VecDeque::new(),
            mem_window: VecDeque::new(),
            net_recv_window: VecDeque::new(),
            net_sent_window: VecDeque::new(),
        }
    }

    pub fn record(&mut self, mut point: HistoryPoint) {
        self.detect_anomalies(&mut point);
        self.points.push_back(point);
        if self.points.len() > self.capacity {
            self.points.pop_front();
        }
    }

    pub fn points(&self) -> &VecDeque<HistoryPoint> {
        &self.points
    }

    /// Return anomalies from the last 10 seconds (not just the latest point).
    pub fn latest_anomalies(&self) -> Vec<&AnomalyEvent> {
        let cutoff = std::time::SystemTime::now()
            - std::time::Duration::from_secs(10);
        let mut result = Vec::new();
        // Walk backwards through recent points
        for point in self.points.iter().rev().take(15) {
            if point.timestamp < cutoff {
                break;
            }
            for anomaly in &point.anomalies {
                // Avoid duplicates — only add if we don't already have this type
                let dominated = result.iter().any(|existing: &&AnomalyEvent| {
                    std::mem::discriminant(*existing) == std::mem::discriminant(anomaly)
                });
                if !dominated {
                    result.push(anomaly);
                }
            }
        }
        result
    }

    pub fn get_point(&self, index: usize) -> Option<&HistoryPoint> {
        self.points.get(index)
    }

    pub fn len(&self) -> usize {
        self.points.len()
    }

    pub fn anomaly_positions(&self) -> Vec<usize> {
        self.points.iter().enumerate()
            .filter(|(_, p)| !p.anomalies.is_empty())
            .map(|(i, _)| i)
            .collect()
    }

    fn detect_anomalies(&mut self, point: &mut HistoryPoint) {
        // --- CPU z-score spike detection (rolling window of 30) ---
        const CPU_WINDOW_SIZE: usize = 30;
        const CPU_ZSCORE_THRESHOLD: f32 = 2.0;

        if self.cpu_window.len() >= CPU_WINDOW_SIZE {
            let n = self.cpu_window.len() as f32;
            let mean = self.cpu_window.iter().sum::<f32>() / n;
            let variance = self.cpu_window.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / n;
            let std_dev = variance.sqrt();

            let spike_detected = if std_dev > 0.1 {
                // Standard z-score check
                let z_score = (point.cpu_total - mean) / std_dev;
                z_score > CPU_ZSCORE_THRESHOLD
            } else {
                // When baseline is nearly constant, use absolute difference:
                // flag if current value exceeds mean by more than 2x mean or by >15 percentage points
                let delta = point.cpu_total - mean;
                delta > 15.0 || (mean > 1.0 && point.cpu_total > mean * 2.0)
            };

            if spike_detected {
                point.anomalies.push(AnomalyEvent::CpuSpike {
                    value: point.cpu_total,
                    threshold: mean,
                });
            }
        }

        // Update CPU rolling window
        self.cpu_window.push_back(point.cpu_total);
        if self.cpu_window.len() > CPU_WINDOW_SIZE {
            self.cpu_window.pop_front();
        }

        // --- Memory jump detection (> 500 MiB from previous point) ---
        const MEM_JUMP_THRESHOLD: u64 = 500 * 1024 * 1024; // 500 MiB

        if let Some(prev_mem) = self.mem_window.back().copied() {
            let mem_used = point.mem_used;
            if mem_used > prev_mem && mem_used - prev_mem > MEM_JUMP_THRESHOLD {
                point.anomalies.push(AnomalyEvent::MemoryJump {
                    delta_bytes: mem_used - prev_mem,
                });
            }
        }

        // Update memory window
        self.mem_window.push_back(point.mem_used);
        if self.mem_window.len() > CPU_WINDOW_SIZE {
            self.mem_window.pop_front();
        }

        // --- New heavy process detection (>20% CPU, not in previous snapshot) ---
        const HEAVY_CPU_THRESHOLD: f32 = 20.0;

        if let Some(prev_point) = self.points.back() {
            let prev_pids: std::collections::HashSet<u32> =
                prev_point.top_processes.iter().map(|(pid, _, _, _)| *pid).collect();

            for (pid, name, cpu, _mem) in &point.top_processes {
                if *cpu >= HEAVY_CPU_THRESHOLD && !prev_pids.contains(pid) {
                    point.anomalies.push(AnomalyEvent::NewHeavyProcess {
                        pid: *pid,
                        name: name.clone(),
                        cpu: *cpu,
                    });
                }
            }
        }

        // --- Network spike detection: current rate > 3x rolling average ---
        if self.net_recv_window.len() >= 10 {
            let avg: u64 = self.net_recv_window.iter().sum::<u64>() / self.net_recv_window.len() as u64;
            if avg > 1024 && point.net_recv_rate > avg * 3 {
                point.anomalies.push(AnomalyEvent::NetworkSpike {
                    direction: "download".into(),
                    bytes_per_sec: point.net_recv_rate,
                    avg,
                });
            }
        }

        // Update recv window
        self.net_recv_window.push_back(point.net_recv_rate);
        if self.net_recv_window.len() > 30 {
            self.net_recv_window.pop_front();
        }

        if self.net_sent_window.len() >= 10 {
            let avg: u64 = self.net_sent_window.iter().sum::<u64>() / self.net_sent_window.len() as u64;
            if avg > 1024 && point.net_sent_rate > avg * 3 {
                point.anomalies.push(AnomalyEvent::NetworkSpike {
                    direction: "upload".into(),
                    bytes_per_sec: point.net_sent_rate,
                    avg,
                });
            }
        }

        // Update sent window
        self.net_sent_window.push_back(point.net_sent_rate);
        if self.net_sent_window.len() > 30 {
            self.net_sent_window.pop_front();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_point(cpu: f32, mem_used: u64, mem_total: u64, procs: Vec<(u32, String, f32, u64)>) -> HistoryPoint {
        HistoryPoint {
            timestamp: SystemTime::now(),
            cpu_total: cpu,
            mem_used,
            mem_total,
            top_processes: procs,
            anomalies: Vec::new(),
            net_recv_rate: 0,
            net_sent_rate: 0,
        }
    }

    #[test]
    fn test_record_and_capacity() {
        let mut history = History::new(3);
        for i in 0..5 {
            history.record(make_point(10.0 * (i + 1) as f32, 1_000_000_000, 8_000_000_000, vec![]));
        }
        assert_eq!(history.points().len(), 3, "Should retain only the last 3 points");
        // Verify we have the last 3 points (cpu 30, 40, 50)
        let cpus: Vec<f32> = history.points().iter().map(|p| p.cpu_total).collect();
        assert_eq!(cpus, vec![30.0, 40.0, 50.0]);
    }

    #[test]
    fn test_cpu_spike_detection() {
        let mut history = History::new(300);
        // Record 30 baseline points at 10% CPU to fill the window
        for _ in 0..30 {
            history.record(make_point(10.0, 4_000_000_000, 8_000_000_000, vec![]));
        }
        // Record a spike at 80% CPU
        history.record(make_point(80.0, 4_000_000_000, 8_000_000_000, vec![]));

        let anomalies = history.latest_anomalies();
        let has_spike = anomalies.iter().any(|a| matches!(a, AnomalyEvent::CpuSpike { .. }));
        assert!(has_spike, "Should detect a CPU spike at 80% when baseline is 10%");
    }

    #[test]
    fn test_memory_jump_detection() {
        let mut history = History::new(300);
        // Record initial point at 4 GiB
        history.record(make_point(10.0, 4 * 1024 * 1024 * 1024, 8 * 1024 * 1024 * 1024, vec![]));
        // Record jump to 5 GiB (1 GiB jump > 500 MiB threshold)
        history.record(make_point(10.0, 5 * 1024 * 1024 * 1024, 8 * 1024 * 1024 * 1024, vec![]));

        let anomalies = history.latest_anomalies();
        let has_mem_jump = anomalies.iter().any(|a| matches!(a, AnomalyEvent::MemoryJump { .. }));
        assert!(has_mem_jump, "Should detect memory jump from 4 GiB to 5 GiB");
    }

    #[test]
    fn test_new_heavy_process() {
        let mut history = History::new(300);
        // First point: only one process with PID 100
        let procs1 = vec![(100u32, "existing_proc".to_string(), 5.0f32, 100_000_000u64)];
        history.record(make_point(10.0, 4_000_000_000, 8_000_000_000, procs1));

        // Second point: new heavy process with PID 999
        let procs2 = vec![
            (100u32, "existing_proc".to_string(), 5.0f32, 100_000_000u64),
            (999u32, "ffmpeg".to_string(), 85.0f32, 200_000_000u64),
        ];
        history.record(make_point(15.0, 4_000_000_000, 8_000_000_000, procs2));

        let anomalies = history.latest_anomalies();
        let has_new_heavy = anomalies.iter().any(|a| {
            matches!(a, AnomalyEvent::NewHeavyProcess { pid: 999, name, cpu } if name == "ffmpeg" && *cpu > 20.0)
        });
        assert!(has_new_heavy, "Should detect new heavy process 'ffmpeg' at PID 999");
    }

    fn make_point_with_net(cpu: f32, mem_used: u64, mem_total: u64, recv: u64, sent: u64) -> HistoryPoint {
        HistoryPoint {
            timestamp: SystemTime::now(),
            cpu_total: cpu,
            mem_used,
            mem_total,
            top_processes: vec![],
            anomalies: Vec::new(),
            net_recv_rate: recv,
            net_sent_rate: sent,
        }
    }

    #[test]
    fn test_network_spike_detection_download() {
        let mut history = History::new(300);
        // Record 10 baseline points at ~1 MiB/s download
        let baseline: u64 = 1 * 1024 * 1024; // 1 MiB/s
        for _ in 0..10 {
            history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, baseline, 0));
        }
        // Record a spike at 10 MiB/s (> 3x average of ~1 MiB/s)
        let spike: u64 = 10 * 1024 * 1024;
        history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, spike, 0));

        let anomalies = history.latest_anomalies();
        let has_net_spike = anomalies.iter().any(|a| {
            matches!(a, AnomalyEvent::NetworkSpike { direction, .. } if direction == "download")
        });
        assert!(has_net_spike, "Should detect a download network spike when rate exceeds 3x average");
    }

    #[test]
    fn test_network_spike_detection_upload() {
        let mut history = History::new(300);
        // Record 10 baseline points at ~1 MiB/s upload
        let baseline: u64 = 1 * 1024 * 1024;
        for _ in 0..10 {
            history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, 0, baseline));
        }
        // Record a spike at 10 MiB/s upload
        let spike: u64 = 10 * 1024 * 1024;
        history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, 0, spike));

        let anomalies = history.latest_anomalies();
        let has_net_spike = anomalies.iter().any(|a| {
            matches!(a, AnomalyEvent::NetworkSpike { direction, .. } if direction == "upload")
        });
        assert!(has_net_spike, "Should detect an upload network spike when rate exceeds 3x average");
    }

    #[test]
    fn test_no_network_spike_below_threshold() {
        let mut history = History::new(300);
        // Record 10 baseline points at 512 bytes/s (below 1024 avg threshold)
        for _ in 0..10 {
            history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, 512, 0));
        }
        // Even a large jump shouldn't trigger if avg is below 1024
        history.record(make_point_with_net(5.0, 4_000_000_000, 8_000_000_000, 5000, 0));

        let anomalies = history.latest_anomalies();
        let has_net_spike = anomalies.iter().any(|a| matches!(a, AnomalyEvent::NetworkSpike { .. }));
        assert!(!has_net_spike, "Should not detect a network spike when average is below 1 KiB/s");
    }
}
