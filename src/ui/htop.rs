use fuzzy_matcher::FuzzyMatcher;
use fuzzy_matcher::skim::SkimMatcherV2;
use ratatui::prelude::*;
use ratatui::widgets::*;

use crate::alerts::{Alert, AlertLevel};
use crate::app::{GroupMode, ProcessSort, SystemTabState};
use crate::system_monitor::{ProcessInfo, SystemSnapshot};
use crate::ui::format_size;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn draw(
    frame: &mut Frame,
    snap: &SystemSnapshot,
    state: &SystemTabState,
    alerts: &[Alert],
    history: &crate::history::History,
    area: Rect,
) {
    // Determine whether we need an alert bar (1 line tall)
    let has_critical = alerts.iter().any(|a| a.level == AlertLevel::Critical);
    let has_warning = alerts.iter().any(|a| a.level == AlertLevel::Warning);
    let alert_height: u16 = if has_critical || has_warning { 1 } else { 0 };

    // Determine whether we need an anomaly indicator line
    let latest_anomalies = history.latest_anomalies();
    let anomaly_height: u16 = if latest_anomalies.is_empty() { 0 } else { 1 };

    // If diff mode is active, reserve space for diff panel above process list
    let diff_height: u16 = if state.show_diff { 5 } else { 0 };

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(alert_height),     // Alert bar (0 when no alerts)
            Constraint::Min(12),                  // Top panels
            Constraint::Length(anomaly_height),   // Anomaly indicator (0 when none)
            Constraint::Length(diff_height),      // Diff overlay (0 when hidden)
            Constraint::Min(8),                   // Process list
        ])
        .split(area);

    // Render the alert bar if needed
    if alert_height > 0 {
        draw_alert_bar(frame, alerts, has_critical, rows[0]);
    }

    draw_top_panels(frame, snap, rows[1]);

    // Render anomaly indicators between top panels and process list
    if anomaly_height > 0 {
        draw_anomaly_bar(frame, &latest_anomalies, rows[2]);
    }

    if state.show_diff {
        draw_diff_panel(frame, snap, rows[3]);
    }
    draw_process_section(frame, snap, state, rows[4]);
}

// ---------------------------------------------------------------------------
// Alert bar
// ---------------------------------------------------------------------------

fn draw_alert_bar(frame: &mut Frame, alerts: &[Alert], is_critical: bool, area: Rect) {
    let (bg, fg) = if is_critical {
        (Color::Red, Color::White)
    } else {
        (Color::Yellow, Color::Black)
    };

    let messages: Vec<String> = alerts.iter().map(|a| a.message.clone()).collect();
    let text = messages.join("  |  ");

    let style = if is_critical {
        Style::default()
            .bg(bg)
            .fg(fg)
            .add_modifier(Modifier::BOLD | Modifier::RAPID_BLINK)
    } else {
        Style::default().bg(bg).fg(fg).add_modifier(Modifier::BOLD)
    };

    let bar = Paragraph::new(format!(" {text} "))
        .style(style)
        .alignment(Alignment::Center);
    frame.render_widget(bar, area);
}

// ---------------------------------------------------------------------------
// Anomaly indicator bar
// ---------------------------------------------------------------------------

fn draw_anomaly_bar(
    frame: &mut Frame,
    anomalies: &[&crate::history::AnomalyEvent],
    area: Rect,
) {
    use crate::history::AnomalyEvent;

    let mut spans: Vec<Span> = Vec::new();
    spans.push(Span::raw(" "));

    for (i, anomaly) in anomalies.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled("  |  ", Style::default().fg(Color::DarkGray)));
        }
        match anomaly {
            AnomalyEvent::CpuSpike { value, threshold } => {
                spans.push(Span::styled(
                    format!("! CPU spike: {:.1}% (avg {:.1}%)", value, threshold),
                    Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                ));
            }
            AnomalyEvent::MemoryJump { delta_bytes } => {
                let mib = *delta_bytes / (1024 * 1024);
                spans.push(Span::styled(
                    format!("! Memory jump: +{} MiB", mib),
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                ));
            }
            AnomalyEvent::NewHeavyProcess { pid, name, cpu } => {
                spans.push(Span::styled(
                    format!("! New: {} (PID {}) at {:.0}% CPU", name, pid, cpu),
                    Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                ));
            }
        }
    }

    let line = Line::from(spans);
    frame.render_widget(Paragraph::new(line), area);
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

    let blocks = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

    let value_to_block = |v: f32| -> char {
        if v < 0.5 {
            '·'
        } else {
            let idx = ((v / 100.0) * 6.0 + 1.0).min(7.0) as usize;
            blocks[idx]
        }
    };

    // Find the 4 hottest cores by their latest usage
    let per_core = &snap.cpu_per_core_history;
    if per_core.is_empty() {
        // Fallback: render total CPU history
        let history = &snap.cpu_history;
        let label = "Hist: ";
        let label_len = label.len();
        let chart_width = (area.width as usize).saturating_sub(label_len);
        if chart_width == 0 {
            return;
        }
        let mut chart_chars: Vec<Span> = Vec::new();
        let data_count = history.len().min(chart_width);
        let pad_count = chart_width.saturating_sub(data_count);
        if pad_count > 0 {
            chart_chars.push(Span::styled(
                "·".repeat(pad_count),
                Style::default().fg(Color::Rgb(50, 50, 50)),
            ));
        }
        let start = history.len().saturating_sub(chart_width);
        for &v in &history[start..] {
            let ch = value_to_block(v);
            let color = if v > 80.0 { Color::Red } else if v > 50.0 { Color::Yellow } else { Color::Green };
            chart_chars.push(Span::styled(ch.to_string(), Style::default().fg(color)));
        }
        let mut spans = vec![Span::styled(label, Style::default().fg(Color::Cyan))];
        spans.extend(chart_chars);
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
        return;
    }

    // Pick up to 4 hottest cores (by latest value)
    let mut indexed: Vec<(usize, f32)> = per_core
        .iter()
        .enumerate()
        .map(|(i, hist)| (i, hist.last().copied().unwrap_or(0.0)))
        .collect();
    indexed.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let hot_cores: Vec<usize> = indexed.iter().take(4).map(|(i, _)| *i).collect();

    // Each core gets: "C00:▂▃▅  " — label(4) + sparkline(~12) + gap(2)
    // We'll show up to 4 in one line if width allows
    let core_label_width = 4usize; // "C00:"
    let gap = 2usize;
    let total_cores = hot_cores.len();
    if total_cores == 0 {
        return;
    }

    // Calculate how many chars each sparkline gets
    let available = area.width as usize;
    let per_core_total = available / total_cores.max(1);
    let sparkline_width = per_core_total.saturating_sub(core_label_width + gap).max(4);

    let mut spans: Vec<Span> = Vec::new();

    for (slot, &core_idx) in hot_cores.iter().enumerate() {
        let hist = &per_core[core_idx];

        // Core label
        spans.push(Span::styled(
            format!("C{:02}:", core_idx),
            Style::default().fg(Color::Cyan),
        ));

        // Sparkline chars
        let data_count = hist.len().min(sparkline_width);
        let pad_count = sparkline_width.saturating_sub(data_count);
        if pad_count > 0 {
            spans.push(Span::styled(
                "·".repeat(pad_count),
                Style::default().fg(Color::Rgb(50, 50, 50)),
            ));
        }
        let start = hist.len().saturating_sub(sparkline_width);
        for &v in &hist[start..] {
            let ch = value_to_block(v);
            let color = if v > 80.0 { Color::Red } else if v > 50.0 { Color::Yellow } else { Color::Green };
            spans.push(Span::styled(ch.to_string(), Style::default().fg(color)));
        }

        // Gap between cores (not after last)
        if slot + 1 < total_cores {
            spans.push(Span::raw("  "));
        }
    }

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
            Constraint::Length(1), // Segmented RAM bar
            Constraint::Length(1), // Memory breakdown compact text
            Constraint::Length(1), // Memory pressure indicator
            Constraint::Length(1), // Swap + load
            Constraint::Length(1), // Tasks/threads + uptime
        ])
        .split(inner);

    // Row 0: Segmented RAM bar (wired=red, active=yellow, compressed=magenta, inactive=darkgray, free=empty)
    if rows[0].y < inner.y + inner.height {
        draw_segmented_mem_bar(frame, snap, rows[0]);
    }

    // Row 1: Compact memory breakdown text
    if rows[1].y < inner.y + inner.height {
        if let Some(ref bd) = snap.mem_breakdown {
            let line = Line::from(vec![
                Span::styled(" wired:", Style::default().fg(Color::Red)),
                Span::styled(
                    format!("{}  ", format_size(bd.wired)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("active:", Style::default().fg(Color::Yellow)),
                Span::styled(
                    format!("{}  ", format_size(bd.active)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("compr:", Style::default().fg(Color::Magenta)),
                Span::styled(
                    format!("{}  ", format_size(bd.compressed)),
                    Style::default().fg(Color::White),
                ),
                Span::styled("inact:", Style::default().fg(Color::DarkGray)),
                Span::styled(
                    format_size(bd.inactive),
                    Style::default().fg(Color::White),
                ),
            ]);
            frame.render_widget(Paragraph::new(line), rows[1]);
        }
    }

    // Row 2: Memory pressure indicator
    if rows[2].y < inner.y + inner.height {
        let level = snap.mem_pressure_level;
        let pressure_line = if level > 50 {
            Line::from(vec![
                Span::styled(" Pressure: ", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("Normal ({}%)", level),
                    Style::default().fg(Color::Green),
                ),
            ])
        } else if level >= 25 {
            Line::from(vec![
                Span::styled(" Pressure: ", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("Warning ({}%)", level),
                    Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                ),
            ])
        } else {
            Line::from(vec![
                Span::styled(" Pressure: ", Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("CRITICAL ({}%)", level),
                    Style::default()
                        .fg(Color::Red)
                        .add_modifier(Modifier::BOLD | Modifier::RAPID_BLINK),
                ),
            ])
        };
        frame.render_widget(Paragraph::new(pressure_line), rows[2]);
    }

    // Row 3: Swap + load
    if rows.len() > 3 && rows[3].y < inner.y + inner.height {
        let swap_pct = if snap.swap_total > 0 {
            snap.swap_used as f64 / snap.swap_total as f64
        } else {
            0.0
        };
        let line = Line::from(vec![
            Span::styled(" Swp ", Style::default().fg(Color::Cyan)),
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
        frame.render_widget(Paragraph::new(line), rows[3]);
    }

    // Row 4: Tasks + threads + uptime
    if rows.len() > 4 && rows[4].y < inner.y + inner.height {
        let hours = snap.uptime / 3600;
        let mins = (snap.uptime % 3600) / 60;
        let line = Line::from(vec![
            Span::styled(" Tasks:", Style::default().fg(Color::Cyan)),
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
        frame.render_widget(Paragraph::new(line), rows[4]);
    }
}

/// Draw a segmented memory bar showing wired/active/compressed/inactive/free portions.
fn draw_segmented_mem_bar(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    if area.width == 0 || snap.mem_total == 0 {
        return;
    }

    let label = "RAM ";
    let label_width = label.len();
    let suffix = format!(" {}/{}", format_size(snap.mem_used), format_size(snap.mem_total));
    let suffix_width = suffix.len();
    let bar_width = (area.width as usize).saturating_sub(label_width + suffix_width);

    if bar_width == 0 {
        return;
    }

    let total = snap.mem_total as f64;
    let (wired_w, active_w, compressed_w, inactive_w) = if let Some(ref bd) = snap.mem_breakdown {
        let wired_w = ((bd.wired as f64 / total) * bar_width as f64).round() as usize;
        let active_w = ((bd.active as f64 / total) * bar_width as f64).round() as usize;
        let compressed_w = ((bd.compressed as f64 / total) * bar_width as f64).round() as usize;
        let inactive_w = ((bd.inactive as f64 / total) * bar_width as f64).round() as usize;
        (wired_w, active_w, compressed_w, inactive_w)
    } else {
        // Fallback: single color bar using mem_used
        let used_w = ((snap.mem_used as f64 / total) * bar_width as f64).round() as usize;
        let empty_w = bar_width.saturating_sub(used_w);
        let mem_pct = snap.mem_used as f64 / total;
        let color = if mem_pct > 0.9 { Color::Red } else if mem_pct > 0.7 { Color::Yellow } else { Color::Green };
        let mut spans = vec![Span::styled(label, Style::default().fg(Color::Cyan))];
        spans.push(Span::styled("█".repeat(used_w), Style::default().fg(color)));
        spans.push(Span::styled("░".repeat(empty_w), Style::default().fg(Color::Rgb(50, 50, 50))));
        spans.push(Span::styled(suffix, Style::default().fg(color)));
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
        return;
    };

    // Clamp so segments don't overflow bar_width
    let used_w = wired_w + active_w + compressed_w + inactive_w;
    let (wired_w, active_w, compressed_w, inactive_w) = if used_w > bar_width {
        let scale = bar_width as f64 / used_w as f64;
        (
            (wired_w as f64 * scale) as usize,
            (active_w as f64 * scale) as usize,
            (compressed_w as f64 * scale) as usize,
            (inactive_w as f64 * scale) as usize,
        )
    } else {
        (wired_w, active_w, compressed_w, inactive_w)
    };

    let filled = wired_w + active_w + compressed_w + inactive_w;
    let free_w = bar_width.saturating_sub(filled);

    let mem_pct = snap.mem_used as f64 / total;
    let summary_color = if mem_pct > 0.9 { Color::Red } else if mem_pct > 0.7 { Color::Yellow } else { Color::Green };

    let mut spans = vec![Span::styled(label, Style::default().fg(Color::Cyan))];
    if wired_w > 0 {
        spans.push(Span::styled("█".repeat(wired_w), Style::default().fg(Color::Red)));
    }
    if active_w > 0 {
        spans.push(Span::styled("█".repeat(active_w), Style::default().fg(Color::Yellow)));
    }
    if compressed_w > 0 {
        spans.push(Span::styled("█".repeat(compressed_w), Style::default().fg(Color::Magenta)));
    }
    if inactive_w > 0 {
        spans.push(Span::styled("█".repeat(inactive_w), Style::default().fg(Color::Rgb(80, 80, 80))));
    }
    if free_w > 0 {
        spans.push(Span::styled("░".repeat(free_w), Style::default().fg(Color::Rgb(50, 50, 50))));
    }
    spans.push(Span::styled(suffix, Style::default().fg(summary_color)));

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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
        let total = io.read_per_sec + io.write_per_sec;
        let line = if io.write_per_sec > 0 {
            Line::from(vec![
                Span::styled("R: ", Style::default().fg(Color::Green)),
                Span::styled(format!("{}/s  ", format_size(io.read_per_sec)), Style::default().fg(Color::White)),
                Span::styled("W: ", Style::default().fg(Color::Yellow)),
                Span::styled(format!("{}/s", format_size(io.write_per_sec)), Style::default().fg(Color::White)),
            ])
        } else {
            Line::from(vec![
                Span::styled("Throughput: ", Style::default().fg(Color::Cyan)),
                Span::styled(format!("{}/s", format_size(total)), Style::default().fg(Color::White)),
            ])
        };
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

    // Build title showing mode indicator
    let mode_suffix = match state.group_mode {
        GroupMode::None => {
            if state.tree_mode {
                " [Tree]".to_string()
            } else {
                String::new()
            }
        }
        GroupMode::ByApp => " (grouped by App ▼)".to_string(),
        GroupMode::ByUser => " (grouped by User ▼)".to_string(),
    };
    let title = format!(" Processes (sorted by {} {}{}) ", sort_label, sort_arrow, mode_suffix);

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

    // Dispatch to appropriate rendering mode
    if state.group_mode != GroupMode::None {
        draw_grouped_processes(frame, snap, state, list_area, wide);
    } else if state.tree_mode {
        draw_tree_processes(frame, snap, state, list_area, wide);
    } else {
        draw_flat_processes(frame, snap, state, list_area, wide);
    }
}

/// Render processes in flat sorted list (original behavior).
fn draw_flat_processes(
    frame: &mut Frame,
    snap: &SystemSnapshot,
    state: &SystemTabState,
    list_area: Rect,
    wide: bool,
) {
    let matcher = SkimMatcherV2::default();
    let mut filtered_with_score: Vec<(i64, &ProcessInfo)> = snap
        .processes
        .iter()
        .filter_map(|p| {
            if state.filter.is_empty() {
                Some((0i64, p))
            } else {
                matcher.fuzzy_match(&p.name, &state.filter).map(|score| (score, p))
            }
        })
        .collect();

    if !state.filter.is_empty() {
        filtered_with_score.sort_by(|(score_a, a), (score_b, b)| {
            let score_cmp = score_b.cmp(score_a);
            if score_cmp != std::cmp::Ordering::Equal {
                return score_cmp;
            }
            secondary_sort_cmp(a, b, state)
        });
    } else {
        filtered_with_score.sort_by(|(_, a), (_, b)| secondary_sort_cmp(a, b, state));
    }

    let filtered: Vec<&ProcessInfo> = filtered_with_score.into_iter().map(|(_, p)| p).collect();

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
        .map(|(idx, p)| build_process_list_item(p, "", idx, state.selected_process, wide, cmd_max))
        .collect();

    frame.render_widget(List::new(items), list_area);
}

/// Render processes as a tree (parent-child hierarchy).
fn draw_tree_processes(
    frame: &mut Frame,
    snap: &SystemSnapshot,
    state: &SystemTabState,
    list_area: Rect,
    wide: bool,
) {
    use std::collections::{HashMap, HashSet};

    // Build pid set for fast lookup
    let pid_set: HashSet<u32> = snap.processes.iter().map(|p| p.pid).collect();

    // Build children map: parent_pid -> Vec<&ProcessInfo>
    let mut children: HashMap<u32, Vec<&ProcessInfo>> = HashMap::new();
    let mut roots: Vec<&ProcessInfo> = Vec::new();

    for p in &snap.processes {
        match p.parent_pid {
            Some(ppid) if pid_set.contains(&ppid) => {
                children.entry(ppid).or_default().push(p);
            }
            _ => {
                roots.push(p);
            }
        }
    }

    // Sort roots and children by CPU descending
    roots.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap_or(std::cmp::Ordering::Equal));
    for v in children.values_mut() {
        v.sort_by(|a, b| b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap_or(std::cmp::Ordering::Equal));
    }

    // Flatten tree into (prefix, &ProcessInfo) pairs
    let mut flat: Vec<(String, &ProcessInfo)> = Vec::new();
    flatten_tree(&roots, &children, String::new(), &mut flat);

    let max_rows = list_area.height as usize;
    let cmd_max = if wide {
        (list_area.width as usize).saturating_sub(55)
    } else {
        (list_area.width as usize).saturating_sub(35)
    };

    let items: Vec<ListItem> = flat
        .iter()
        .enumerate()
        .take(max_rows)
        .map(|(idx, (prefix, p))| build_process_list_item(p, prefix, idx, state.selected_process, wide, cmd_max))
        .collect();

    frame.render_widget(List::new(items), list_area);
}

/// Recursively flatten the process tree with tree-drawing characters.
fn flatten_tree<'a>(
    nodes: &[&'a ProcessInfo],
    children: &std::collections::HashMap<u32, Vec<&'a ProcessInfo>>,
    prefix: String,
    out: &mut Vec<(String, &'a ProcessInfo)>,
) {
    let count = nodes.len();
    for (i, node) in nodes.iter().enumerate() {
        let is_last = i + 1 == count;
        let connector = if is_last { "└── " } else { "├── " };
        let my_prefix = format!("{}{}", prefix, connector);
        out.push((my_prefix, node));

        if let Some(kids) = children.get(&node.pid) {
            let child_prefix = if is_last {
                format!("{}    ", prefix)
            } else {
                format!("{}│   ", prefix)
            };
            flatten_tree(kids, children, child_prefix, out);
        }
    }
}

/// Aggregated group entry for group-mode display.
struct GroupEntry {
    display_name: String,
    total_cpu: f32,
    total_mem: u64,
    count: usize,
}

/// Render processes grouped by app name or user.
fn draw_grouped_processes(
    frame: &mut Frame,
    snap: &SystemSnapshot,
    state: &SystemTabState,
    list_area: Rect,
    wide: bool,
) {
    use std::collections::HashMap;

    let groups: Vec<GroupEntry> = match state.group_mode {
        GroupMode::ByApp => {
            let mut map: HashMap<String, GroupEntry> = HashMap::new();
            for p in &snap.processes {
                let key = normalize_app_name(&p.name);
                let e = map.entry(key.clone()).or_insert(GroupEntry {
                    display_name: key,
                    total_cpu: 0.0,
                    total_mem: 0,
                    count: 0,
                });
                e.total_cpu += p.cpu_percent;
                e.total_mem += p.mem_bytes;
                e.count += 1;
            }
            let mut v: Vec<GroupEntry> = map.into_values().collect();
            v.sort_by(|a, b| b.total_cpu.partial_cmp(&a.total_cpu).unwrap_or(std::cmp::Ordering::Equal));
            v
        }
        GroupMode::ByUser => {
            let mut map: HashMap<String, GroupEntry> = HashMap::new();
            for p in &snap.processes {
                let key = if p.user.is_empty() { "unknown".to_string() } else { p.user.clone() };
                let e = map.entry(key.clone()).or_insert(GroupEntry {
                    display_name: key,
                    total_cpu: 0.0,
                    total_mem: 0,
                    count: 0,
                });
                e.total_cpu += p.cpu_percent;
                e.total_mem += p.mem_bytes;
                e.count += 1;
            }
            let mut v: Vec<GroupEntry> = map.into_values().collect();
            v.sort_by(|a, b| b.total_cpu.partial_cmp(&a.total_cpu).unwrap_or(std::cmp::Ordering::Equal));
            v
        }
        GroupMode::None => Vec::new(),
    };

    let max_rows = list_area.height as usize;
    let cmd_max = if wide {
        (list_area.width as usize).saturating_sub(55)
    } else {
        (list_area.width as usize).saturating_sub(35)
    };

    let items: Vec<ListItem> = groups
        .iter()
        .enumerate()
        .take(max_rows)
        .map(|(idx, g)| {
            let is_selected = idx == state.selected_process;
            let bg = if is_selected { Color::Rgb(60, 60, 80) } else { Color::Reset };

            let cpu_color = if g.total_cpu > 80.0 {
                Color::Red
            } else if g.total_cpu > 30.0 {
                Color::Yellow
            } else {
                Color::White
            };

            let name_label = format!("{} ({} procs)", g.display_name, g.count);
            let name_truncated = if name_label.len() > cmd_max + 20 {
                name_label[..cmd_max + 20].to_string()
            } else {
                name_label
            };

            let spans = vec![
                Span::styled(format!("  {:>7}  ", ""), Style::default().fg(Color::DarkGray).bg(bg)),
                Span::styled(format!("{:<12}", ""), Style::default().fg(Color::Cyan).bg(bg)),
                Span::styled(format!("{:>5.1}", g.total_cpu), Style::default().fg(cpu_color).bg(bg)),
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled(
                    format!("{:>10}", format_size(g.total_mem)),
                    Style::default().fg(Color::Magenta).bg(bg),
                ),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(name_truncated, Style::default().fg(Color::White).bg(bg)),
            ];

            ListItem::new(Line::from(spans))
        })
        .collect();

    frame.render_widget(List::new(items), list_area);
}

/// Normalize an app name by stripping common macOS helper suffixes.
fn normalize_app_name(name: &str) -> String {
    let suffixes = [
        " Helper (Renderer)",
        " Helper (GPU)",
        " Helper (Plugin)",
        " Helper",
        " (Renderer)",
        " (GPU)",
        " Renderer",
        " GPU",
    ];
    let mut result = name.to_string();
    for suffix in &suffixes {
        if let Some(stripped) = result.strip_suffix(suffix) {
            result = stripped.to_string();
            break;
        }
    }
    result
}

/// Build a single ListItem for a process row (used in flat and tree modes).
fn build_process_list_item<'a>(
    p: &ProcessInfo,
    prefix: &str,
    idx: usize,
    selected: usize,
    wide: bool,
    cmd_max: usize,
) -> ListItem<'a> {
    let is_selected = idx == selected;
    let cpu_color = if p.cpu_percent > 80.0 {
        Color::Red
    } else if p.cpu_percent > 30.0 {
        Color::Yellow
    } else {
        Color::White
    };

    // Name with tree prefix
    let prefixed_name = format!("{}{}", prefix, p.name);
    let name_display = if prefixed_name.len() > cmd_max {
        prefixed_name[..cmd_max].to_string()
    } else {
        prefixed_name
    };

    let user_display = if p.user.len() > 10 {
        p.user[..10].to_string()
    } else {
        p.user.clone()
    };

    let bg = if is_selected { Color::Rgb(60, 60, 80) } else { Color::Reset };

    let mut spans = vec![
        Span::styled(format!(" {:>7}", p.pid), Style::default().fg(Color::DarkGray).bg(bg)),
        Span::styled("  ", Style::default().bg(bg)),
        Span::styled(format!("{:<12}", user_display), Style::default().fg(Color::Cyan).bg(bg)),
        Span::styled(format!("{:>5.1}", p.cpu_percent), Style::default().fg(cpu_color).bg(bg)),
        Span::styled("    ", Style::default().bg(bg)),
        Span::styled(
            format!("{:>10}", format_size(p.mem_bytes)),
            Style::default().fg(Color::Magenta).bg(bg),
        ),
    ];

    if wide {
        spans.push(Span::styled(
            format!("  {:>9}", format_size(p.disk_read)),
            Style::default().fg(Color::Green).bg(bg),
        ));
        spans.push(Span::styled(
            format!("  {:>9}", format_size(p.disk_write)),
            Style::default().fg(Color::Yellow).bg(bg),
        ));
    }

    spans.push(Span::styled("  ", Style::default().bg(bg)));
    spans.push(Span::styled(name_display, Style::default().fg(Color::White).bg(bg)));

    ListItem::new(Line::from(spans))
}

/// Compare two processes according to the user's selected sort key.
fn secondary_sort_cmp(a: &ProcessInfo, b: &ProcessInfo, state: &SystemTabState) -> std::cmp::Ordering {
    match state.sort_by {
        ProcessSort::Cpu => {
            if state.sort_ascending {
                a.cpu_percent.partial_cmp(&b.cpu_percent).unwrap_or(std::cmp::Ordering::Equal)
            } else {
                b.cpu_percent.partial_cmp(&a.cpu_percent).unwrap_or(std::cmp::Ordering::Equal)
            }
        }
        ProcessSort::Mem => {
            if state.sort_ascending {
                a.mem_bytes.cmp(&b.mem_bytes)
            } else {
                b.mem_bytes.cmp(&a.mem_bytes)
            }
        }
        ProcessSort::Pid => {
            if state.sort_ascending {
                a.pid.cmp(&b.pid)
            } else {
                b.pid.cmp(&a.pid)
            }
        }
        ProcessSort::Name => {
            if state.sort_ascending {
                a.name.cmp(&b.name)
            } else {
                b.name.cmp(&a.name)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Diff panel
// ---------------------------------------------------------------------------

fn draw_diff_panel(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Process Diff (last 5s) — [d] to toggle ")
        .title_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    let diff = &snap.process_diff;
    let mut lines: Vec<Line> = Vec::new();

    // NEW processes (green)
    if !diff.new_pids.is_empty() {
        let names: Vec<String> = diff
            .new_pids
            .iter()
            .take(6)
            .map(|(pid, name)| format!("{} (PID {})", name, pid))
            .collect();
        lines.push(Line::from(vec![
            Span::styled("NEW:    ", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
            Span::styled(names.join(", "), Style::default().fg(Color::Green)),
        ]));
    }

    // EXITED processes (red)
    if !diff.exited_pids.is_empty() {
        let names: Vec<String> = diff
            .exited_pids
            .iter()
            .take(6)
            .map(|(pid, name)| format!("{} (PID {})", name, pid))
            .collect();
        lines.push(Line::from(vec![
            Span::styled("EXITED: ", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(names.join(", "), Style::default().fg(Color::Red)),
        ]));
    }

    // CPU SPIKES (yellow)
    if !diff.cpu_spikes.is_empty() {
        let names: Vec<String> = diff
            .cpu_spikes
            .iter()
            .take(4)
            .map(|(_, name, delta)| format!("{} +{:.1}% CPU", name, delta))
            .collect();
        lines.push(Line::from(vec![
            Span::styled("SPIKE:  ", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
            Span::styled(names.join(", "), Style::default().fg(Color::Yellow)),
        ]));
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "No changes detected (refreshes every 5s)",
            Style::default().fg(Color::DarkGray),
        )));
    }

    frame.render_widget(Paragraph::new(lines), inner);
}

fn build_header(state: &SystemTabState, wide: bool) -> Line<'static> {
    let arrow = |col: ProcessSort| -> &'static str {
        if state.sort_by == col {
            if state.sort_ascending { " ▲" } else { " ▼" }
        } else {
            "  "
        }
    };

    // Fixed column widths: PID=7, USER=12, CPU%=7, MEM=10, R/s=9, W/s=9
    let mut s = format!(
        " {:>7}  {:<12}{:>5}{}  {:>10}",
        "PID", "USER", "CPU%", arrow(ProcessSort::Cpu), "MEM",
    );
    s.push_str(arrow(ProcessSort::Mem));

    let mut spans = vec![
        Span::styled(s, Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
    ];

    if wide {
        spans.push(Span::styled(
            format!("  {:>9}  {:>9}", "R/s", "W/s"),
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
