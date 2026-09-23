use owo_colors::OwoColorize;

pub struct TerminalUi {
    pub depth: u32,
}

impl TerminalUi {
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

    pub fn print_error(&self, err: &dyn std::error::Error) {
        let tag = format!("{:>12}", "Error:").bright_red().bold().to_string();
        let indent_str = "  ".repeat(self.depth as usize);

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
        let indent_str = "  ".repeat(self.depth as usize);
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_info(&self, msg: &str) {
        let tag = format!("{:>12}", "Info:").bright_blue().bold().to_string();
        let indent_str = "  ".repeat(self.depth as usize);
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_skip(&self, msg: &str) {
        let tag = format!("{:>12}", "Skip:").dimmed().bold().to_string();
        let indent_str = "  ".repeat(self.depth as usize);
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_step(&self, msg: &str) {
        let tag = format!("{:>12}", "Step:").bright_cyan().bold().to_string();
        let indent_str = "  ".repeat(self.depth as usize);
        eprintln!("{}{tag} {}", indent_str, self.colorize_msg(msg));
    }

    pub fn print_data(&self, data: String) {
        println!("{data}");
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
            if c == '`' {
                let mut inner = String::new();
                while let Some(&next_c) = chars.peek() {
                    if next_c == '`' {
                        chars.next();
                        break;
                    }
                    inner.push(chars.next().unwrap());
                }
                result.push_str(&inner.yellow().bold().to_string());
            } else if c == '\'' {
                let mut inner = String::new();
                while let Some(&next_c) = chars.peek() {
                    if next_c == '\'' {
                        chars.next();
                        break;
                    }
                    inner.push(chars.next().unwrap());
                }
                result.push_str(&format!("'{}'", inner.magenta().to_string()));
            } else {
                result.push(c);
            }
        }
        result
    }
}
