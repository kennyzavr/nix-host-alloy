use std::path::PathBuf;

use crate::{ctx::Ctx, term_ui::TermUi};

mod facts;
mod generators;
mod indexes;
mod secrets;

const NIXPKGS_DEFAULT_SOURCE_URL: &str = "nixpkgs";
const ALLOY_DEFAULT_SOURCE_URL: &str = "github:kennyzavr/nix-host-alloy";

#[derive(clap::Parser, Debug)]
#[command(name = "alloy-cli", styles = TermUi::CLAP_STYLES)]
pub struct Args {
    #[arg(long = "root", env = "ALLOY_ROOT", default_value = ".")]
    root_dir: PathBuf,

    #[arg(long = "state-path", env = "ALLOY_STATE_PATH")]
    state_path: Option<PathBuf>,

    #[arg(long = "alloy-url", env = "ALLOY_URL", default_value = ALLOY_DEFAULT_SOURCE_URL)]
    alloy_url: String,

    #[arg(long = "nixpkgs-url", env = "ALLOY_NIXPKGS_URL", default_value = NIXPKGS_DEFAULT_SOURCE_URL)]
    nixpkgs_url: String,

    #[arg(long = "depth", env = "ALLOY_DEPTH", default_value = "0")]
    depth: u32,

    #[arg(
        long = "cache-dir",
        env = "ALLOY_CACHE_DIR",
        default_value = "./.alloy"
    )]
    cache_dir: PathBuf,

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
    if let Err(e) = std::fs::create_dir_all(&args.cache_dir) {
        eprintln!("Failed to create cache dir: {}", e);
    } else {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let log_file = args.cache_dir.join(format!("alloy-{}.log", ts));
        
        if let Ok(file) = std::fs::OpenOptions::new().create(true).append(true).open(&log_file) {
            let _ = simplelog::WriteLogger::init(
                simplelog::LevelFilter::Debug,
                simplelog::Config::default(),
                file,
            );
        }
    }

    log::info!("Starting alloy-cli");
    log::debug!("Parsed Arguments: {:#?}", args);
    let alloy_envs: Vec<_> = std::env::vars().filter(|(k, _)| k.starts_with("ALLOY_")).collect();
    log::debug!("ALLOY_* Environment variables: {:#?}", alloy_envs);

    let ctx = Ctx::new(
        args.root_dir,
        args.module_source.module_path,
        args.module_source.flake_attr,
        args.depth,
        args.alloy_url,
        args.nixpkgs_url,
        args.state_path,
        args.cache_dir,
    );

    match args.cmd {
        Cmd::Facts(cmd_args) => facts::handle(cmd_args, &ctx),
        Cmd::Generators(cmd_args) => generators::handle(cmd_args, &ctx),
        Cmd::Indexes(cmd_args) => indexes::handle(cmd_args, &ctx),
        Cmd::Secrets(cmd_args) => secrets::handle(cmd_args, &ctx),
    }
}
