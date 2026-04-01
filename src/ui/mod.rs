pub mod cleanup;
pub mod explorer;
pub mod htop;
pub mod logs;
pub mod overview;

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, Paragraph, Tabs},
};

use crate::app::{App, Screen, Tab};
use crate::rules::Safety;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn draw(frame: &mut Frame, app: &App) {
    match app.screen {
        Screen::FolderSelect => draw_folder_select(frame, app),
        Screen::Main => draw_main(frame, app),
    }
}

fn draw_main(frame: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(0),
            Constraint::Length(1),
        ])
        .split(frame.area());

    draw_header(frame, app, chunks[0]);

    match app.tab {
        Tab::Overview => overview::draw(frame, app, chunks[1]),
        Tab::Explorer => explorer::draw(frame, app, chunks[1]),
        Tab::Cleanup => cleanup::draw(frame, app, chunks[1]),
        Tab::Logs => logs::draw(frame, app, chunks[1]),
        Tab::System => {
            if let Some(ref snap) = app.sys_snapshot {
                htop::draw(frame, snap, &app.system_tab, &app.alert_engine.alerts, chunks[1]);
            } else {
                let p = Paragraph::new("Loading system stats...")
                    .alignment(Alignment::Center)
                    .style(Style::default().fg(Color::DarkGray));
                frame.render_widget(p, chunks[1]);
            }
        }
    }

    draw_status_bar(frame, app, chunks[2]);

    if app.show_help {
        draw_help_overlay(frame, frame.area());
    }
}

fn draw_folder_select(frame: &mut Frame, app: &App) {
    let area = frame.area();

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4),  // Title + hints
            Constraint::Length(1),  // Spacer
            Constraint::Min(0),    // Folder list
            Constraint::Length(1),  // Spacer
            Constraint::Length(3),  // Disk stats bar
            Constraint::Length(2),  // Action bar
        ])
        .split(area);

    // Title with inline hints
    let title = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("bloat", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
            Span::styled(" — ", Style::default().fg(Color::DarkGray)),
            Span::styled("your disk is bloated. let's fix that.", Style::default().fg(Color::Gray)),
        ]),
        Line::from(vec![
            Span::styled("↑↓", Style::default().fg(Color::Cyan)),
            Span::styled(" navigate  ", Style::default().fg(Color::Gray)),
            Span::styled("Space", Style::default().fg(Color::Cyan)),
            Span::styled(" select  ", Style::default().fg(Color::Gray)),
            Span::styled("Enter", Style::default().fg(Color::Green)),
            Span::styled(" scan  ", Style::default().fg(Color::Gray)),
            Span::styled("a", Style::default().fg(Color::Cyan)),
            Span::styled(" all  ", Style::default().fg(Color::Gray)),
            Span::styled("q", Style::default().fg(Color::Red)),
            Span::styled(" quit  ", Style::default().fg(Color::Gray)),
            Span::styled("s", Style::default().fg(Color::Yellow)),
            Span::styled(" system monitor", Style::default().fg(Color::Gray)),
        ]),
    ])
    .block(Block::default().borders(Borders::ALL));
    frame.render_widget(title, chunks[0]);

    // Folder list
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Select folders to scan ")
        .title_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));

    let items: Vec<ListItem> = app
        .folder_select
        .folders
        .iter()
        .enumerate()
        .map(|(i, f)| {
            let checkbox = if f.checked { "[x]" } else { "[ ]" };
            let check_style = if f.checked {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            let name_style = if !f.exists {
                Style::default().fg(Color::DarkGray)
            } else if i == app.folder_select.folders.len() - 1 {
                // "Entire Home Directory" — special styling
                Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::White)
            };

            let suffix = if !f.exists {
                Span::styled(" (not found)", Style::default().fg(Color::DarkGray))
            } else {
                Span::raw("")
            };

            let line = Line::from(vec![
                Span::raw("  "),
                Span::styled(checkbox, check_style),
                Span::raw(" "),
                Span::styled(&f.name, name_style),
                suffix,
            ]);

            let style = if i == app.folder_select.selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };

            ListItem::new(line).style(style)
        })
        .collect();

    let list = List::new(items).block(block);
    frame.render_widget(list, chunks[2]);

    // Disk stats
    if let Some(stats) = &app.disk_stats {
        let pct = stats.used_bytes as f64 / stats.total_bytes.max(1) as f64;
        let bar_color = if pct > 0.9 {
            Color::Red
        } else if pct > 0.7 {
            Color::Yellow
        } else {
            Color::Green
        };
        let disk_line = Line::from(vec![
            Span::styled(" Disk: ", Style::default().fg(Color::DarkGray)),
            Span::styled(format_size(stats.used_bytes), Style::default().fg(bar_color)),
            Span::raw(" / "),
            Span::raw(format_size(stats.total_bytes)),
            Span::styled(format!(" ({:.0}% used)", pct * 100.0), Style::default().fg(bar_color)),
        ]);
        let disk_block = Block::default().borders(Borders::ALL).title(" disk ");
        let disk = Paragraph::new(disk_line).block(disk_block);
        frame.render_widget(disk, chunks[4]);
    }

    // Action bar
    let selected_count = app.folder_select.folders.iter().filter(|f| f.checked).count();
    let action = if selected_count > 0 {
        Line::from(vec![
            Span::styled(" Enter", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
            Span::raw(": scan  "),
            Span::styled("Space", Style::default().fg(Color::Cyan)),
            Span::raw(": toggle  "),
            Span::styled("a", Style::default().fg(Color::Cyan)),
            Span::raw(": all  "),
            Span::styled("q", Style::default().fg(Color::Red)),
            Span::raw(": quit"),
        ])
    } else {
        Line::from(vec![
            Span::styled(" Space", Style::default().fg(Color::Cyan)),
            Span::raw(": toggle  "),
            Span::styled("a", Style::default().fg(Color::Cyan)),
            Span::raw(": all  "),
            Span::styled("q", Style::default().fg(Color::Red)),
            Span::raw(": quit"),
        ])
    };
    frame.render_widget(Paragraph::new(action), chunks[5]);
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

fn draw_header(frame: &mut Frame, app: &App, area: Rect) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(1), Constraint::Length(1)])
        .split(area);

    // Row 1: "bloat v0.1.0" left, tab labels right
    let log_label = if app.logs.is_empty() {
        "[4 Logs]".to_string()
    } else {
        format!("[4 Logs ({})]", app.logs.len())
    };

    let tab_labels: Vec<(&str, &str, Tab)> = vec![
        ("[1 Overview]", "1 Overview", Tab::Overview),
        ("[2 Explorer]", "2 Explorer", Tab::Explorer),
        ("[3 Cleanup]", "3 Cleanup", Tab::Cleanup),
    ];

    let mut tab_spans: Vec<Span> = Vec::new();
    for (label, _, tab) in &tab_labels {
        let style = if *tab == app.tab {
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::DarkGray)
        };
        tab_spans.push(Span::styled(*label, style));
        tab_spans.push(Span::raw(" "));
    }
    // Logs tab
    let log_style = if app.tab == Tab::Logs {
        Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    };
    tab_spans.push(Span::styled(&log_label, log_style));
    tab_spans.push(Span::raw(" "));

    // System tab — accessed via 's', not a numbered tab
    if app.tab == Tab::System {
        tab_spans.push(Span::raw(" "));
        tab_spans.push(Span::styled(
            "[System]",
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ));
    }

    // Calculate how wide the tab labels are
    let tabs_text: String = tab_spans.iter().map(|s| s.content.to_string()).collect();
    let tabs_width = tabs_text.len();
    let title = "bloat v0.1.0";
    let total_width = area.width as usize;
    let padding = total_width.saturating_sub(title.len() + tabs_width);

    let mut header_spans = vec![
        Span::styled(
            title,
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ),
        Span::raw(" ".repeat(padding)),
    ];
    header_spans.extend(tab_spans);

    frame.render_widget(Paragraph::new(Line::from(header_spans)), rows[0]);

    // Row 2: separator line
    let sep = "─".repeat(total_width);
    frame.render_widget(
        Paragraph::new(Span::styled(&sep, Style::default().fg(Color::DarkGray))),
        rows[1],
    );
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

fn draw_status_bar(frame: &mut Frame, app: &App, area: Rect) {
    let dim = Style::default().fg(Color::Gray);
    let key = Style::default().fg(Color::Cyan);
    let dot = Span::styled(" · ", dim);

    let line = if app.scanning {
        Line::from(vec![
            Span::styled(" Esc", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(": stop", dim),
            dot.clone(),
            Span::styled("Scanning...", Style::default().fg(Color::Yellow)),
        ])
    } else {
        Line::from(vec![
            Span::raw(" "),
            Span::styled("1-4", key),
            Span::styled(": tabs", dim),
            dot.clone(),
            Span::styled("s", key),
            Span::styled(": system", dim),
            dot.clone(),
            Span::styled("r", key),
            Span::styled(": rescan", dim),
            dot.clone(),
            Span::styled("q", key),
            Span::styled(": quit", dim),
            dot.clone(),
            Span::styled("?", key),
            Span::styled(": help", dim),
        ])
    };

    // Render with a subtle background so it's always visible
    let bar = Paragraph::new(line).style(Style::default().bg(Color::Rgb(30, 30, 30)));
    frame.render_widget(bar, area);
}

// ---------------------------------------------------------------------------
// Help overlay
// ---------------------------------------------------------------------------

fn draw_help_overlay(frame: &mut Frame, area: Rect) {
    let popup_area = centered_rect(60, 60, area);

    let help_text = vec![
        Line::from(vec![
            Span::styled("Key Bindings", Style::default().add_modifier(Modifier::BOLD))
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("q", Style::default().fg(Color::Yellow)),
            Span::raw("          Quit"),
        ]),
        Line::from(vec![
            Span::styled("?", Style::default().fg(Color::Yellow)),
            Span::raw("          Toggle this help"),
        ]),
        Line::from(vec![
            Span::styled("1 / 2 / 3", Style::default().fg(Color::Yellow)),
            Span::raw("  Switch tabs"),
        ]),
        Line::from(vec![
            Span::styled("Tab", Style::default().fg(Color::Yellow)),
            Span::raw("        Next tab"),
        ]),
        Line::from(vec![
            Span::styled("Shift+Tab", Style::default().fg(Color::Yellow)),
            Span::raw("  Previous tab"),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Explorer", Style::default().add_modifier(Modifier::BOLD))
        ]),
        Line::from(vec![
            Span::styled("j / k / ↑↓", Style::default().fg(Color::Yellow)),
            Span::raw(" Navigate"),
        ]),
        Line::from(vec![
            Span::styled("l / → / Enter", Style::default().fg(Color::Yellow)),
            Span::raw(" Expand dir"),
        ]),
        Line::from(vec![
            Span::styled("h / ←", Style::default().fg(Color::Yellow)),
            Span::raw("      Collapse dir"),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("Cleanup", Style::default().add_modifier(Modifier::BOLD))
        ]),
        Line::from(vec![
            Span::styled("j / k / ↑↓", Style::default().fg(Color::Yellow)),
            Span::raw(" Navigate"),
        ]),
        Line::from(vec![
            Span::styled("Space", Style::default().fg(Color::Yellow)),
            Span::raw("       Toggle item"),
        ]),
        Line::from(vec![
            Span::styled("a", Style::default().fg(Color::Yellow)),
            Span::raw("          Toggle all"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "Press any key to close",
            Style::default().fg(Color::DarkGray),
        )),
    ];

    let block = Block::default()
        .title(" Help ")
        .borders(Borders::ALL)
        .style(Style::default().bg(Color::Black));

    frame.render_widget(Clear, popup_area);
    frame.render_widget(
        Paragraph::new(help_text).block(block),
        popup_area,
    );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a centered rectangle of `percent_x` width and `percent_y` height.
pub fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(area);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(vertical[1])[1]
}

/// Render a prominent "no data — press r to rescan" message.
pub fn draw_no_data(frame: &mut Frame, area: Rect) {
    let lines = vec![
        Line::from(""),
        Line::from(""),
        Line::from(Span::styled(
            "No scan data available",
            Style::default().fg(Color::Gray),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("Press ", Style::default().fg(Color::Gray)),
            Span::styled(" r ", Style::default().fg(Color::Yellow).bg(Color::Rgb(60, 60, 60)).add_modifier(Modifier::BOLD)),
            Span::styled(" to rescan", Style::default().fg(Color::Gray)),
        ]),
    ];
    frame.render_widget(
        Paragraph::new(lines).alignment(Alignment::Center),
        area,
    );
}

/// Format bytes using human_bytes.
pub fn format_size(bytes: u64) -> String {
    human_bytes::human_bytes(bytes as f64)
}

/// Map a Safety level to a colour.
pub fn safety_color(safety: Safety) -> Color {
    match safety {
        Safety::Safe => Color::Green,
        Safety::Caution => Color::Yellow,
        Safety::Risky => Color::Red,
    }
}
