use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::Line,
    widgets::{Block, Borders, Paragraph},
    layout::Alignment,
};

use crate::app::App;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let text = if app.scanning {
        Line::from("Scanning filesystem...")
    } else {
        Line::from("Overview tab — coming in Task 10")
    };

    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title(" Overview "))
        .alignment(Alignment::Center)
        .style(Style::default().add_modifier(Modifier::BOLD));

    frame.render_widget(paragraph, area);
}
