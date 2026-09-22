use std::{io::Write, path::PathBuf};

use owo_colors::OwoColorize;
use tempfile::NamedTempFile;

use crate::lib::{state, workspace};

mod facts;
mod generators;
mod indexes;
mod secrets;

const NIXPKGS_DEFAULT_SOURCE_URL: &str = "nixpkgs";
const ALLOY_DEFAULT_SOURCE_URL: &str = "github:kennyzavr/nix-host-alloy";

const CLAP_STYLES: clap::builder::styling::Styles = clap::builder::styling::Styles::styled()
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

#[derive(clap::Parser, Debug)]
#[command(name = "alloy-cli", styles = CLAP_STYLES)]
pub struct Args {
    #[command(flatten)]
    workspace: WorkspaceArgs,
    #[command(flatten)]
    module_source: ModuleSourceArgs,
    #[arg(long = "alloy-url", env = "ALLOY_URL", default_value = ALLOY_DEFAULT_SOURCE_URL)]
    alloy_url: String,
    #[arg(long = "nixpkgs-url", env = "ALLOY_NIXPKGS_URL", default_value = NIXPKGS_DEFAULT_SOURCE_URL)]
    nixpkgs_url: String,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug)]
enum Cmd {
    Facts(facts::Args),
    Generators(generators::Args),
    Indexes(indexes::Args),
    Secrets(secrets::Args),
}

#[derive(clap::Args, Debug)]
struct WorkspaceArgs {
    #[arg(long = "root", env = "ALLOY_ROOT")]
    root_dir: Option<PathBuf>,
}

#[derive(clap::Args, Debug)]
#[group(required = false, multiple = false)]
struct ModuleSourceArgs {
    #[arg(long = "module", env = "ALLOY_MODULE")]
    module_path: Option<PathBuf>,
    #[arg(long = "attr", env = "ALLOY_ATTR")]
    flake_attr: Option<String>,
}

struct Cli {
    state_loader: state::Loader,
    stderr: console::Term,
    depth: usize,
}

#[derive(thiserror::Error, miette::Diagnostic, Debug)]
enum EditError {
    #[error("Failed to create temp file")]
    #[diagnostic()]
    Create(#[source] std::io::Error),

    #[error("Failed to execute editor")]
    #[diagnostic()]
    Exec(#[source] std::io::Error),

    #[error("Editor execution failed with {0}")]
    #[diagnostic()]
    ExitStatus(std::process::ExitStatus),

    #[error("Failed to write initial content to temp file")]
    #[diagnostic()]
    Write(#[source] std::io::Error),

    #[error("Failed to read new content from temp file")]
    #[diagnostic()]
    Read(#[source] std::io::Error),
}

impl Cli {
    fn indent(&self) -> String {
        "  ".repeat(self.depth)
    }

    fn print_info(&self, msg: &str) {
        let tag = format!("{:>12}", "Info:").bright_blue().bold().to_string();
        self.stderr
            .write_line(&format!("{}{tag} {msg}", self.indent()))
            .unwrap();
    }

    fn print_skip(&self, msg: &str) {
        let tag = format!("{:>12}", "Skip:").dimmed().bold().to_string();
        self.stderr
            .write_line(&format!("{}{tag} {msg}", self.indent()))
            .unwrap();
    }

    fn print_ok(&self, msg: &str) {
        let tag = format!("{:>12}", "Ok:").bright_green().bold().to_string();
        self.stderr
            .write_line(&format!("{}{tag} {msg}", self.indent()))
            .unwrap();
    }

    fn print_step(&self, msg: &str) {
        let tag = format!("{:>12}", "Step:").bright_cyan().bold().to_string();
        self.stderr
            .write_line(&format!("{}{tag} {msg}", self.indent()))
            .unwrap();
    }

    fn print_error(&self, error: impl miette::Diagnostic + Send + Sync + 'static) {
        print_error(&self.stderr, error, self.depth);
    }

    fn print_report(&self, report: miette::Report) {
        let tag = format!("{:>12}", "Error:").bright_red().bold().to_string();
        let indent_str = "  ".repeat(self.depth);

        let report_code = AsRef::<dyn miette::Diagnostic>::as_ref(&report)
            .code()
            .map(|c| c.to_string());

        let error_str = format!("{:?}", report);
        let mut lines = error_str.lines().skip_while(|l| l.trim().is_empty());

        if let Some(first_line) = lines.next() {
            let original_len = first_line.len();
            let trimmed = first_line.trim_start();
            let spaces_removed = original_len - trimmed.len();

            let display_text = if let Some(code) = report_code {
                code.yellow().bold().to_string()
            } else {
                trimmed.to_string()
            };

            self.stderr
                .write_line(&format!("{}{tag} {}", indent_str, display_text))
                .unwrap();

            let padding = 13_usize.saturating_sub(spaces_removed);
            let block_indent = format!("{}{}", indent_str, " ".repeat(padding));

            let indented_error = lines
                .map(|line| {
                    if line.trim().is_empty() {
                        String::new()
                    } else {
                        format!("{block_indent}{line}")
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");

            if !indented_error.is_empty() {
                self.stderr.write_line(&indented_error).unwrap();
            }
        }
    }

    fn create_table(&self) -> comfy_table::Table {
        let mut table = comfy_table::Table::new();
        table.load_style(comfy_table::presets::UTF8_FULL);
        table
    }

    fn print_table(&self, table: comfy_table::Table) {
        println!("{table}");
    }

    fn handle_cmd(&self, cmd: Cmd) {
        match cmd {
            Cmd::Facts(facts) => self.handle_facts(facts),
            Cmd::Generators(generators) => self.handle_generators(generators),
            Cmd::Indexes(indexes) => self.handle_indexes(indexes),
            Cmd::Secrets(secrets) => self.handle_secrets(secrets),
        }
    }

    fn edit(&self, data: String) -> Result<Option<String>, EditError> {
        let mut tempfile = NamedTempFile::new().map_err(EditError::Create)?;

        tempfile
            .write_all(data.as_bytes())
            .map_err(EditError::Write)?;

        let editor_env = std::env::var("EDITOR").ok();
        let editor_env = editor_env.as_deref().unwrap_or("nano");

        let mut editor_parts = editor_env.split_whitespace();
        let editor_bin = editor_parts.next().unwrap();

        let mut cmd = std::process::Command::new(editor_bin);
        cmd.args(editor_parts);

        if ["vi", "vim", "nvim", "gvim"]
            .iter()
            .any(|&cmd| editor_bin.ends_with(cmd))
        {
            cmd.args(["-n", "-i", "NONE"]);
        } else if editor_bin.ends_with("nano") {
            cmd.arg("-H");
        } else if editor_bin.ends_with("emacs") {
            cmd.args([
                "--eval",
                "(setq make-backup-files nil)",
                "--eval",
                "(setq auto-save-default nil)",
            ]);
        }

        let status = cmd.arg(tempfile.path()).status().map_err(EditError::Exec)?;

        if !status.success() {
            return Err(EditError::ExitStatus(status));
        }

        let mut new_data = std::fs::read_to_string(tempfile.path()).map_err(EditError::Read)?;

        if !data.ends_with("\n") && new_data.ends_with("\n") {
            new_data.pop();
            if new_data.ends_with("\r") {
                new_data.pop();
            }
        }

        if data == new_data {
            return Ok(None);
        }

        Ok(Some(new_data))
    }
}

fn print_error(
    stderr: &console::Term,
    error: impl miette::Diagnostic + Send + Sync + 'static,
    depth: usize,
) {
    let tag = format!("{:>12}", "Error:").bright_red().bold().to_string();
    let indent_str = "  ".repeat(depth);

    let report_code = error.code().map(|c| c.to_string());

    let report = miette::Report::new(error);
    let error_str = format!("{:?}", report);
    let mut lines = error_str.lines().skip_while(|l| l.trim().is_empty());

    if let Some(first_line) = lines.next() {
        let original_len = first_line.len();
        let trimmed = first_line.trim_start();
        let spaces_removed = original_len - trimmed.len();

        let display_text = if let Some(code) = report_code {
            code.yellow().bold().to_string()
        } else {
            trimmed.to_string()
        };

        stderr
            .write_line(&format!("{}{tag} {}", indent_str, display_text))
            .unwrap();

        let padding = 13_usize.saturating_sub(spaces_removed);
        let block_indent = format!("{}{}", indent_str, " ".repeat(padding));

        let indented_error = lines
            .map(|line| {
                if line.trim().is_empty() {
                    String::new()
                } else {
                    format!("{block_indent}{line}")
                }
            })
            .collect::<Vec<_>>()
            .join("\n");

        if !indented_error.is_empty() {
            stderr.write_line(&indented_error).unwrap();
        }
    }
}

pub fn handle_args(args: Args) {
    let _ = miette::set_hook(Box::new(|_| {
        let mut theme = miette::GraphicalTheme::unicode();
        theme.styles = miette::ThemeStyles {
            error: owo_colors::Style::new().bright_red().bold(),
            warning: owo_colors::Style::new().bright_yellow().bold(),
            advice: owo_colors::Style::new().bright_blue().bold(),
            help: owo_colors::Style::new().cyan().dimmed(),
            link: owo_colors::Style::new().bright_blue().underline(),
            linum: owo_colors::Style::new().dimmed(),
            highlights: vec![
                owo_colors::Style::new().bright_red().bold(),
                owo_colors::Style::new().bright_yellow().bold(),
                owo_colors::Style::new().bright_cyan().bold(),
            ],
        };

        Box::new(
            miette::MietteHandlerOpts::new()
                .graphical_theme(theme)
                .build(),
        )
    }));

    let stderr = console::Term::stderr();

    let depth = std::env::var("ALLOY_DEPTH")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .unwrap_or(0);

    let Ok(workspace) = workspace::Workspace::new(args.workspace.root_dir.clone())
        .map_err(|error| {
            print_error(&stderr, error, depth);
            std::process::exit(1);
        })
    else {
        return;
    };

    let module_source = if let Some(module_path) = args.module_source.module_path {
        state::ModuleSource::ModuleFile(module_path)
    } else if let Some(flake_attr) = args.module_source.flake_attr {
        state::ModuleSource::FlakeAttr(flake_attr)
    } else {
        state::ModuleSource::FlakeAttr("alloyModules.default".to_string())
    };

    let alloy_url = args.alloy_url;

    let nixpkgs_url = args.nixpkgs_url;

    let state_loader = state::Loader {
        module_source,
        workspace,
        alloy_url,
        nixpkgs_url,
    };

    Cli {
        state_loader,
        stderr,
        depth,
    }
    .handle_cmd(args.cmd);
}
