use crate::app::App;
use crate::ui::format_size;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    if app.scanning {
        draw_scan_progress(frame, app, area);
        return;
    }

    // Layout: [disk_stats(4), spacer(1), top_consumers(7), spacer(1), reclaimable(min 3)]
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4),
            Constraint::Length(1),
            Constraint::Length(7),
            Constraint::Length(1),
            Constraint::Min(3),
        ])
        .split(area);

    draw_disk_stats(frame, app, chunks[0]);
    draw_top_consumers(frame, app, chunks[2]);
    draw_reclaimable(frame, app, chunks[4]);
}

fn draw_scan_progress(frame: &mut Frame, app: &App, area: Rect) {
    let stats = &app.scan_stats;

    // Truncate current_dir to fit the terminal width
    let max_dir_len = area.width.saturating_sub(4) as usize;
    let dir_display = if stats.current_dir.len() > max_dir_len {
        let start = stats.current_dir.len() - max_dir_len + 3;
        format!("...{}", &stats.current_dir[start..])
    } else {
        stats.current_dir.clone()
    };

    let lines = vec![
        Line::from(""),
        Line::from(Span::styled(
            "Scanning filesystem...",
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("  Files: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format!("{:>10}", format_number(stats.files_found)),
                Style::default().fg(Color::Cyan),
            ),
            Span::raw("    "),
            Span::styled("Dirs: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format!("{:>10}", format_number(stats.dirs_found)),
                Style::default().fg(Color::Cyan),
            ),
            Span::raw("    "),
            Span::styled("Size: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format!("{:>10}", format_size(stats.bytes_found)),
                Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("  ", Style::default()),
            Span::styled(dir_display, Style::default().fg(Color::DarkGray)),
        ]),
    ];

    let paragraph = Paragraph::new(lines);
    frame.render_widget(paragraph, area);
}

/// Format a number with comma separators (e.g. 1,234,567).
fn format_number(n: u64) -> String {
    let s = n.to_string();
    let mut result = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    result.chars().rev().collect()
}

fn draw_disk_stats(frame: &mut Frame, app: &App, area: Rect) {
    let inner = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(2), Constraint::Length(2)])
        .split(area);

    if let Some(stats) = &app.disk_stats {
        let percent = if stats.total_bytes > 0 {
            (stats.used_bytes as f64 / stats.total_bytes as f64 * 100.0) as u64
        } else {
            0
        };

        let gauge_color = if percent > 90 {
            Color::Red
        } else if percent > 70 {
            Color::Yellow
        } else {
            Color::Green
        };

        let line = Line::from(vec![
            Span::raw("Disk Usage: "),
            Span::styled(
                format_size(stats.used_bytes),
                Style::default().fg(Color::Cyan),
            ),
            Span::raw(" / "),
            Span::styled(
                format_size(stats.total_bytes),
                Style::default().fg(Color::White),
            ),
            Span::raw(" ("),
            Span::styled(
                format!("{}%", percent),
                Style::default().fg(gauge_color),
            ),
            Span::raw(")"),
        ]);

        let text_paragraph = Paragraph::new(line).alignment(Alignment::Left);
        frame.render_widget(text_paragraph, inner[0]);

        let gauge = Gauge::default()
            .gauge_style(Style::default().fg(gauge_color))
            .ratio(stats.used_bytes as f64 / stats.total_bytes.max(1) as f64);
        frame.render_widget(gauge, inner[1]);
    } else {
        let paragraph = Paragraph::new("Disk stats unavailable.")
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(paragraph, area);
    }
}

fn draw_top_consumers(frame: &mut Frame, app: &App, area: Rect) {
    let mut lines: Vec<Line> = Vec::new();

    lines.push(Line::from(Span::styled(
        "Top Space Consumers",
        Style::default()
            .fg(Color::Yellow)
            .add_modifier(Modifier::BOLD),
    )));

    if let Some(tree) = &app.tree {
        let top: Vec<_> = tree
            .root
            .children
            .iter()
            .filter(|c| c.is_dir)
            .take(5)
            .collect();

        for (i, node) in top.iter().enumerate() {
            let rank = Span::styled(
                format!(" {}. ", i + 1),
                Style::default().fg(Color::DarkGray),
            );
            let size = Span::styled(
                format!("{:>10}  ", format_size(node.size)),
                Style::default().fg(Color::Magenta),
            );
            let name = Span::raw(node.name.clone());
            lines.push(Line::from(vec![rank, size, name]));
        }

        if top.is_empty() {
            lines.push(Line::from(Span::styled(
                " No directories found.",
                Style::default().fg(Color::DarkGray),
            )));
        }
    } else {
        lines.push(Line::from(Span::styled(
            " No data yet — start a scan.",
            Style::default().fg(Color::DarkGray),
        )));
    }

    let paragraph = Paragraph::new(lines);
    frame.render_widget(paragraph, area);
}

fn draw_reclaimable(frame: &mut Frame, app: &App, area: Rect) {
    let lines: Vec<Line> = if let Some(analysis) = &app.analysis {
        if analysis.total_reclaimable > 0 {
            vec![
                Line::from(Span::styled(
                    format!(
                        "Reclaimable: {} ({} items)",
                        format_size(analysis.total_reclaimable),
                        analysis.items.len()
                    ),
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::BOLD),
                )),
                Line::from(Span::styled(
                    "Press 3 to review and clean up.",
                    Style::default().fg(Color::DarkGray),
                )),
            ]
        } else {
            vec![Line::from(Span::styled(
                "No reclaimable space detected.",
                Style::default().fg(Color::DarkGray),
            ))]
        }
    } else {
        vec![Line::from(Span::styled(
            "No reclaimable space detected.",
            Style::default().fg(Color::DarkGray),
        ))]
    };

    let paragraph = Paragraph::new(lines);
    frame.render_widget(paragraph, area);
}
