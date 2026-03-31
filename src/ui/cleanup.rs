use ratatui::{
    Frame,
    layout::{Alignment, Rect},
    style::{Modifier, Style},
    text::Line,
    widgets::{Block, Borders, Paragraph},
};

use crate::app::App;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let text = if app.scanning {
        Line::from("Scanning filesystem...")
    } else {
        Line::from("Cleanup tab — coming in Task 12")
    };

    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title(" Cleanup "))
        .alignment(Alignment::Center)
        .style(Style::default().add_modifier(Modifier::BOLD));

    frame.render_widget(paragraph, area);
}
