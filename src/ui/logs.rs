use ratatui::prelude::*;
use ratatui::widgets::*;

use crate::app::App;
use crate::ui::format_size;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Logs ")
        .title_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));

    if app.logs.is_empty() {
        let empty = Paragraph::new(Line::from(Span::styled(
            "No deletions yet.",
            Style::default().fg(Color::DarkGray),
        )))
        .block(block)
        .alignment(Alignment::Center);
        frame.render_widget(empty, area);
        return;
    }

    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Header
    let header_area = Rect { height: 2, ..inner };
    let header = Paragraph::new(vec![
        Line::from(vec![
            Span::styled(
                format!(" {} deletions", app.logs.len()),
                Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(
                    "  (freed {})",
                    format_size(
                        app.logs
                            .iter()
                            .filter(|l| l.success)
                            .map(|l| l.size)
                            .sum::<u64>()
                    )
                ),
                Style::default().fg(Color::Green),
            ),
        ]),
        Line::from(""),
    ]);
    frame.render_widget(header, header_area);

    // Log entries (newest first)
    let list_area = Rect {
        y: inner.y + 2,
        height: inner.height.saturating_sub(2),
        ..inner
    };

    let items: Vec<ListItem> = app
        .logs
        .iter()
        .rev()
        .map(|entry| {
            let status = if entry.success {
                Span::styled(" OK ", Style::default().fg(Color::Green))
            } else {
                Span::styled("FAIL", Style::default().fg(Color::Red))
            };

            let mut spans = vec![
                Span::styled(
                    format!(" {} ", entry.timestamp),
                    Style::default().fg(Color::DarkGray),
                ),
                status,
                Span::raw(" "),
                Span::styled(
                    format!("{:>10}", format_size(entry.size)),
                    Style::default().fg(Color::Magenta),
                ),
                Span::raw("  "),
                Span::styled(&entry.name, Style::default().fg(Color::White)),
                Span::styled(
                    format!("  → {}", entry.method),
                    Style::default().fg(Color::DarkGray),
                ),
            ];

            if let Some(ref err) = entry.error {
                spans.push(Span::styled(
                    format!("  ({})", err),
                    Style::default().fg(Color::Red),
                ));
            }

            ListItem::new(Line::from(spans))
        })
        .collect();

    let list = List::new(items);
    frame.render_widget(list, list_area);
}
