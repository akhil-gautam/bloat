use std::collections::VecDeque;
use std::time::SystemTime;

#[derive(Clone, Debug)]
pub enum AnomalyEvent {
    CpuSpike { value: f32, threshold: f32 },
    MemoryJump { delta_bytes: u64 },
    NewHeavyProcess { pid: u32, name: String, cpu: f32 },
}

#[derive(Clone, Debug)]
pub struct HistoryPoint {
    pub timestamp: SystemTime,
    pub cpu_total: f32,
    pub mem_used: u64,
    pub mem_total: u64,
    pub top_processes: Vec<(u32, String, f32, u64)>,
    pub anomalies: Vec<AnomalyEvent>,
}

pub struct History {
    points: VecDeque<HistoryPoint>,
    capacity: usize,
    cpu_window: VecDeque<f32>,
    mem_window: VecDeque<u64>,
}

impl History {
    pub fn new(capacity: usize) -> Self {
        Self {
            points: VecDeque::new(),
            capacity,
            cpu_window: VecDeque::new(),
            mem_window: VecDeque::new(),
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

    pub fn latest_anomalies(&self) -> Vec<&AnomalyEvent> {
        self.points.back().map_or(Vec::new(), |p| p.anomalies.iter().collect())
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
}
