use std::path::PathBuf;

use clap::{ArgGroup, Parser};
use eyre::Context;

mod sh;
mod state;
mod workspace;

#[derive(Parser, Debug)]
#[command(name = "alloy-cli")]
#[command(group(ArgGroup::new("source").required(false)))]
struct Args {
    #[arg(short = 'R', long = "workspace-root", long)]
    workspace_root: Option<PathBuf>,
    #[arg(short = 'M', long = "module-path", long, group = "source")]
    module_path: Option<PathBuf>,
    #[arg(short = 'A', long = "attr", group = "source")]
    flake_attr: Option<String>,
    #[arg(short = 'N', long = "nixpkgs")]
    nixpkgs_flake_url: Option<String>,
}

const NIXPKGS_DEFAULT_SOURCE_URL: &str = "nixpkgs";
const ALLOY_DEFAULT_SOURCE_URL: &str = "github:kennyzavr/nix-host-alloy";

fn main() -> eyre::Result<()> {
    color_eyre::install()?;

    let args = Args::parse();

    let workspace = workspace::Workspace::new(args.workspace_root)?;

    let module_source = if let Some(flake_attr) = args.flake_attr {
        state::ModuleSource::FlakeAttr(flake_attr)
    } else if let Some(module_path) = args.module_path {
        state::ModuleSource::ModuleFile(module_path)
    } else {
        state::ModuleSource::FlakeAttr("alloyModules.default".to_string())
    };

    let nixpkgs_url = args
        .nixpkgs_flake_url
        .unwrap_or(NIXPKGS_DEFAULT_SOURCE_URL.to_string());

    let alloy_url = std::env::var("ALLOY_URL").unwrap_or(ALLOY_DEFAULT_SOURCE_URL.to_string());

    let loader = state::StateLoader {
        module_source,
        workspace,
        alloy_url,
        nixpkgs_url,
    };

    let state = loader
        .load()
        .wrap_err("Failed to load state from the module")?;

    dbg!(state);

    Ok(())
}
