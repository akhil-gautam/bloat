use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
};

use crate::app::App;
use crate::rules::Category;
use crate::ui::{format_size, safety_color};

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    // Scanning state
    if app.scanning {
        let s = &app.scan_stats;
        let text = format!(
            "Scanning...  {} files, {} dirs, {}",
            s.files_found,
            s.dirs_found,
            format_size(s.bytes_found)
        );
        let paragraph = Paragraph::new(Line::from(Span::styled(
            text,
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )))
        .block(Block::default().borders(Borders::ALL).title(" Cleanup "))
        .alignment(Alignment::Center);
        frame.render_widget(paragraph, area);
        return;
    }

    // No analysis or empty
    let analysis = match &app.analysis {
        Some(a) if !a.items.is_empty() => a,
        _ => {
            let paragraph = Paragraph::new(Line::from(Span::styled(
                "Your disk is clean! Nothing to remove.",
                Style::default().fg(Color::Green),
            )))
            .block(Block::default().borders(Borders::ALL).title(" Cleanup "))
            .alignment(Alignment::Center);
            frame.render_widget(paragraph, area);
            return;
        }
    };

    // Main layout: header, item list, detail panel, action bar
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),  // Header
            Constraint::Min(8),    // Item list
            Constraint::Length(12), // Detail panel
            Constraint::Length(2),  // Action bar
        ])
        .split(area);

    draw_header(frame, app, analysis, chunks[0]);
    draw_item_list(frame, app, analysis, chunks[1]);
    draw_detail_panel(frame, app, analysis, chunks[2]);
    draw_action_bar(frame, chunks[3]);
}

fn draw_header(
    frame: &mut Frame,
    app: &App,
    analysis: &crate::analyzer::AnalysisResult,
    area: Rect,
) {
    let selected_size: u64 = app
        .cleanup
        .checked
        .iter()
        .filter_map(|&i| analysis.items.get(i))
        .map(|item| item.total_size)
        .sum();

    let header = Paragraph::new(Line::from(vec![
        Span::styled(
            format!("Reclaimable: {}", format_size(analysis.total_reclaimable)),
            Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("   "),
        Span::styled(
            format!(
                "Selected: {} ({} items)",
                format_size(selected_size),
                app.cleanup.checked.len()
            ),
            Style::default().fg(Color::White),
        ),
    ]));
    frame.render_widget(header, area);
}

fn draw_item_list(
    frame: &mut Frame,
    app: &App,
    analysis: &crate::analyzer::AnalysisResult,
    area: Rect,
) {
    let block = Block::default().borders(Borders::ALL).title(" Items ");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let mut current_category: Option<Category> = None;
    let mut visual_rows: Vec<usize> = Vec::new(); // item_idx -> visual row

    struct Row {
        line: Line<'static>,
        is_selected: bool,
    }

    let mut rows: Vec<Row> = Vec::new();
    let mut vrow: usize = 0;

    for (idx, item) in analysis.items.iter().enumerate() {
        if current_category != Some(item.category) {
            current_category = Some(item.category);
            rows.push(Row {
                line: Line::from(Span::styled(
                    format!(" {} ", item.category),
                    Style::default()
                        .fg(category_color(item.category))
                        .add_modifier(Modifier::BOLD),
                )),
                is_selected: false,
            });
            vrow += 1;
        }

        visual_rows.push(vrow);
        let is_sel = app.cleanup.selected == idx;
        let is_chk = app.cleanup.checked.contains(&idx);

        let checkbox = if is_chk {
            Span::styled("[x]", Style::default().fg(Color::Green))
        } else {
            Span::styled("[ ]", Style::default().fg(Color::DarkGray))
        };

        let sc = safety_color(item.safety);
        let path_count = item.paths.len();
        let paths_hint = if path_count > 1 {
            format!("  ({} paths)", path_count)
        } else {
            String::new()
        };

        rows.push(Row {
            line: Line::from(vec![
                Span::raw("  "),
                checkbox,
                Span::raw(" "),
                Span::styled("● ", Style::default().fg(sc)),
                Span::styled(
                    truncate(&item.name, 35),
                    Style::default().fg(Color::White),
                ),
                Span::raw("  "),
                Span::styled(
                    format!("{:>10}", format_size(item.total_size)),
                    Style::default().fg(Color::Magenta),
                ),
                Span::styled(format!("  {:<7}", format!("{}", item.safety)), Style::default().fg(sc)),
                Span::styled(paths_hint, Style::default().fg(Color::DarkGray)),
            ]),
            is_selected: is_sel,
        });
        vrow += 1;
    }

    // Scroll
    let vis_h = inner.height as usize;
    let sel_vrow = visual_rows
        .get(app.cleanup.selected)
        .copied()
        .unwrap_or(0);
    let offset = if sel_vrow >= vis_h {
        sel_vrow.saturating_sub(vis_h / 2)
    } else {
        0
    };

    let list_items: Vec<ListItem> = rows
        .into_iter()
        .skip(offset)
        .map(|r| {
            let style = if r.is_selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };
            ListItem::new(r.line).style(style)
        })
        .collect();

    frame.render_widget(List::new(list_items), inner);
}

fn draw_detail_panel(
    frame: &mut Frame,
    app: &App,
    analysis: &crate::analyzer::AnalysisResult,
    area: Rect,
) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Details ")
        .title_style(Style::default().fg(Color::Cyan));

    let item = match analysis.items.get(app.cleanup.selected) {
        Some(i) => i,
        None => {
            frame.render_widget(
                Paragraph::new("Select an item to see details.").block(block),
                area,
            );
            return;
        }
    };

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let inner_chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(inner);

    // Left: description, impact, safety info
    let sc = safety_color(item.safety);
    let mut left_lines = vec![
        Line::from(vec![
            Span::styled(&item.name, Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
            Span::raw("  "),
            Span::styled(format!("{}", item.safety), Style::default().fg(sc).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Size: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                format_size(item.total_size),
                Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  ({} paths)", item.paths.len()),
                Style::default().fg(Color::DarkGray),
            ),
        ]),
        Line::from(""),
    ];

    if !item.description.is_empty() {
        left_lines.push(Line::from(vec![
            Span::styled("What: ", Style::default().fg(Color::Cyan)),
            Span::raw(&item.description),
        ]));
    }
    if !item.impact.is_empty() {
        left_lines.push(Line::from(vec![
            Span::styled("Impact: ", Style::default().fg(Color::Yellow)),
            Span::raw(&item.impact),
        ]));
    }

    let left = Paragraph::new(left_lines).wrap(Wrap { trim: false });
    frame.render_widget(left, inner_chunks[0]);

    // Right: file paths
    let max_paths = inner_chunks[1].height as usize;
    let total_paths = item.paths.len();
    let mut right_lines = vec![Line::from(Span::styled(
        "Paths:",
        Style::default()
            .fg(Color::Cyan)
            .add_modifier(Modifier::BOLD),
    ))];

    let display_count = total_paths.min(max_paths.saturating_sub(2));
    for path in item.paths.iter().take(display_count) {
        let path_str = path.to_string_lossy();
        // Shorten home dir prefix
        let display = if let Some(home) = dirs::home_dir() {
            let home_str = home.to_string_lossy();
            if path_str.starts_with(home_str.as_ref()) {
                format!("~{}", &path_str[home_str.len()..])
            } else {
                path_str.to_string()
            }
        } else {
            path_str.to_string()
        };

        // Truncate to fit panel width
        let max_w = inner_chunks[1].width.saturating_sub(2) as usize;
        let truncated = if display.len() > max_w {
            format!("...{}", &display[display.len() - max_w + 3..])
        } else {
            display
        };

        right_lines.push(Line::from(Span::styled(
            format!(" {}", truncated),
            Style::default().fg(Color::DarkGray),
        )));
    }

    if total_paths > display_count {
        right_lines.push(Line::from(Span::styled(
            format!(" ... and {} more", total_paths - display_count),
            Style::default().fg(Color::DarkGray),
        )));
    }

    let right = Paragraph::new(right_lines);
    frame.render_widget(right, inner_chunks[1]);
}

fn draw_action_bar(frame: &mut Frame, area: Rect) {
    let action = Paragraph::new(Line::from(vec![
        Span::styled("Space", Style::default().fg(Color::Cyan)),
        Span::raw(": toggle  "),
        Span::styled("a", Style::default().fg(Color::Cyan)),
        Span::raw(": all  "),
        Span::styled("j/k", Style::default().fg(Color::Cyan)),
        Span::raw(": navigate  "),
        Span::styled(
            "Enter",
            Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(": clean selected"),
    ]))
    .alignment(Alignment::Center);
    frame.render_widget(action, area);
}

fn category_color(category: Category) -> Color {
    match category {
        Category::Developer => Color::Magenta,
        Category::System => Color::Blue,
        Category::App => Color::Yellow,
        Category::Media => Color::Cyan,
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        format!("{:<width$}", s, width = max)
    } else {
        format!("{:<width$}", &s[..max], width = max)
    }
}
