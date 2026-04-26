// Permissions tab — inspect granted tiers and deep-link to System Settings.

use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
};

use crate::app::App;
use crate::permissions::{Capabilities, Tier};

const TIERS: &[Tier] = &[
    Tier::FullDiskAccess,
    Tier::Admin,
    Tier::Accessibility,
    Tier::Automation,
];

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Min(8),
            Constraint::Length(8),
            Constraint::Length(2),
        ])
        .split(area);

    draw_header(frame, &app.capabilities, chunks[0]);
    draw_tier_list(frame, app, chunks[1]);
    draw_detail(frame, app, chunks[2]);
    draw_action_bar(frame, chunks[3]);
}

fn draw_header(frame: &mut Frame, caps: &Capabilities, area: Rect) {
    let granted = [caps.full_disk_access, caps.admin, caps.accessibility]
        .iter()
        .filter(|b| **b)
        .count();
    let line = Line::from(vec![
        Span::styled(
            "Permissions",
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            format!("{}/4 granted", granted),
            Style::default().fg(Color::Gray),
        ),
    ]);
    frame.render_widget(Paragraph::new(line), area);
}

fn draw_tier_list(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default().borders(Borders::ALL).title(" Tiers ");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let items: Vec<ListItem> = TIERS
        .iter()
        .enumerate()
        .map(|(i, tier)| {
            let granted = app.capabilities.has(*tier);
            let mark = if granted { "[granted]" } else { "[missing]" };
            let mark_style = if granted {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::Yellow)
            };
            let line = Line::from(vec![
                Span::raw("  "),
                Span::styled(format!("{:<10}", mark), mark_style),
                Span::raw("  "),
                Span::styled(
                    format!("{:<20}", tier.label()),
                    Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
                ),
                Span::styled(tier.unlocks(), Style::default().fg(Color::DarkGray)),
            ]);
            let style = if i == app.permissions_selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };
            ListItem::new(line).style(style)
        })
        .collect();

    frame.render_widget(List::new(items), inner);
}

fn draw_detail(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" How to grant ")
        .title_style(Style::default().fg(Color::Cyan));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let tier = TIERS
        .get(app.permissions_selected)
        .copied()
        .unwrap_or(Tier::FullDiskAccess);

    let body = match tier {
        Tier::FullDiskAccess => vec![
            Line::from("System Settings → Privacy & Security → Full Disk Access → add `bloat`."),
            Line::from(""),
            Line::from("Press `o` (or Enter) to jump to that pane, then `r` to re-probe."),
        ],
        Tier::Admin => vec![
            Line::from("Granted on demand. The first admin action shows a macOS auth dialog;"),
            Line::from("subsequent actions in the same session reuse the cached credential."),
            Line::from("Press `r` after running an admin action to flip this to ✅."),
        ],
        Tier::Accessibility => vec![
            Line::from("System Settings → Privacy & Security → Accessibility → add `bloat`."),
            Line::from(""),
            Line::from("Required for AppleScript-driven UI automation of other apps."),
        ],
        Tier::Automation => vec![
            Line::from("Granted per-app. The first `osascript tell` against an app prompts."),
            Line::from("Approve in System Settings → Privacy & Security → Automation."),
        ],
        Tier::User => vec![Line::from("Always granted.")],
    };

    frame.render_widget(Paragraph::new(body).wrap(Wrap { trim: false }), inner);
}

fn draw_action_bar(frame: &mut Frame, area: Rect) {
    let line = Line::from(vec![
        Span::styled(" j/k", Style::default().fg(Color::Cyan)),
        Span::raw(": navigate  "),
        Span::styled("o / Enter", Style::default().fg(Color::Cyan)),
        Span::raw(": open System Settings  "),
        Span::styled("r", Style::default().fg(Color::Green)),
        Span::raw(": re-probe"),
    ]);
    frame.render_widget(Paragraph::new(line), area);
}
