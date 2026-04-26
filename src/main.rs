mod alerts;
mod analyzer;
mod app;
mod cleaner;
mod history;
mod memory_actions;
mod permissions;
mod plugins;
mod rules;
mod scanner;
mod system_monitor;
mod tree;
mod ui;

use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use human_bytes::human_bytes;

use crate::rules::{RuleRegistry, Safety};

// ---------------------------------------------------------------------------
// CLI definition
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(name = "bloat", version, about = "Your disk is bloated. Let's fix that.")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Output results as JSON
    #[arg(long, global = true)]
    pub json: bool,

    /// Disable colour output
    #[arg(long, global = true)]
    pub no_color: bool,

    /// Root path to scan (overrides subcommand positional arg and home dir)
    #[arg(long, global = true)]
    pub path: Option<PathBuf>,

    /// Minimum size threshold (e.g. "10MB"); items smaller than this are hidden
    #[arg(long, global = true)]
    pub min_size: Option<String>,
}

#[derive(Subcommand)]
pub enum Command {
    /// Scan a directory and report reclaimable space
    Scan {
        /// Path to scan (defaults to home directory)
        path: Option<PathBuf>,
    },
    /// Clean reclaimable items
    Clean {
        /// Show what would be cleaned without touching the filesystem
        #[arg(long)]
        dry_run: bool,
        /// Only clean items marked as Safe (no prompts)
        #[arg(long)]
        safe: bool,
    },
    /// Show the N largest directories under the scan root
    Top {
        /// Number of directories to show
        #[arg(default_value = "10")]
        count: usize,
    },
}

impl Cli {
    /// Resolve the scan root: --path flag > Scan subcommand positional arg > home dir.
    pub fn scan_path(&self) -> PathBuf {
        if let Some(p) = &self.path {
            return p.clone();
        }
        if let Some(Command::Scan { path: Some(p) }) = &self.command {
            return p.clone();
        }
        dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"))
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let cli = Cli::parse();

    match &cli.command {
        None => {
            let path = cli.scan_path();
            let app = app::App::new(path);
            let terminal = ratatui::init();
            let result = app::run(terminal, app);
            ratatui::restore();
            if let Err(e) = result {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
        }
        Some(Command::Scan { .. }) => run_scan(&cli),
        Some(Command::Clean { dry_run, safe }) => run_clean(&cli, *dry_run, *safe),
        Some(Command::Top { count }) => run_top(&cli, *count),
    }
}

// ---------------------------------------------------------------------------
// Subcommand handlers
// ---------------------------------------------------------------------------

fn run_scan(cli: &Cli) {
    let root = cli.scan_path();

    eprintln!("Scanning {}…", root.display());

    let tree = scanner::scan(&root);
    let registry = RuleRegistry::with_defaults();
    let result = analyzer::analyze(&tree, &registry);

    let disk = scanner::disk_stats(&root);

    if cli.json {
        // Serialisable summary types — inline so we don't need extra derives
        // in the library modules.
        use serde_json::{json, Value};

        let items: Vec<Value> = result
            .items
            .iter()
            .map(|i| {
                json!({
                    "name": i.name,
                    "category": i.category.to_string(),
                    "safety": i.safety.to_string(),
                    "size_bytes": i.total_size,
                    "size_human": format_size(i.total_size),
                    "paths": i.paths.iter().map(|p| p.to_string_lossy()).collect::<Vec<_>>(),
                })
            })
            .collect();

        let mut output = json!({
            "scan_path": root.to_string_lossy(),
            "total_reclaimable_bytes": result.total_reclaimable,
            "total_reclaimable_human": format_size(result.total_reclaimable),
            "items": items,
        });

        if let Some(d) = &disk {
            output["disk"] = json!({
                "total_bytes": d.total_bytes,
                "used_bytes": d.used_bytes,
                "free_bytes": d.free_bytes,
                "total_human": format_size(d.total_bytes),
                "used_human": format_size(d.used_bytes),
                "free_human": format_size(d.free_bytes),
            });
        }

        println!("{}", serde_json::to_string_pretty(&output).unwrap());
        return;
    }

    // --- Text output ---

    println!("\nScan path : {}", root.display());

    if let Some(d) = &disk {
        println!(
            "Disk      : {} used / {} total ({} free)",
            format_size(d.used_bytes),
            format_size(d.total_bytes),
            format_size(d.free_bytes),
        );
    }

    println!(
        "Reclaimable: {} across {} item(s)\n",
        format_size(result.total_reclaimable),
        result.items.len(),
    );

    if result.items.is_empty() {
        println!("Nothing reclaimable found.");
        return;
    }

    for item in &result.items {
        println!(
            "  [{:7}] [{:^8}]  {}  ({})",
            item.safety.to_string(),
            item.category.to_string(),
            item.name,
            format_size(item.total_size),
        );
    }
}

fn run_clean(cli: &Cli, dry_run: bool, safe_only: bool) {
    let root = cli.scan_path();

    eprintln!("Scanning {}…", root.display());

    let tree = scanner::scan(&root);
    let registry = RuleRegistry::with_defaults();
    let result = analyzer::analyze(&tree, &registry);

    if result.items.is_empty() {
        println!("Nothing to clean.");
        return;
    }

    if dry_run {
        let summary = cleaner::dry_run(&result.items);
        println!("Dry run — nothing will be deleted.\n");
        for (name, size, path_count, safety) in &summary {
            println!(
                "  [{}] {} — {} ({} path(s))",
                safety,
                name,
                format_size(*size),
                path_count,
            );
        }
        return;
    }

    let items_to_clean: Vec<_> = if safe_only {
        result
            .items
            .iter()
            .filter(|i| i.safety == Safety::Safe)
            .collect()
    } else {
        result.items.iter().collect()
    };

    if items_to_clean.is_empty() {
        println!("No safe items found to clean.");
        return;
    }

    let stdin = io::stdin();
    let mut total_freed: u64 = 0;

    for item in items_to_clean {
        let should_clean = if safe_only || item.safety == Safety::Safe {
            true
        } else {
            // Prompt for non-safe items
            print!(
                "Clean [{}] {} ({})? [y/N] ",
                item.safety,
                item.name,
                format_size(item.total_size)
            );
            io::stdout().flush().ok();
            let mut line = String::new();
            stdin.lock().read_line(&mut line).ok();
            matches!(line.trim().to_lowercase().as_str(), "y" | "yes")
        };

        if should_clean {
            let clean_result = cleaner::clean_item(item, cleaner::DeleteMethod::Trash);
            total_freed += clean_result.freed_bytes;
            if clean_result.paths_failed.is_empty() {
                println!(
                    "  Cleaned: {} (freed {})",
                    clean_result.item_name,
                    format_size(clean_result.freed_bytes)
                );
            } else {
                println!(
                    "  Partial: {} (freed {}, {} error(s))",
                    clean_result.item_name,
                    format_size(clean_result.freed_bytes),
                    clean_result.paths_failed.len(),
                );
                for (path, err) in &clean_result.paths_failed {
                    eprintln!("    Error on {}: {}", path.display(), err);
                }
            }
        }
    }

    println!("\nTotal freed: {}", format_size(total_freed));
}

fn run_top(cli: &Cli, count: usize) {
    let root = cli.scan_path();

    eprintln!("Scanning {}…", root.display());

    let tree = scanner::scan(&root);

    // Collect top-level children, already sorted by size descending.
    let mut children: Vec<_> = tree.root.children.iter().collect();
    children.sort_by(|a, b| b.size.cmp(&a.size));
    let top = children.into_iter().take(count);

    println!("\nTop {} largest items under {}:\n", count, root.display());

    for (i, node) in top.enumerate() {
        println!(
            "  {:>2}. {:>10}  {}",
            i + 1,
            format_size(node.size),
            node.path.display(),
        );
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn format_size(bytes: u64) -> String {
    human_bytes(bytes as f64)
}
