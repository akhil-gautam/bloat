use ratatui::prelude::*;
use ratatui::widgets::*;

use crate::app::{ProcessSort, SystemTabState};
use crate::system_monitor::{ProcessInfo, SystemSnapshot};
use crate::ui::format_size;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn draw(frame: &mut Frame, snap: &SystemSnapshot, state: &SystemTabState, area: Rect) {
    // Two-row layout: top info panels + bottom process list
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(12),  // Top panels
            Constraint::Min(8),   // Process list
        ])
        .split(area);

    draw_top_panels(frame, snap, rows[0]);
    draw_process_section(frame, snap, state, rows[1]);
}

// ---------------------------------------------------------------------------
// Top panel — two-column layout
// ---------------------------------------------------------------------------

fn draw_top_panels(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    draw_left_column(frame, snap, cols[0]);
    draw_right_column(frame, snap, cols[1]);
}

fn draw_left_column(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    // Sub-rows: CPU, Network (with per-app), Disk I/O, GPU
    let net_height = 3 + snap.net_apps.len().min(6) as u16; // header + apps
    let sub = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(4),          // CPU
            Constraint::Length(net_height.max(4)), // Network
            Constraint::Length(3),        // Disk I/O
            Constraint::Length(3),        // GPU
        ])
        .split(area);

    draw_cpu_section(frame, snap, sub[0]);
    draw_network_section(frame, snap, sub[1]);
    draw_disk_io_section(frame, snap, sub[2]);
    draw_gpu_section(frame, snap, sub[3]);
}

fn draw_right_column(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    // Sub-rows: Memory, Battery, Volumes
    let sub = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(5),   // Memory
            Constraint::Length(3), // Battery
            Constraint::Min(3),   // Volumes
        ])
        .split(area);

    draw_memory_section(frame, snap, sub[0]);
    draw_battery_section(frame, snap, sub[1]);
    draw_volumes_section(frame, snap, sub[2]);
}

// ---------------------------------------------------------------------------
// CPU section
// ---------------------------------------------------------------------------

fn draw_cpu_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" CPU ")
        .title_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 || inner.width == 0 {
        return;
    }

    let cores = &snap.cpu_usage_per_core;
    if cores.is_empty() {
        return;
    }

    // We'll split the inner area: top portion for bars, bottom for sparkline + temp
    let sparkline_height: u16 = 1;
    let temp_height: u16 = 1;
    let reserved = sparkline_height + temp_height;
    let bars_height = inner.height.saturating_sub(reserved);

    let bars_area = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: bars_height,
    };
    let sparkline_area = Rect {
        x: inner.x,
        y: inner.y + bars_height,
        width: inner.width,
        height: sparkline_height,
    };
    let temp_area = Rect {
        x: inner.x,
        y: inner.y + bars_height + sparkline_height,
        width: inner.width,
        height: temp_height,
    };

    // CPU bars in two columns
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(bars_area);

    let half = (cores.len() + 1) / 2;
    let left_cores = &cores[..half];
    let right_cores = &cores[half..];

    draw_cpu_column(frame, left_cores, 0, cols[0]);
    draw_cpu_column(frame, right_cores, half, cols[1]);

    // Sparkline history
    draw_cpu_sparkline(frame, snap, sparkline_area);

    // Temperature
    let temp_line = if let Some(temp) = snap.cpu_temp {
        Line::from(vec![
            Span::styled("Temp: ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{:.0}°C", temp),
                Style::default().fg(if temp > 80.0 {
                    Color::Red
                } else if temp > 60.0 {
                    Color::Yellow
                } else {
                    Color::Green
                }),
            ),
        ])
    } else {
        Line::from(vec![
            Span::styled("Temp: ", Style::default().fg(Color::Cyan)),
            Span::styled("N/A", Style::default().fg(Color::DarkGray)),
        ])
    };
    frame.render_widget(Paragraph::new(temp_line), temp_area);
}

fn draw_cpu_column(frame: &mut Frame, cores: &[crate::system_monitor::CpuCoreInfo], start_idx: usize, area: Rect) {
    for (i, core) in cores.iter().enumerate() {
        if i as u16 >= area.height {
            break;
        }
        let row = Rect {
            x: area.x,
            y: area.y + i as u16,
            width: area.width,
            height: 1,
        };

        let usage = core.usage;
        let freq = core.frequency_mhz;

        // Label "  0 " = 4 chars, bar, " XX.X% XXXX MHz"
        let freq_str = if freq > 0 {
            format!(" {:.1}%  {}MHz", usage, freq)
        } else {
            format!(" {:.1}%", usage)
        };
        let label_width = 4usize;
        let suffix_width = freq_str.len();
        let bar_width = (row.width as usize).saturating_sub(label_width + suffix_width);
        let filled = ((usage as f64 / 100.0) * bar_width as f64).round() as usize;
        let empty = bar_width.saturating_sub(filled);

        let color = if usage > 80.0 {
            Color::Red
        } else if usage > 50.0 {
            Color::Yellow
        } else {
            Color::Green
        };

        let line = Line::from(vec![
            Span::styled(
                format!("{:>3} ", start_idx + i),
                Style::default().fg(Color::Cyan),
            ),
            Span::styled("█".repeat(filled), Style::default().fg(color)),
            Span::styled("░".repeat(empty), Style::default().fg(Color::Rgb(50, 50, 50))),
            Span::styled(freq_str, Style::default().fg(color)),
        ]);

        frame.render_widget(Paragraph::new(line), row);
    }
}

fn draw_cpu_sparkline(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    if area.height == 0 || area.width == 0 {
        return;
    }

    // Use blocks where ▂ is minimum for any non-zero value (▁ is invisible on dark bg)
    let blocks = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let history = &snap.cpu_history;

    let label = "Hist: ";
    let label_len = label.len();
    let chart_width = (area.width as usize).saturating_sub(label_len);

    if chart_width == 0 {
        return;
    }

    // Build sparkline characters from history
    let value_to_block = |v: f32| -> char {
        if v < 0.5 {
            '·' // near-zero shown as dot
        } else {
            // Map 0.5-100 to indices 1-7 (skip index 0 = ▁ which is invisible)
            let idx = ((v / 100.0) * 6.0 + 1.0).min(7.0) as usize;
            blocks[idx]
        }
    };

    let mut chart_chars: Vec<Span> = Vec::new();

    // Pad with dots for empty slots at the start
    let data_count = history.len().min(chart_width);
    let pad_count = chart_width.saturating_sub(data_count);
    if pad_count > 0 {
        chart_chars.push(Span::styled(
            "·".repeat(pad_count),
            Style::default().fg(Color::Rgb(50, 50, 50)),
        ));
    }

    // Render actual data points
    let start = if history.len() > chart_width {
        history.len() - chart_width
    } else {
        0
    };
    for &v in &history[start..] {
        let ch = value_to_block(v);
        let color = if v > 80.0 {
            Color::Red
        } else if v > 50.0 {
            Color::Yellow
        } else {
            Color::Green
        };
        chart_chars.push(Span::styled(
            ch.to_string(),
            Style::default().fg(color),
        ));
    }

    let mut spans = vec![Span::styled(label, Style::default().fg(Color::Cyan))];
    spans.extend(chart_chars);

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

// ---------------------------------------------------------------------------
// Memory section
// ---------------------------------------------------------------------------

fn draw_memory_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Memory ")
        .title_style(Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // RAM bar
            Constraint::Length(1), // Memory breakdown
            Constraint::Length(1), // Swap + load
            Constraint::Length(1), // Tasks/threads + uptime
        ])
        .split(inner);

    // RAM bar
    let mem_pct = if snap.mem_total > 0 {
        snap.mem_used as f64 / snap.mem_total as f64
    } else {
        0.0
    };
    let ram_color = if mem_pct > 0.9 {
        Color::Red
    } else if mem_pct > 0.7 {
        Color::Yellow
    } else {
        Color::Green
    };
    draw_resource_bar(
        frame,
        "RAM",
        mem_pct,
        &format!("{} / {}", format_size(snap.mem_used), format_size(snap.mem_total)),
        ram_color,
        rows[0],
    );

    // Memory breakdown
    if rows[1].y < inner.y + inner.height {
        if let Some(ref bd) = snap.mem_breakdown {
            let line = Line::from(vec![
                Span::styled("  wired:", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("{} ", format_size(bd.wired)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("actv:", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("{} ", format_size(bd.active)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("inact:", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("{} ", format_size(bd.inactive)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("comp:", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format_size(bd.compressed),
                    Style::default().fg(Color::White),
                ),
            ]);
            frame.render_widget(Paragraph::new(line), rows[1]);
        }
    }

    // Swap + load
    if rows.len() > 2 && rows[2].y < inner.y + inner.height {
        let swap_pct = if snap.swap_total > 0 {
            snap.swap_used as f64 / snap.swap_total as f64
        } else {
            0.0
        };
        let line = Line::from(vec![
            Span::styled("  Swp ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{}/{}", format_size(snap.swap_used), format_size(snap.swap_total)),
                Style::default().fg(if swap_pct > 0.5 { Color::Yellow } else { Color::Green }),
            ),
            Span::styled("  Load ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{:.2} {:.2} {:.2}", snap.load_avg.0, snap.load_avg.1, snap.load_avg.2),
                Style::default().fg(Color::White),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), rows[2]);
    }

    // Tasks + threads + uptime
    if rows.len() > 3 && rows[3].y < inner.y + inner.height {
        let hours = snap.uptime / 3600;
        let mins = (snap.uptime % 3600) / 60;
        let line = Line::from(vec![
            Span::styled("  Tasks:", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{} ", snap.total_processes),
                Style::default().fg(Color::White),
            ),
            Span::styled("Thr:", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{}  ", snap.total_threads),
                Style::default().fg(Color::White),
            ),
            Span::styled("Up:", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{}h{}m", hours, mins),
                Style::default().fg(Color::White),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), rows[3]);
    }
}

// ---------------------------------------------------------------------------
// Network section
// ---------------------------------------------------------------------------

fn draw_network_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Network ")
        .title_style(Style::default().fg(Color::Blue).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    let mut lines: Vec<Line> = Vec::new();

    // Overall throughput
    if let Some(ref net) = snap.network {
        lines.push(Line::from(vec![
            Span::styled(format!("{}: ", net.interface), Style::default().fg(Color::Cyan)),
            Span::styled("▲ ", Style::default().fg(Color::Green)),
            Span::styled(format!("{}/s  ", format_size(net.sent_per_sec)), Style::default().fg(Color::Green)),
            Span::styled("▼ ", Style::default().fg(Color::Yellow)),
            Span::styled(format!("{}/s", format_size(net.recv_per_sec)), Style::default().fg(Color::Yellow)),
        ]));
    }

    // Per-app network usage
    if !snap.net_apps.is_empty() {
        lines.push(Line::from(""));
        let max_apps = (inner.height as usize).saturating_sub(lines.len());
        for app in snap.net_apps.iter().take(max_apps) {
            let conns = app.connections.len();
            let remote_hint = app
                .connections
                .first()
                .and_then(|c| {
                    if c.remote.is_empty() {
                        None
                    } else {
                        // Show just host part (strip port)
                        let host = c.remote.split(':').next().unwrap_or(&c.remote);
                        Some(host.to_string())
                    }
                })
                .unwrap_or_default();

            let extra_remotes = if conns > 1 {
                format!(" +{}", conns - 1)
            } else {
                String::new()
            };

            let mut spans = vec![
                Span::styled(
                    format!("{:<14}", truncate_str(&app.name, 14)),
                    Style::default().fg(Color::White),
                ),
            ];

            if app.bytes_in > 0 || app.bytes_out > 0 {
                spans.push(Span::styled(
                    format!("▲{:<8}", format_size(app.bytes_out)),
                    Style::default().fg(Color::Green),
                ));
                spans.push(Span::styled(
                    format!("▼{:<8}", format_size(app.bytes_in)),
                    Style::default().fg(Color::Yellow),
                ));
            } else {
                spans.push(Span::styled(
                    format!("{} conn", conns),
                    Style::default().fg(Color::DarkGray),
                ));
                spans.push(Span::raw("  "));
            }

            if !remote_hint.is_empty() {
                spans.push(Span::styled(
                    format!(" → {}{}", remote_hint, extra_remotes),
                    Style::default().fg(Color::DarkGray),
                ));
            }

            lines.push(Line::from(spans));
        }
    } else if snap.network.is_none() {
        lines.push(Line::from(Span::styled(
            "No network data",
            Style::default().fg(Color::DarkGray),
        )));
    }

    frame.render_widget(Paragraph::new(lines), inner);
}

fn truncate_str(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        s[..max].to_string()
    }
}

// ---------------------------------------------------------------------------
// Disk I/O section
// ---------------------------------------------------------------------------

fn draw_disk_io_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Disk I/O ")
        .title_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    if let Some(ref io) = snap.disk_io {
        let line = Line::from(vec![
            Span::styled("R: ", Style::default().fg(Color::Green)),
            Span::styled(
                format!("{}/s  ", format_size(io.read_per_sec)),
                Style::default().fg(Color::White),
            ),
            Span::styled("W: ", Style::default().fg(Color::Yellow)),
            Span::styled(
                format!("{}/s", format_size(io.write_per_sec)),
                Style::default().fg(Color::White),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), inner);
    }
}

// ---------------------------------------------------------------------------
// GPU section
// ---------------------------------------------------------------------------

fn draw_gpu_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" GPU ")
        .title_style(Style::default().fg(Color::LightMagenta).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    if let Some(ref gpu) = snap.gpu {
        let util_str = if let Some(util) = gpu.utilization {
            format!("{:.0}% util", util)
        } else {
            "N/A".to_string()
        };

        let vram_str = match (gpu.vram_used, gpu.vram_total) {
            (Some(used), Some(total)) => {
                format!("  VRAM: {}/{}", format_size(used), format_size(total))
            }
            _ => String::new(),
        };

        let line = Line::from(vec![
            Span::styled(
                format!("{}: ", gpu.name),
                Style::default().fg(Color::Cyan),
            ),
            Span::styled(util_str, Style::default().fg(Color::LightMagenta)),
            Span::styled(vram_str, Style::default().fg(Color::White)),
        ]);
        frame.render_widget(Paragraph::new(line), inner);
    } else {
        frame.render_widget(
            Paragraph::new(Span::styled("GPU info unavailable", Style::default().fg(Color::DarkGray))),
            inner,
        );
    }
}

// ---------------------------------------------------------------------------
// Battery section
// ---------------------------------------------------------------------------

fn draw_battery_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Battery ")
        .title_style(Style::default().fg(Color::Green).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    if let Some(ref bat) = snap.battery {
        let pct = bat.percent;
        let bat_color = if pct > 50.0 {
            Color::Green
        } else if pct > 20.0 {
            Color::Yellow
        } else {
            Color::Red
        };

        let status = if bat.charging { "charging" } else { "discharging" };
        let time_str = bat
            .time_remaining
            .as_ref()
            .map(|t| format!("  {}", t))
            .unwrap_or_default();

        // Mini bar
        let bar_width = 10usize;
        let filled = ((pct as f64 / 100.0) * bar_width as f64).round() as usize;
        let empty = bar_width.saturating_sub(filled);

        let line = Line::from(vec![
            Span::styled("█".repeat(filled), Style::default().fg(bat_color)),
            Span::styled("░".repeat(empty), Style::default().fg(Color::Rgb(50, 50, 50))),
            Span::styled(
                format!(" {:.0}% {}{}", pct, status, time_str),
                Style::default().fg(bat_color),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), inner);
    } else {
        frame.render_widget(
            Paragraph::new(Span::styled("No battery", Style::default().fg(Color::DarkGray))),
            inner,
        );
    }
}

// ---------------------------------------------------------------------------
// Volumes section
// ---------------------------------------------------------------------------

fn draw_volumes_section(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Volumes ")
        .title_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 || snap.volumes.is_empty() {
        return;
    }

    let items: Vec<ListItem> = snap
        .volumes
        .iter()
        .take(inner.height as usize)
        .map(|vol| {
            let pct = if vol.total > 0 {
                vol.used as f64 / vol.total as f64
            } else {
                0.0
            };
            let color = if pct > 0.9 {
                Color::Red
            } else if pct > 0.7 {
                Color::Yellow
            } else {
                Color::Green
            };

            let bar_width = 8usize;
            let filled = (pct * bar_width as f64).round() as usize;
            let empty = bar_width.saturating_sub(filled);

            let mount = if vol.mount_point.len() > 12 {
                &vol.mount_point[..12]
            } else {
                &vol.mount_point
            };

            ListItem::new(Line::from(vec![
                Span::styled(format!("{:<12} ", mount), Style::default().fg(Color::Cyan)),
                Span::styled("█".repeat(filled), Style::default().fg(color)),
                Span::styled("░".repeat(empty), Style::default().fg(Color::Rgb(50, 50, 50))),
                Span::styled(
                    format!(" {}/{}", format_size(vol.used), format_size(vol.total)),
                    Style::default().fg(color),
                ),
            ]))
        })
        .collect();

    frame.render_widget(List::new(items), inner);
}

// ---------------------------------------------------------------------------
// Process section
// ---------------------------------------------------------------------------

fn draw_process_section(frame: &mut Frame, snap: &SystemSnapshot, state: &SystemTabState, area: Rect) {
    // Sort indicator in title
    let sort_label = match state.sort_by {
        ProcessSort::Cpu => "CPU",
        ProcessSort::Mem => "MEM",
        ProcessSort::Pid => "PID",
        ProcessSort::Name => "Name",
    };
    let sort_arrow = if state.sort_ascending { "▲" } else { "▼" };
    let title = format!(" Processes (sorted by {} {}) ", sort_label, sort_arrow);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .title_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    // Filter bar
    let (filter_height, list_start_y) = if state.filter_active || !state.filter.is_empty() {
        (1u16, 1u16)
    } else {
        (0u16, 0u16)
    };

    if filter_height > 0 {
        let filter_area = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        };
        let filter_line = Line::from(vec![
            Span::styled("Filter: ", Style::default().fg(Color::Cyan)),
            Span::styled(
                state.filter.clone(),
                Style::default().fg(Color::White),
            ),
            if state.filter_active {
                Span::styled("█", Style::default().fg(Color::White).add_modifier(Modifier::SLOW_BLINK))
            } else {
                Span::raw("")
            },
        ]);
        frame.render_widget(
            Paragraph::new(filter_line).style(Style::default().bg(Color::Rgb(20, 20, 40))),
            filter_area,
        );
    }

    // Confirm kill overlay
    if state.confirm_kill {
        let confirm_area = Rect {
            x: inner.x,
            y: inner.y + list_start_y,
            width: inner.width,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled(
                " Kill selected process? ",
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            ),
            Span::styled("y", Style::default().fg(Color::Green)),
            Span::styled(" confirm  ", Style::default().fg(Color::Gray)),
            Span::styled("any other key", Style::default().fg(Color::Red)),
            Span::styled(" cancel", Style::default().fg(Color::Gray)),
        ]);
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(Color::Rgb(40, 10, 10))),
            confirm_area,
        );
        return;
    }

    let remaining_height = inner.height.saturating_sub(list_start_y + 1); // +1 for header
    let header_area = Rect {
        x: inner.x,
        y: inner.y + list_start_y,
        width: inner.width,
        height: 1,
    };
    let list_area = Rect {
        x: inner.x,
        y: inner.y + list_start_y + 1,
        width: inner.width,
        height: remaining_height,
    };

    let wide = inner.width >= 90;

    // Header with sort indicators
    let header = build_header(state, wide);
    frame.render_widget(
        Paragraph::new(header).style(Style::default().bg(Color::Rgb(40, 40, 40))),
        header_area,
    );

    // Build filtered + sorted process list
    let filter_lower = state.filter.to_lowercase();
    let mut filtered: Vec<&ProcessInfo> = snap
        .processes
        .iter()
        .filter(|p| {
            filter_lower.is_empty() || p.name.to_lowercase().contains(&filter_lower)
        })
        .collect();

    // Sort
    match state.sort_by {
        ProcessSort::Cpu => filtered.sort_by(|a, b| {
            if state.sort_ascending {
                a.cpu_percent.partial_cmp(&b.cpu_percent).unwrap_or(std::cmp::Ordering::Equal)
            } else {
                b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap_or(std::cmp::Ordering::Equal)
            }
        }),
        ProcessSort::Mem => filtered.sort_by(|a, b| {
            if state.sort_ascending {
                a.mem_bytes.cmp(&b.mem_bytes)
            } else {
                b.mem_bytes.cmp(&a.mem_bytes)
            }
        }),
        ProcessSort::Pid => filtered.sort_by(|a, b| {
            if state.sort_ascending {
                a.pid.cmp(&b.pid)
            } else {
                b.pid.cmp(&a.pid)
            }
        }),
        ProcessSort::Name => filtered.sort_by(|a, b| {
            if state.sort_ascending {
                a.name.cmp(&b.name)
            } else {
                b.name.cmp(&a.name)
            }
        }),
    }

    let max_rows = list_area.height as usize;
    let cmd_max = if wide {
        (list_area.width as usize).saturating_sub(55)
    } else {
        (list_area.width as usize).saturating_sub(35)
    };

    let items: Vec<ListItem> = filtered
        .iter()
        .enumerate()
        .take(max_rows)
        .map(|(idx, p)| {
            let is_selected = idx == state.selected_process;
            let cpu_color = if p.cpu_percent > 80.0 {
                Color::Red
            } else if p.cpu_percent > 30.0 {
                Color::Yellow
            } else {
                Color::White
            };

            let name_display = if p.name.len() > cmd_max {
                &p.name[..cmd_max]
            } else {
                &p.name
            };

            let user_display = if p.user.len() > 10 {
                &p.user[..10]
            } else {
                &p.user
            };

            let bg = if is_selected {
                Color::Rgb(60, 60, 80)
            } else {
                Color::Reset
            };

            let mut spans = vec![
                Span::styled(format!(" {:>6}", p.pid), Style::default().fg(Color::DarkGray).bg(bg)),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(format!("{:<10}", user_display), Style::default().fg(Color::Cyan).bg(bg)),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(format!("{:>5.1}", p.cpu_percent), Style::default().fg(cpu_color).bg(bg)),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    format!("{:>8}", format_size(p.mem_bytes)),
                    Style::default().fg(Color::Magenta).bg(bg),
                ),
                Span::styled("  ", Style::default().bg(bg)),
            ];

            if wide {
                spans.push(Span::styled(
                    format!("{:>6}", format_size(p.disk_read)),
                    Style::default().fg(Color::Green).bg(bg),
                ));
                spans.push(Span::styled("  ", Style::default().bg(bg)));
                spans.push(Span::styled(
                    format!("{:>6}", format_size(p.disk_write)),
                    Style::default().fg(Color::Yellow).bg(bg),
                ));
                spans.push(Span::styled("  ", Style::default().bg(bg)));
            }

            spans.push(Span::styled(name_display, Style::default().fg(Color::White).bg(bg)));

            ListItem::new(Line::from(spans))
        })
        .collect();

    frame.render_widget(List::new(items), list_area);
}

fn build_header(state: &SystemTabState, wide: bool) -> Line<'static> {
    let arrow = |col: ProcessSort| -> &'static str {
        if state.sort_by == col {
            if state.sort_ascending { " ▲" } else { " ▼" }
        } else {
            "  "
        }
    };

    let mut spans = vec![
        Span::styled(
            format!(" {:>6}  {:<10}  {:>5}{}  {:>8}{}",
                "PID",
                "USER",
                "CPU%", arrow(ProcessSort::Cpu),
                "MEM", arrow(ProcessSort::Mem),
            ),
            Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
        ),
    ];

    if wide {
        spans.push(Span::styled(
            format!("  {:>6}  {:>6}", "R/s", "W/s"),
            Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
        ));
    }

    spans.push(Span::styled(
        "  COMMAND",
        Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
    ));

    Line::from(spans)
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn draw_resource_bar(
    frame: &mut Frame,
    label: &str,
    ratio: f64,
    detail: &str,
    color: Color,
    area: Rect,
) {
    let label_width = 4;
    let detail_width = detail.len() + 1;
    let bar_width = (area.width as usize).saturating_sub(label_width + detail_width);
    let filled = (ratio * bar_width as f64).round() as usize;
    let empty = bar_width.saturating_sub(filled);

    let line = Line::from(vec![
        Span::styled(format!("{:<4}", label), Style::default().fg(Color::Cyan)),
        Span::styled("█".repeat(filled), Style::default().fg(color)),
        Span::styled("░".repeat(empty), Style::default().fg(Color::Rgb(50, 50, 50))),
        Span::styled(format!(" {}", detail), Style::default().fg(color)),
    ]);

    frame.render_widget(Paragraph::new(line), area);
}
