use ratatui::prelude::*;
use ratatui::widgets::*;

use crate::system_monitor::SystemSnapshot;
use crate::ui::format_size;

pub fn draw(frame: &mut Frame, snapshot: &SystemSnapshot, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(cpu_section_height(snapshot)),
            Constraint::Length(4),  // Memory + Swap + Load
            Constraint::Min(5),    // Process list
        ])
        .split(area);

    draw_cpu_bars(frame, snapshot, chunks[0]);
    draw_memory_section(frame, snapshot, chunks[1]);
    draw_process_list(frame, snapshot, chunks[2]);
}

fn cpu_section_height(snap: &SystemSnapshot) -> u16 {
    let cores = snap.cpu_usage_per_core.len();
    // Two columns of CPU bars + 1 for the header
    let rows = (cores + 1) / 2;
    (rows as u16 + 1).min(10)
}

fn draw_cpu_bars(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
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

    // Two-column layout
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(inner);

    let half = (cores.len() + 1) / 2;
    let left_cores = &cores[..half];
    let right_cores = &cores[half..];

    draw_cpu_column(frame, left_cores, 0, cols[0]);
    draw_cpu_column(frame, right_cores, half, cols[1]);
}

fn draw_cpu_column(frame: &mut Frame, cores: &[f32], start_idx: usize, area: Rect) {
    for (i, &usage) in cores.iter().enumerate() {
        if i as u16 >= area.height {
            break;
        }
        let row = Rect {
            x: area.x,
            y: area.y + i as u16,
            width: area.width,
            height: 1,
        };

        let label_width = 5; // "C00 "
        let bar_width = row.width.saturating_sub(label_width + 6) as usize; // 6 for " XXX%"
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
            Span::styled(
                "█".repeat(filled),
                Style::default().fg(color),
            ),
            Span::styled(
                "░".repeat(empty),
                Style::default().fg(Color::Rgb(50, 50, 50)),
            ),
            Span::styled(
                format!("{:>5.1}%", usage),
                Style::default().fg(color),
            ),
        ]);

        frame.render_widget(Paragraph::new(line), row);
    }
}

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
        .constraints([Constraint::Length(1), Constraint::Length(1)])
        .split(inner);

    // RAM bar
    let mem_pct = if snap.mem_total > 0 {
        snap.mem_used as f64 / snap.mem_total as f64
    } else {
        0.0
    };
    draw_resource_bar(
        frame,
        "RAM",
        mem_pct,
        &format!("{} / {}", format_size(snap.mem_used), format_size(snap.mem_total)),
        if mem_pct > 0.9 { Color::Red } else if mem_pct > 0.7 { Color::Yellow } else { Color::Green },
        rows[0],
    );

    // Swap + load + uptime on same line
    if rows.len() > 1 {
        let swap_pct = if snap.swap_total > 0 {
            snap.swap_used as f64 / snap.swap_total as f64
        } else {
            0.0
        };

        let hours = snap.uptime / 3600;
        let mins = (snap.uptime % 3600) / 60;

        let line = Line::from(vec![
            Span::styled("Swp ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{}/{}", format_size(snap.swap_used), format_size(snap.swap_total)),
                Style::default().fg(if swap_pct > 0.5 { Color::Yellow } else { Color::Green }),
            ),
            Span::styled("   Load ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{:.2} {:.2} {:.2}", snap.load_avg.0, snap.load_avg.1, snap.load_avg.2),
                Style::default().fg(Color::White),
            ),
            Span::styled("   Up ", Style::default().fg(Color::Cyan)),
            Span::styled(
                format!("{}h {}m", hours, mins),
                Style::default().fg(Color::White),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), rows[1]);
    }
}

fn draw_resource_bar(
    frame: &mut Frame,
    label: &str,
    ratio: f64,
    detail: &str,
    color: Color,
    area: Rect,
) {
    let label_width = 4;
    let detail_width = detail.len() + 2;
    let bar_width = area.width.saturating_sub(label_width as u16 + detail_width as u16) as usize;
    let filled = ((ratio) * bar_width as f64).round() as usize;
    let empty = bar_width.saturating_sub(filled);

    let line = Line::from(vec![
        Span::styled(
            format!("{:<4}", label),
            Style::default().fg(Color::Cyan),
        ),
        Span::styled("█".repeat(filled), Style::default().fg(color)),
        Span::styled(
            "░".repeat(empty),
            Style::default().fg(Color::Rgb(50, 50, 50)),
        ),
        Span::styled(
            format!(" {}", detail),
            Style::default().fg(color),
        ),
    ]);

    frame.render_widget(Paragraph::new(line), area);
}

fn draw_process_list(frame: &mut Frame, snap: &SystemSnapshot, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Processes ")
        .title_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 {
        return;
    }

    // Header
    let header_area = Rect { height: 1, ..inner };
    let header = Line::from(vec![
        Span::styled(
            format!(
                " {:>6}  {:<10}  {:>5}  {:>8}  {}",
                "PID", "USER", "CPU%", "MEM", "COMMAND"
            ),
            Style::default()
                .fg(Color::White)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(header).style(Style::default().bg(Color::Rgb(40, 40, 40))),
        header_area,
    );

    // Process rows
    let list_area = Rect {
        y: inner.y + 1,
        height: inner.height.saturating_sub(1),
        ..inner
    };

    let max_rows = list_area.height as usize;
    let cmd_max = list_area.width.saturating_sub(35) as usize;

    let items: Vec<ListItem> = snap
        .processes
        .iter()
        .take(max_rows)
        .map(|p| {
            let cpu_color = if p.cpu_percent > 80.0 {
                Color::Red
            } else if p.cpu_percent > 30.0 {
                Color::Yellow
            } else {
                Color::White
            };

            let cmd = if p.name.len() > cmd_max {
                &p.name[..cmd_max]
            } else {
                &p.name
            };

            let user = if p.user.len() > 10 {
                &p.user[..10]
            } else {
                &p.user
            };

            ListItem::new(Line::from(vec![
                Span::styled(
                    format!(" {:>6}", p.pid),
                    Style::default().fg(Color::DarkGray),
                ),
                Span::raw("  "),
                Span::styled(
                    format!("{:<10}", user),
                    Style::default().fg(Color::Cyan),
                ),
                Span::raw("  "),
                Span::styled(
                    format!("{:>5.1}", p.cpu_percent),
                    Style::default().fg(cpu_color),
                ),
                Span::raw("  "),
                Span::styled(
                    format!("{:>8}", format_size(p.mem_bytes)),
                    Style::default().fg(Color::Magenta),
                ),
                Span::raw("  "),
                Span::styled(cmd, Style::default().fg(Color::White)),
            ]))
        })
        .collect();

    frame.render_widget(List::new(items), list_area);
}
