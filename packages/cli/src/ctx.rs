use std::path::PathBuf;
use std::sync::Arc;

use crate::domain::models::State;
use crate::domain::ports::{CommandRunner, Crypto, FileSystem, Git, NixError, NixEvaluator};
use crate::infra::nix::ModuleSource;
use crate::infra::workspace::Workspace;
use crate::infra::{
    fs::LocalFs, git::GitCli, nix::NixAdapter, rage::Rage, runner::SystemRunner, ui::TerminalUi,
};
use crate::services::{facts, generators, indexes, secrets};

pub struct AppContext {
    pub workspace: Arc<Workspace>,
    pub fs: Arc<dyn FileSystem>,
    pub git: Arc<dyn Git>,
    pub crypto: Arc<dyn Crypto>,
    pub nix: Arc<dyn NixEvaluator>,
    pub runner: Arc<dyn CommandRunner>,
    pub ui: Arc<TerminalUi>,
    pub facts_service: Arc<facts::Service>,
    pub secrets_service: Arc<secrets::Service>,
    pub indexes_service: Arc<indexes::Service>,
    pub generators_service: Arc<generators::Service>,
    pub state_file_slot: Arc<std::sync::Mutex<Option<PathBuf>>>,
}

impl AppContext {
    pub fn new(
        default_dir: Option<PathBuf>,
        module_path: Option<PathBuf>,
        flake_attr: Option<String>,
        depth: u32,
        alloy_url: String,
        nixpkgs_url: String,
        state_file: Option<PathBuf>,
    ) -> Self {
        let state_file_slot = Arc::new(std::sync::Mutex::new(state_file));
        let workspace = Arc::new(Workspace::new(default_dir).unwrap());

        let module_source = if let Some(module_path) = &module_path {
            ModuleSource::ModuleFile(module_path.clone())
        } else if let Some(flake_attr) = &flake_attr {
            ModuleSource::FlakeAttr(flake_attr.clone())
        } else {
            ModuleSource::FlakeAttr("alloyModules.default".to_string())
        };

        let fs: Arc<dyn FileSystem> = Arc::new(LocalFs {
            workspace: Arc::clone(&workspace),
        });

        let git: Arc<dyn Git> = Arc::new(GitCli {
            workspace: Arc::clone(&workspace),
        });

        let crypto: Arc<dyn Crypto> = Arc::new(Rage);

        let nix: Arc<dyn NixEvaluator> = Arc::new(NixAdapter {
            module_source,
            workspace: Arc::clone(&workspace),
            alloy_url: alloy_url.clone(),
            nixpkgs_url: nixpkgs_url.clone(),
            state_file_slot: Arc::clone(&state_file_slot),
        });

        let runner: Arc<dyn CommandRunner> = Arc::new(SystemRunner {
            workspace: Arc::clone(&workspace),
            depth,
            alloy_url: alloy_url,
            nixpkgs_url: nixpkgs_url,
            module_path,
            flake_attr,
            state_file_slot: Arc::clone(&state_file_slot),
        });

        let ui = Arc::new(TerminalUi { depth });

        let facts_service = Arc::new(facts::Service {
            nix: Arc::clone(&nix),
            fs: Arc::clone(&fs),
            git: Arc::clone(&git),
        });

        let secrets_service = Arc::new(secrets::Service {
            nix: Arc::clone(&nix),
            fs: Arc::clone(&fs),
            git: Arc::clone(&git),
            crypto: Arc::clone(&crypto),
        });

        let indexes_service = Arc::new(indexes::Service {
            nix: Arc::clone(&nix),
            facts_service: Arc::clone(&facts_service),
        });

        let generators_service = Arc::new(generators::Service {
            nix: Arc::clone(&nix),
            fs: Arc::clone(&fs),
            runner: Arc::clone(&runner),
        });

        Self {
            workspace,
            fs,
            git,
            crypto,
            runner,
            nix,
            ui,
            facts_service,
            secrets_service,
            indexes_service,
            generators_service,
            state_file_slot,
        }
    }
}
