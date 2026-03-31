pub mod cleanup;
pub mod explorer;
pub mod overview;

use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Tabs},
};

use crate::app::{App, Tab};
use crate::rules::Safety;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn draw(frame: &mut Frame, app: &App) {
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
    let text = if app.scanning {
        Span::styled(
            " Scanning...",
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled(
            " q Quit  ? Help  Tab Next  1/2/3 Switch tabs",
            Style::default().fg(Color::DarkGray),
        )
    };

    let paragraph = Paragraph::new(Line::from(text));
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
