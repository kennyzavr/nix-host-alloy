use std::io::Write;

use crate::error::WrapErrExt;
use alloy_core::domain::{NameMarker, PathMarker};
use owo_colors::OwoColorize;

#[derive(Debug, Clone)]
pub struct TermUi {
    pub depth: u64,
}

impl TermUi {
    pub const CLAP_STYLES: clap::builder::styling::Styles =
        clap::builder::styling::Styles::styled()
            .header(
                clap::builder::styling::AnsiColor::Cyan
                    .on_default()
                    .effects(clap::builder::styling::Effects::BOLD),
            )
            .usage(
                clap::builder::styling::AnsiColor::Cyan
                    .on_default()
                    .effects(clap::builder::styling::Effects::BOLD),
            )
            .literal(
                clap::builder::styling::AnsiColor::Blue
                    .on_default()
                    .effects(clap::builder::styling::Effects::BOLD),
            )
            .placeholder(clap::builder::styling::AnsiColor::Cyan.on_default());

    fn indent_str(&self) -> String {
        "    ".repeat(self.depth as usize)
    }

    pub fn print_clap_err(&self, err: &clap::Error) {
        let indent_str = self.indent_str();
        let is_error = err.use_stderr();
        let full_text = err.render().ansi().to_string();

        for line in full_text.lines() {
            if is_error {
                eprintln!("{}      {}", indent_str, line);
            } else {
                println!("{}      {}", indent_str, line);
            }
        }
    }

    pub fn print_error(&self, err: &dyn std::error::Error) {
        let tag = format!("{:>12}", "Error:").bright_red().bold().to_string();
        let indent_str = self.indent_str();

        let full_text = crate::error::render_error_chain(err);
        let mut is_first = true;

        for line in full_text.lines() {
            let colored_text = self.colorize_msg(line);

            if is_first {
                eprintln!("{}{tag} {}", indent_str, colored_text);
                is_first = false;
            } else {
                let padding = " ".repeat(13);
                eprintln!("{}{padding}{}", indent_str, colored_text);
            }
        }
    }

    pub fn print_ok(&self, msg: &str) {
        let tag = format!("{:>12}", "Ok:").bright_green().bold().to_string();
        let indent_str = self.indent_str();
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_newline(&self) {
        eprintln!("");
    }

    pub fn print_info(&self, msg: &str) {
        let tag = format!("{:>12}", "Info:").bright_blue().bold().to_string();
        let indent_str = self.indent_str();
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_skip(&self, msg: &str) {
        let tag = format!("{:>12}", "Skip:").dimmed().bold().to_string();
        let indent_str = self.indent_str();
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    #[allow(dead_code)]
    pub fn print_step(&self, msg: &str) {
        let tag = format!("{:>12}", "Step:").bright_cyan().bold().to_string();
        let indent_str = self.indent_str();
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_data(&self, data: String) {
        println!("{data}");
    }

    pub fn print_raw_data(&self, data: &[u8]) {
        let mut stdout = std::io::stdout();
        if let Err(e) = stdout
            .write_all(&data)
            .and_then(|_| stdout.flush())
            .wrap_err("Failed to write raw bytes to stdout")
        {
            self.print_error(&e);
        }
    }

    pub fn print_table(&self, headers: Vec<&str>, rows: Vec<Vec<String>>) {
        let mut table = comfy_table::Table::new();
        table.load_style(comfy_table::presets::UTF8_FULL);
        table.set_header(headers);
        for row in rows {
            table.add_row(row);
        }
        println!("{table}");
    }

    fn colorize_msg(&self, msg: &str) -> String {
        let mut result = String::new();
        let mut chars = msg.chars().peekable();

        while let Some(c) = chars.next() {
            if c == NameMarker::START {
                let mut inner = String::new();
                while let Some(&next_c) = chars.peek() {
                    if next_c == NameMarker::END {
                        chars.next();
                        break;
                    }
                    inner.push(chars.next().unwrap());
                }
                result.push_str(&format!("`{}`", inner.yellow().bold()));
            } else if c == PathMarker::START {
                let mut inner = String::new();
                while let Some(&next_c) = chars.peek() {
                    if next_c == PathMarker::END {
                        chars.next();
                        break;
                    }
                    inner.push(chars.next().unwrap());
                }
                result.push_str(&inner.magenta().underline().to_string());
            } else {
                result.push(c);
            }
        }
        result
    }
}
