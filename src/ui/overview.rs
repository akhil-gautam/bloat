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

    if app.overview.confirm_delete {
        draw_confirm_overlay(frame, app, area);
    }
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
        .constraints([Constraint::Length(2), Constraint::Length(1), Constraint::Length(1)])
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
            .gauge_style(Style::default().fg(gauge_color).bg(Color::DarkGray))
            .ratio(stats.used_bytes as f64 / stats.total_bytes.max(1) as f64)
            .label(format!("{:.0}%", stats.used_bytes as f64 / stats.total_bytes.max(1) as f64 * 100.0));
        frame.render_widget(gauge, inner[2]);
    } else {
        let paragraph = Paragraph::new("Disk stats unavailable.")
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(paragraph, area);
    }
}

fn draw_top_consumers(frame: &mut Frame, app: &App, area: Rect) {
    use ratatui::widgets::{List, ListItem};

    let mut items: Vec<ListItem> = Vec::new();

    items.push(ListItem::new(Line::from(vec![
        Span::styled(
            "Top Space Consumers",
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            "  (Space: select, d: delete)",
            Style::default().fg(Color::DarkGray),
        ),
    ])));

    if let Some(tree) = &app.tree {
        let top: Vec<_> = tree.root.children.iter().take(5).collect();

        for (i, node) in top.iter().enumerate() {
            let checked = if app.overview.checked.contains(&i) {
                "[x]"
            } else {
                "[ ]"
            };
            let check_style = if app.overview.checked.contains(&i) {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            let line = Line::from(vec![
                Span::styled(format!(" {} ", checked), check_style),
                Span::styled(format!("{}. ", i + 1), Style::default().fg(Color::DarkGray)),
                Span::styled(
                    format!("{:>10}  ", format_size(node.size)),
                    Style::default().fg(Color::Magenta),
                ),
                Span::raw(node.name.clone()),
            ]);

            let style = if i == app.overview.selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };

            items.push(ListItem::new(line).style(style));
        }

        if top.is_empty() {
            items.push(ListItem::new(Line::from(Span::styled(
                " No items found.",
                Style::default().fg(Color::DarkGray),
            ))));
        }
    } else {
        items.push(ListItem::new(Line::from(Span::styled(
            " No data yet — start a scan.",
            Style::default().fg(Color::DarkGray),
        ))));
    }

    let list = List::new(items);
    frame.render_widget(list, area);
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

fn draw_confirm_overlay(frame: &mut Frame, app: &App, area: Rect) {
    let tree = match &app.tree {
        Some(t) => t,
        None => return,
    };

    let top: Vec<_> = tree.root.children.iter().take(5).collect();
    let selected_names: Vec<(&str, u64)> = app
        .overview
        .checked
        .iter()
        .filter_map(|&i| top.get(i).map(|n| (n.name.as_str(), n.size)))
        .collect();
    let total_size: u64 = selected_names.iter().map(|(_, s)| s).sum();

    let popup = crate::ui::centered_rect(50, 40, area);

    let mut lines = vec![
        Line::from(Span::styled(
            " Move to Trash? ",
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
    ];

    for (name, size) in &selected_names {
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled("• ", Style::default().fg(Color::Red)),
            Span::styled(*name, Style::default().fg(Color::White)),
            Span::styled(
                format!("  ({})", format_size(*size)),
                Style::default().fg(Color::DarkGray),
            ),
        ]));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        format!("  Total: {}", format_size(total_size)),
        Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::raw("  "),
        Span::styled("y", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
        Span::raw(" confirm   "),
        Span::styled("any other key", Style::default().fg(Color::DarkGray)),
        Span::raw(" cancel"),
    ]));

    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Confirm Delete ")
        .title_style(Style::default().fg(Color::Red))
        .style(Style::default().bg(Color::Black));

    frame.render_widget(Clear, popup);
    frame.render_widget(Paragraph::new(lines).block(block), popup);
}
