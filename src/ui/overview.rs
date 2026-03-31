use crate::app::App;
use crate::ui::format_size;
use ratatui::prelude::*;
use ratatui::widgets::*;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    if app.scanning {
        draw_scan_progress(frame, app, area);
        return;
    }

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),  // Disk stats (title + used/free/total)
            Constraint::Length(1),  // Segmented bar
            Constraint::Length(1),  // Spacer
            Constraint::Min(7),    // Top consumers
            Constraint::Length(3),  // Reclaimable box
        ])
        .split(area);

    draw_disk_stats(frame, app, chunks[0], chunks[1]);
    draw_top_consumers(frame, app, chunks[3]);
    draw_reclaimable(frame, app, chunks[4]);

    if app.overview.confirm_delete {
        draw_confirm_overlay(frame, app, area);
    }
}

fn draw_scan_progress(frame: &mut Frame, app: &App, area: Rect) {
    let stats = &app.scan_stats;

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
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
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
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::raw("  "),
            Span::styled(dir_display, Style::default().fg(Color::DarkGray)),
        ]),
    ];

    frame.render_widget(Paragraph::new(lines), area);
}

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

fn draw_disk_stats(frame: &mut Frame, app: &App, text_area: Rect, bar_area: Rect) {
    if let Some(stats) = &app.disk_stats {
        let pct = if stats.total_bytes > 0 {
            stats.used_bytes as f64 / stats.total_bytes as f64
        } else {
            0.0
        };

        // Line 1: Macintosh HD — APFS
        let title = Line::from(Span::styled(
            "Macintosh HD — APFS",
            Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        ));

        // Line 2: Used: X  Free: Y  Total: Z
        let used_color = if pct > 0.9 {
            Color::Red
        } else if pct > 0.7 {
            Color::Yellow
        } else {
            Color::Green
        };

        let info = Line::from(vec![
            Span::styled("Used: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format_size(stats.used_bytes),
                Style::default().fg(used_color).add_modifier(Modifier::BOLD),
            ),
            Span::raw("   "),
            Span::styled("Free: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format_size(stats.free_bytes),
                Style::default().fg(Color::Green),
            ),
            Span::raw("   "),
            Span::styled("Total: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format_size(stats.total_bytes),
                Style::default().fg(Color::White),
            ),
        ]);

        frame.render_widget(Paragraph::new(vec![title, info]), text_area);

        // Segmented color bar showing usage categories
        draw_segmented_bar(frame, app, bar_area, pct);
    } else {
        frame.render_widget(
            Paragraph::new("Disk stats unavailable.")
                .style(Style::default().fg(Color::DarkGray)),
            text_area,
        );
    }
}

/// Draw a segmented bar showing what's using the disk space.
/// Uses scan tree categories if available, otherwise a simple used/free bar.
fn draw_segmented_bar(frame: &mut Frame, app: &App, area: Rect, used_pct: f64) {
    let width = area.width as usize;
    if width == 0 {
        return;
    }

    // If we have a scan tree, categorize top-level children
    if let Some(tree) = &app.tree {
        let total = app
            .disk_stats
            .as_ref()
            .map_or(tree.root.size, |s| s.total_bytes);
        if total == 0 {
            return;
        }

        // Group top children into rough categories
        let mut segments: Vec<(&str, u64, Color)> = Vec::new();
        let mut other_size: u64 = 0;

        for child in &tree.root.children {
            let name_lower = child.name.to_lowercase();
            if child.size * 100 / total < 2 {
                // Too small to show, lump into other
                other_size += child.size;
                continue;
            }
            let color = if name_lower.contains("librar") || name_lower.contains("cache") {
                Color::Blue
            } else if name_lower.contains("download") {
                Color::Magenta
            } else if name_lower.contains("document") || name_lower.contains("desktop") {
                Color::Green
            } else if name_lower.contains("application") {
                Color::Cyan
            } else if name_lower.contains("project")
                || name_lower.contains("developer")
                || name_lower.contains("code")
            {
                Color::Yellow
            } else {
                Color::White
            };

            // Shorten name
            let label = if child.name.len() > 8 {
                &child.name[..8]
            } else {
                &child.name
            };
            segments.push((label, child.size, color));
        }

        if other_size > 0 && other_size * 100 / total >= 2 {
            segments.push(("Other", other_size, Color::DarkGray));
        }

        // Calculate free space
        let used: u64 = segments.iter().map(|(_, s, _)| *s).sum::<u64>() + other_size;
        let free = total.saturating_sub(
            app.disk_stats
                .as_ref()
                .map_or(used, |s| s.used_bytes),
        );

        // Build the bar
        let mut spans: Vec<Span> = Vec::new();
        let mut chars_used = 0;

        for (label, size, color) in &segments {
            let seg_width = ((*size as f64 / total as f64) * width as f64).round() as usize;
            if seg_width == 0 {
                continue;
            }
            let seg_width = seg_width.min(width - chars_used);
            if seg_width == 0 {
                break;
            }

            // Center the label in the segment
            let text = if seg_width >= label.len() + 2 {
                format!("{:^width$}", label, width = seg_width)
            } else {
                "█".repeat(seg_width)
            };

            spans.push(Span::styled(
                text,
                Style::default().fg(Color::Black).bg(*color),
            ));
            chars_used += seg_width;
        }

        // Free space
        let free_width = width.saturating_sub(chars_used);
        if free_width > 0 {
            let free_text = if free_width >= 6 {
                format!("{:^width$}", "Free", width = free_width)
            } else {
                " ".repeat(free_width)
            };
            spans.push(Span::styled(
                free_text,
                Style::default().fg(Color::DarkGray).bg(Color::Black),
            ));
        }

        frame.render_widget(Paragraph::new(Line::from(spans)), area);
    } else {
        // Simple used/free bar
        let used_w = (used_pct * width as f64).round() as usize;
        let free_w = width.saturating_sub(used_w);
        let color = if used_pct > 0.9 {
            Color::Red
        } else if used_pct > 0.7 {
            Color::Yellow
        } else {
            Color::Green
        };
        let spans = vec![
            Span::styled(
                format!("{:^width$}", format!("{:.0}%", used_pct * 100.0), width = used_w),
                Style::default().fg(Color::Black).bg(color),
            ),
            Span::styled(
                " ".repeat(free_w),
                Style::default().bg(Color::Black),
            ),
        ];
        frame.render_widget(Paragraph::new(Line::from(spans)), area);
    }
}

fn draw_top_consumers(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0)])
        .split(area);

    // Title line
    let title = Line::from(vec![
        Span::styled(
            "Top Space Consumers",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            "   Space: select · d: delete",
            Style::default().fg(Color::DarkGray),
        ),
    ]);
    frame.render_widget(Paragraph::new(title), chunks[0]);

    // Item list
    let tree = match &app.tree {
        Some(t) => t,
        None => {
            frame.render_widget(
                Paragraph::new(Span::styled(
                    "  No data yet.",
                    Style::default().fg(Color::DarkGray),
                )),
                chunks[1],
            );
            return;
        }
    };

    let top: Vec<_> = tree.root.children.iter().take(5).collect();
    let right_col_width = 12; // for size like "  38.2 GiB"
    let list_width = chunks[1].width as usize;

    let items: Vec<ListItem> = top
        .iter()
        .enumerate()
        .map(|(i, node)| {
            let checked = app.overview.checked.contains(&i);
            let is_sel = i == app.overview.selected;

            let checkbox = if checked {
                Span::styled("[x] ", Style::default().fg(Color::Green))
            } else {
                Span::styled("[ ] ", Style::default().fg(Color::DarkGray))
            };

            let rank = Span::styled(
                format!("{}. ", i + 1),
                Style::default().fg(Color::DarkGray),
            );

            // Show path relative to scan root, or shortened with ~
            let display_name = shorten_path(&node.path, &app.scan_path);

            // Calculate padding to right-align the size
            let left_len = 6 + display_name.len(); // "[x] " + "N. " + name
            let padding = if list_width > left_len + right_col_width {
                list_width - left_len - right_col_width
            } else {
                1
            };

            let size_str = format_size(node.size);

            let line = Line::from(vec![
                checkbox,
                rank,
                Span::styled(display_name.clone(), Style::default().fg(Color::White)),
                Span::raw(" ".repeat(padding)),
                Span::styled(
                    format!("{:>10}", size_str),
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::BOLD),
                ),
            ]);

            let style = if is_sel {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };

            ListItem::new(line).style(style)
        })
        .collect();

    frame.render_widget(List::new(items), chunks[1]);
}

fn draw_reclaimable(frame: &mut Frame, app: &App, area: Rect) {
    let analysis = match &app.analysis {
        Some(a) if a.total_reclaimable > 0 => a,
        _ => {
            frame.render_widget(
                Paragraph::new(Span::styled(
                    "No reclaimable space detected.",
                    Style::default().fg(Color::DarkGray),
                )),
                area,
            );
            return;
        }
    };

    // Left-bordered accent box like the mockup
    let block = Block::default()
        .borders(Borders::LEFT)
        .border_style(Style::default().fg(Color::Green))
        .padding(Padding::new(1, 0, 0, 0));

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let text = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("Quick scan found ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format_size(analysis.total_reclaimable),
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" reclaimable.", Style::default().fg(Color::DarkGray)),
            Span::raw(" "),
            Span::styled(
                "Press 3 to review.",
                Style::default().fg(Color::DarkGray),
            ),
        ]),
    ]);
    frame.render_widget(text, inner);
}

/// Shorten a path for display: use ~ for home, show relative to scan root
fn shorten_path(path: &std::path::Path, scan_root: &std::path::Path) -> String {
    let path_str = path.to_string_lossy();

    // Try relative to scan root first
    if let Ok(rel) = path.strip_prefix(scan_root) {
        let rel_str = rel.to_string_lossy();
        if let Some(home) = dirs::home_dir() {
            let home_str = home.to_string_lossy();
            if scan_root.starts_with(&*home_str) {
                let scan_rel = scan_root.strip_prefix(&*home_str).unwrap_or(scan_root);
                return format!("~/{}/{}", scan_rel.display(), rel_str);
            }
        }
        return rel_str.to_string();
    }

    // Fallback: shorten home prefix
    if let Some(home) = dirs::home_dir() {
        let home_str = home.to_string_lossy();
        if path_str.starts_with(home_str.as_ref()) {
            return format!("~{}", &path_str[home_str.len()..]);
        }
    }

    path_str.to_string()
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
            Style::default()
                .fg(Color::Red)
                .add_modifier(Modifier::BOLD),
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
        Style::default()
            .fg(Color::Magenta)
            .add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::raw("  "),
        Span::styled(
            "y",
            Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
        ),
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
