use std::path::PathBuf;

use alloy_core::domain::env::{Env, EnvStateSource};

use crate::{ctx::Ctx, term_ui::TermUi};

mod facts;
mod gens;
mod indexes;
mod qemu;
mod secrets;

#[derive(clap::Parser, Debug)]
#[command(name = "alloy-cli", styles = TermUi::CLAP_STYLES)]
pub struct Args {
    #[arg(long = "workspace-root", env = Env::WORKSPACE_ROOT)]
    workspace_root: Option<PathBuf>,

    #[arg(long = "state-source", env = Env::STATE_SOURCE)]
    state_source: Option<EnvStateSource>,

    #[arg(long = "flake-url", env = Env::FLAKE_URL)]
    flake_url: String,

    #[arg(long = "module-attr", env = Env::MODULE_ATTR)]
    module_attr: String,

    #[arg(long = "alloy-input-attr", env = Env::INPUT_ATTR)]
    input_attr: String,

    #[arg(long = "depth", env = Env::DEPTH, default_value = Env::DEFAULT_DEPTH)]
    depth: u64,

    #[arg(long = "force", env = Env::FORCE)]
    force: Option<bool>,

    #[arg(long = "add-to-git", env = Env::ADD_TO_GIT)]
    add_to_git: Option<bool>,

    #[arg(
        long = "cache-dir",
        env = Env::CACHE_DIR,
    )]
    cache_dir: Option<PathBuf>,

    #[arg(
        long = "show-nix-trace",
        env = Env::SHOW_NIX_TRACE,
    )]
    show_nix_trace: Option<bool>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug)]
pub enum Cmd {
    Facts(facts::Args),
    Gens(gens::Args),
    Indexes(indexes::Args),
    Secrets(secrets::Args),
    Qemu(qemu::Args),
}

pub fn handle_args(args: Args) {
    let workspace_root = args
        .workspace_root
        .clone()
        .unwrap_or(std::env::current_dir().unwrap());

    let cache_dir = args
        .cache_dir
        .clone()
        .unwrap_or(workspace_root.join(".alloy"));

    if let Err(e) = std::fs::create_dir_all(&cache_dir) {
        eprintln!("Failed to create cache dir: {}", e);
        return;
    } else {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let log_file = cache_dir.join(format!("alloy-{}.log", ts));

        if let Ok(file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_file)
        {
            let _ = simplelog::WriteLogger::init(
                simplelog::LevelFilter::Debug,
                simplelog::Config::default(),
                file,
            );
        }
    }

    log::info!("Starting alloy-cli");
    log::debug!("Parsed Arguments: {:#?}", args);
    let alloy_envs: Vec<_> = std::env::vars()
        .filter(|(k, _)| k.starts_with("ALLOY_"))
        .collect();
    log::debug!("ALLOY_* Environment variables: {:#?}", alloy_envs);

    let env = Env {
        state_source: args.state_source,
        workspace_root,
        flake_url: args.flake_url,
        module_attr: args.module_attr,
        input_attr: args.input_attr,
        depth: args.depth,
        cache_dir,
        force: args.force,
        add_to_git: args.add_to_git,
        show_nix_trace: args.show_nix_trace,
    };

    let mut ctx = Ctx {
        env,
        system: alloy_core::infra::System {},
    };

    let ui = TermUi { depth: args.depth };

    match args.cmd {
        Cmd::Facts(cmd_args) => facts::handle(cmd_args, &mut ctx, ui),
        Cmd::Secrets(cmd_args) => secrets::handle(cmd_args, &mut ctx, ui),
        Cmd::Indexes(cmd_args) => indexes::handle(cmd_args, &mut ctx, ui),
        Cmd::Gens(cmd_args) => gens::handle(cmd_args, &mut ctx, ui),
        Cmd::Qemu(cmd_args) => qemu::handle(cmd_args, &mut ctx, ui),
    }
}
