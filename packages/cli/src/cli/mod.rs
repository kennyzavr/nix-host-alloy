use std::{io::Write, path::PathBuf};

use console::style;
use miette::{Context, IntoDiagnostic};
use tempfile::NamedTempFile;

use crate::lib::{state, workspace};

mod facts;
mod secrets;

const NIXPKGS_DEFAULT_SOURCE_URL: &str = "nixpkgs";
const ALLOY_DEFAULT_SOURCE_URL: &str = "github:kennyzavr/nix-host-alloy";

#[derive(clap::Parser, Debug)]
#[command(name = "alloy-cli")]
pub struct Args {
    #[command(flatten)]
    workspace: WorkspaceArgs,
    #[command(flatten)]
    module_source: ModuleSourceArgs,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug)]
enum Cmd {
    Facts(facts::Args),
    Secrets(secrets::Args),
}

#[derive(clap::Args, Debug)]
struct WorkspaceArgs {
    #[arg(long = "root")]
    root_dir: Option<PathBuf>,
}

#[derive(clap::Args, Debug)]
#[group(required = false, multiple = false)]
struct ModuleSourceArgs {
    #[arg(long = "module")]
    module_path: Option<PathBuf>,
    #[arg(long = "attr")]
    flake_attr: Option<String>,
}

struct Cli {
    state_loader: state::Loader,
    stderr: console::Term,
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
    fn print_info(&self, msg: &str) {
        // TODO: just log the error
        self.stderr
            .write_line(&format!("{} {}", style("·").cyan().dim(), msg))
            .unwrap();
    }

    fn print_skip(&self, msg: &str) {
        self.stderr
            .write_line(&format!("{} {}", style("○").dim(), msg))
            .unwrap();
    }

    fn print_ok(&self, msg: &str) {
        self.stderr
            .write_line(&format!("{} {}", style("✓").bold().green(), msg))
            .unwrap();
    }

    fn print_step(&self, msg: &str) {
        self.stderr
            .write_line(&format!("{} {}", style("◆").bold().blue(), msg))
            .unwrap();
    }

    fn print_error(&self, error: impl miette::Diagnostic + Send + Sync + 'static) {
        print_error(&self.stderr, error);
    }

    fn print_report(&self, report: miette::Report) {
        self.stderr.write_line(&format!("{:?}", report)).unwrap();
    }

    fn handle_cmd(&self, cmd: Cmd) {
        match cmd {
            Cmd::Facts(facts) => self.handle_facts(facts),
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

fn print_error(stderr: &console::Term, error: impl miette::Diagnostic + Send + Sync + 'static) {
    let report = miette::Report::new(error);
    stderr.write_line(&format!("{:?}", report)).unwrap();
}

pub fn handle_args(args: Args) {
    let stderr = console::Term::stderr();

    let Ok(workspace) = workspace::Workspace::new(args.workspace.root_dir)
        .map_err(|error| print_error(&stderr, error))
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

    let alloy_url = std::env::var("ALLOY_URL").unwrap_or(ALLOY_DEFAULT_SOURCE_URL.to_string());

    let nixpkgs_url =
        std::env::var("ALLOY_NIXPKGS_URL").unwrap_or(NIXPKGS_DEFAULT_SOURCE_URL.to_string());

    let state_loader = state::Loader {
        module_source,
        workspace,
        alloy_url,
        nixpkgs_url,
    };

    Cli {
        state_loader,
        stderr,
    }
    .handle_cmd(args.cmd);
}
