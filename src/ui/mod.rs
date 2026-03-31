pub mod cleanup;
pub mod explorer;
pub mod overview;

use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
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
            Constraint::Length(3),  // Title
            Constraint::Length(1),  // Spacer
            Constraint::Min(0),    // Folder list
            Constraint::Length(1),  // Spacer
            Constraint::Length(3),  // Disk stats bar
            Constraint::Length(2),  // Action bar
        ])
        .split(area);

    // Title
    let title = Paragraph::new(Line::from(vec![
        Span::styled("bloat", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
        Span::styled(" — ", Style::default().fg(Color::DarkGray)),
        Span::styled("your disk is bloated. let's fix that.", Style::default().fg(Color::DarkGray)),
    ]))
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
    let tab_titles = vec![
        Line::from("1 Overview"),
        Line::from("2 Explorer"),
        Line::from("3 Cleanup"),
    ];

    let selected = match app.tab {
        Tab::Overview => 0,
        Tab::Explorer => 1,
        Tab::Cleanup => 2,
    };

    let tabs = Tabs::new(tab_titles)
        .block(Block::default().borders(Borders::ALL).title(" bloat "))
        .select(selected)
        .style(Style::default().fg(Color::White))
        .highlight_style(
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        );

    frame.render_widget(tabs, area);
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

fn draw_status_bar(frame: &mut Frame, app: &App, area: Rect) {
    let line = if app.scanning {
        Line::from(vec![
            Span::styled(" Scanning...  ", Style::default().fg(Color::Yellow)),
            Span::styled("Esc", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(": stop scan", Style::default().fg(Color::DarkGray)),
        ])
    } else {
        Line::from(Span::styled(
            " q Quit  ? Help  Tab Next  1/2/3 Switch tabs  r Rescan",
            Style::default().fg(Color::DarkGray),
        ))
    };

    let paragraph = Paragraph::new(line);
    frame.render_widget(paragraph, area);
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
