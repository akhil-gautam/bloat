use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
};

use crate::app::App;
use crate::rules::Category;
use crate::ui::{format_size, safety_color};

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    // Scanning state: show centered message
    if app.scanning {
        let paragraph = Paragraph::new(Line::from(Span::styled(
            "Scanning filesystem...",
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )))
        .block(Block::default().borders(Borders::ALL).title(" Cleanup "))
        .alignment(Alignment::Center);
        frame.render_widget(paragraph, area);
        return;
    }

    // No analysis or empty items: show clean message
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

    // Layout: header (2), item list (min), action bar (2)
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Min(0),
            Constraint::Length(2),
        ])
        .split(area);

    // -------------------------------------------------------------------------
    // Header
    // -------------------------------------------------------------------------
    let selected_size: u64 = app
        .cleanup
        .checked
        .iter()
        .filter_map(|&i| analysis.items.get(i))
        .map(|item| item.total_size)
        .sum();
    let selected_count = app.cleanup.checked.len();

    let header_line = Line::from(vec![
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
                selected_count
            ),
            Style::default().fg(Color::White),
        ),
    ]);
    let header = Paragraph::new(header_line).alignment(Alignment::Left);
    frame.render_widget(header, chunks[0]);

    // -------------------------------------------------------------------------
    // Item list
    // -------------------------------------------------------------------------
    let items_border = Block::default().borders(Borders::ALL).title(" Items ");
    let inner_area = items_border.inner(chunks[1]);
    frame.render_widget(items_border, chunks[1]);

    let mut current_category: Option<Category> = None;
    let mut visual_row: usize = 0;
    // item_index -> visual row for the rendered item line
    let mut item_visual_map: Vec<usize> = Vec::new();

    struct Row {
        line: Line<'static>,
        is_selected: bool,
    }

    let mut rows: Vec<Row> = Vec::new();

    for (item_idx, item) in analysis.items.iter().enumerate() {
        // Insert category header when category changes
        if current_category != Some(item.category) {
            current_category = Some(item.category);
            let cat_color = category_color(item.category);
            let cat_label = format!(" {} ", item.category);
            rows.push(Row {
                line: Line::from(vec![Span::styled(
                    cat_label,
                    Style::default()
                        .fg(cat_color)
                        .add_modifier(Modifier::BOLD),
                )]),
                is_selected: false,
            });
            visual_row += 1;
        }

        item_visual_map.push(visual_row);

        let is_selected = app.cleanup.selected == item_idx;
        let is_checked = app.cleanup.checked.contains(&item_idx);

        let checkbox = if is_checked {
            Span::styled("[x]", Style::default().fg(Color::Green))
        } else {
            Span::styled("[ ]", Style::default().fg(Color::DarkGray))
        };

        let s_color = safety_color(item.safety);

        // Name padded/truncated to 40 chars
        let name_str = format!("{:<40}", truncate_str(&item.name, 40));
        let size_str = format!("{:>10}", format_size(item.total_size));
        let safety_label = format!("  {}", item.safety);

        rows.push(Row {
            line: Line::from(vec![
                Span::raw("  "),
                checkbox,
                Span::raw(" "),
                Span::styled("● ", Style::default().fg(s_color)),
                Span::raw(name_str),
                Span::styled(size_str, Style::default().fg(Color::Magenta)),
                Span::styled(safety_label, Style::default().fg(s_color)),
            ]),
            is_selected,
        });
        visual_row += 1;
    }

    // Compute scroll offset so the selected item stays visible
    let visible_height = inner_area.height as usize;
    let selected_visual_row = item_visual_map
        .get(app.cleanup.selected)
        .copied()
        .unwrap_or(0);
    let offset = if selected_visual_row >= visible_height {
        selected_visual_row.saturating_sub(visible_height / 2)
    } else {
        0
    };

    let list_items: Vec<ListItem> = rows
        .into_iter()
        .skip(offset)
        .map(|row| {
            let style = if row.is_selected {
                Style::default().bg(Color::DarkGray)
            } else {
                Style::default()
            };
            ListItem::new(row.line).style(style)
        })
        .collect();

    let list = List::new(list_items);
    frame.render_widget(list, inner_area);

    // -------------------------------------------------------------------------
    // Action bar
    // -------------------------------------------------------------------------
    let action_bar_line = Line::from(vec![
        Span::styled("Space", Style::default().fg(Color::Cyan)),
        Span::raw(": toggle  "),
        Span::styled("a", Style::default().fg(Color::Cyan)),
        Span::raw(": all  "),
        Span::styled("i", Style::default().fg(Color::Cyan)),
        Span::raw(": details  "),
        Span::styled(
            "Enter",
            Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(": clean selected"),
    ]);
    let action_bar = Paragraph::new(action_bar_line).alignment(Alignment::Center);
    frame.render_widget(action_bar, chunks[2]);
}

fn category_color(category: Category) -> Color {
    match category {
        Category::Developer => Color::Magenta,
        Category::System => Color::Blue,
        Category::App => Color::Yellow,
        Category::Media => Color::Cyan,
    }
}

fn truncate_str(s: &str, max_len: usize) -> &str {
    if s.len() <= max_len {
        s
    } else {
        &s[..max_len]
    }
}
