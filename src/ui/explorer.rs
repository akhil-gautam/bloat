use crate::app::App;
use crate::tree::FsNode;
use crate::ui::format_size;
use ratatui::prelude::*;
use ratatui::widgets::*;
use std::path::PathBuf;

/// Build a flat list of visible tree rows.
///
/// Returns `Vec<(Line<'static>, PathBuf)>` where each entry is a rendered line
/// and the path of the node (used for hit-testing the selected index).
///
/// The root node (depth 0) is never added to the output; its children are
/// always recursed so the top-level entries are always visible.
fn flatten_tree(
    node: &FsNode,
    depth: usize,
    root_size: u64,
    app: &App,
    out: &mut Vec<(Line<'static>, PathBuf)>,
) {
    if depth == 0 {
        // Root itself is hidden; always recurse into its children.
        for child in &node.children {
            flatten_tree(child, depth + 1, root_size, app, out);
        }
        return;
    }

    // --- Build the line for this node ---
    let indent = "  ".repeat(depth - 1);

    let arrow = if node.is_dir {
        if app.explorer.expanded.contains(&node.path) {
            "▼ "
        } else {
            "▶ "
        }
    } else {
        "  "
    };

    // Name span
    let name_span = if node.is_dir {
        Span::styled(
            format!("{}{}{}/", indent, arrow, node.name),
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled(
            format!("{}{}{}", indent, arrow, node.name),
            Style::default().fg(Color::White),
        )
    };

    // Size span — right-aligned via a leading space makes it look decent in a
    // proportional-font context; we just include a small separator.
    let size_str = format!(" {} ", format_size(node.size));
    let size_span = Span::styled(size_str, Style::default().fg(Color::Magenta));

    // Size bar — proportional to root_size, max 20 chars
    const BAR_MAX: usize = 20;
    let bar_width = if root_size > 0 {
        ((node.size as f64 / root_size as f64) * BAR_MAX as f64).round() as usize
    } else {
        0
    }
    .min(BAR_MAX);

    let bar_color = if root_size > 0 {
        let ratio = node.size as f64 / root_size as f64;
        if ratio > 0.30 {
            Color::Red
        } else if ratio > 0.10 {
            Color::Yellow
        } else {
            Color::Green
        }
    } else {
        Color::Green
    };

    let bar_str: String = "█".repeat(bar_width);
    // Pad to BAR_MAX width so columns stay aligned
    let bar_padded = format!("{:<width$}", bar_str, width = BAR_MAX);
    let bar_span = Span::styled(bar_padded, Style::default().fg(bar_color));

    let line = Line::from(vec![name_span, size_span, bar_span]);
    out.push((line, node.path.clone()));

    // Recurse into expanded directories
    if node.is_dir && app.explorer.expanded.contains(&node.path) {
        for child in &node.children {
            flatten_tree(child, depth + 1, root_size, app, out);
        }
    }
}

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    // Split area into a 1-line header and the rest for the tree.
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0)])
        .split(area);

    let header_area = chunks[0];
    let tree_area = chunks[1];

    // --- Scanning state ---
    if app.scanning {
        let s = &app.scan_stats;
        let text = format!(
            "Scanning...  {} files, {} dirs, {}",
            s.files_found, s.dirs_found, format_size(s.bytes_found)
        );
        let paragraph = Paragraph::new(text)
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::Yellow));
        frame.render_widget(paragraph, area);
        return;
    }

    // --- No tree yet ---
    let tree = match &app.tree {
        Some(t) => t,
        None => {
            crate::ui::draw_no_data(frame, area);
            return;
        }
    };

    let root_size = tree.total_size();

    // --- Header ---
    let header_line = Line::from(vec![
        Span::styled(
            tree.root.path.display().to_string(),
            Style::default().fg(Color::Cyan),
        ),
        Span::raw(" "),
        Span::styled(
            format!("({})", format_size(root_size)),
            Style::default().fg(Color::DarkGray),
        ),
    ]);
    frame.render_widget(Paragraph::new(header_line), header_area);

    // --- Flatten tree ---
    let mut rows: Vec<(Line<'static>, PathBuf)> = Vec::new();
    flatten_tree(&tree.root, 0, root_size, app, &mut rows);

    if rows.is_empty() {
        let paragraph = Paragraph::new("No scan data.")
            .alignment(Alignment::Center)
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(paragraph, tree_area);
        return;
    }

    // --- Scrolling ---
    // app.explorer.selected counts the root as index 0.
    // flatten_tree skips root, so display index i = app.selected - 1.
    let visible_height = tree_area.height as usize;
    let selected_display = app.explorer.selected.saturating_sub(1);

    let offset = if selected_display >= visible_height {
        selected_display - visible_height + 1
    } else {
        0
    };

    // --- Render rows ---
    let visible_rows: Vec<Line<'static>> = rows
        .iter()
        .enumerate()
        .skip(offset)
        .take(visible_height)
        .map(|(i, (line, _path))| {
            if i == selected_display {
                // Apply selection background by restyling all spans
                let spans: Vec<Span<'static>> = line
                    .spans
                    .iter()
                    .map(|s| {
                        Span::styled(
                            s.content.clone(),
                            s.style.bg(Color::DarkGray),
                        )
                    })
                    .collect();
                Line::from(spans)
            } else {
                line.clone()
            }
        })
        .collect();

    let paragraph = Paragraph::new(visible_rows);
    frame.render_widget(paragraph, tree_area);
}
