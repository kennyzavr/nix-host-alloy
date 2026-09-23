use std::path::PathBuf;

use crate::{
    ctx::AppContext,
    infra::{
        fs::LocalFs,
        git::GitCli,
        nix::{ModuleSource, NixAdapter},
        rage::Rage,
        runner::SystemRunner,
        ui::TerminalUi,
    },
};

mod facts;
mod generators;
mod indexes;
mod secrets;

const NIXPKGS_DEFAULT_SOURCE_URL: &str = "nixpkgs";
const ALLOY_DEFAULT_SOURCE_URL: &str = "github:kennyzavr/nix-host-alloy";

#[derive(clap::Parser, Debug)]
#[command(name = "alloy-cli", styles = TerminalUi::CLAP_STYLES)]
pub struct Args {
    #[arg(long = "root", env = "ALLOY_ROOT")]
    root_dir: Option<PathBuf>,

    #[arg(long = "state-file", env = "ALLOY_STATE_FILE")]
    state_file: Option<PathBuf>,

    #[arg(long = "alloy-url", env = "ALLOY_URL", default_value = ALLOY_DEFAULT_SOURCE_URL)]
    alloy_url: String,

    #[arg(long = "nixpkgs-url", env = "ALLOY_NIXPKGS_URL", default_value = NIXPKGS_DEFAULT_SOURCE_URL)]
    nixpkgs_url: String,

    #[arg(long = "depth", env = "ALLOY_DEPTH", default_value = "0")]
    depth: u32,

    #[command(flatten)]
    module_source: ModuleSourceArgs,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Args, Debug)]
#[group(required = false, multiple = false)]
struct ModuleSourceArgs {
    #[arg(long = "module", env = "ALLOY_MODULE")]
    module_path: Option<PathBuf>,
    #[arg(long = "attr", env = "ALLOY_ATTR")]
    flake_attr: Option<String>,
}

#[derive(clap::Subcommand, Debug)]
pub enum Cmd {
    Facts(facts::Args),
    Generators(generators::Args),
    Indexes(indexes::Args),
    Secrets(secrets::Args),
}

pub fn handle_args(args: Args) {
    let ctx = AppContext::new(
        args.root_dir,
        args.module_source.module_path,
        args.module_source.flake_attr,
        args.depth,
        args.alloy_url,
        args.nixpkgs_url,
        args.state_file,
    );

    match args.cmd {
        Cmd::Facts(cmd_args) => facts::handle(cmd_args, &ctx),
        Cmd::Generators(cmd_args) => generators::handle(cmd_args, &ctx),
        Cmd::Indexes(cmd_args) => indexes::handle(cmd_args, &ctx),
        Cmd::Secrets(cmd_args) => secrets::handle(cmd_args, &ctx),
    }
}
