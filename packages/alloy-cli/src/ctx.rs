use std::path::PathBuf;
use std::sync::Arc;

use alloy_infra::gen_runner::GenScriptSpawner;
use alloy_infra::local_fs::LocalFs;
use alloy_infra::nix::{ModuleSource, NixAdapter};
use alloy_infra::rage::Rage;
use alloy_infra::workspace::Workspace;

use crate::term_ui::TermUi;

pub struct Ctx {
    pub state_path: Arc<std::sync::Mutex<Option<PathBuf>>>,
    pub workspace: Arc<Workspace>,
    pub local_fs: LocalFs,
    pub rage: Rage,
    pub nix: NixAdapter,
    pub gen_runner: GenScriptSpawner,
    pub ui: TermUi,
}

impl Ctx {
    pub fn new(
        workspace_dir: PathBuf,
        module_path: Option<PathBuf>,
        flake_attr: Option<String>,
        depth: u32,
        alloy_url: String,
        nixpkgs_url: String,
        state_path: Option<PathBuf>,
        cache_dir: PathBuf,
    ) -> Self {
        let state_path = Arc::new(std::sync::Mutex::new(state_path));
        let workspace = Arc::new(Workspace::new(workspace_dir));

        let module_source = if let Some(module_path) = &module_path {
            ModuleSource::ModuleFile(module_path.clone())
        } else if let Some(flake_attr) = &flake_attr {
            ModuleSource::FlakeAttr(flake_attr.clone())
        } else {
            ModuleSource::FlakeAttr("alloyModules.default".to_string())
        };

        Self {
            state_path: Arc::clone(&state_path),
            workspace: Arc::clone(&workspace),
            local_fs: LocalFs {
                workspace: Arc::clone(&workspace),
            },
            rage: Rage,
            nix: NixAdapter {
                module_source,
                workspace: Arc::clone(&workspace),
                alloy_url: alloy_url.clone(),
                nixpkgs_url: nixpkgs_url.clone(),
                state_path: Arc::clone(&state_path),
            },
            gen_runner: GenScriptSpawner {
                workspace,
                depth,
                alloy_url,
                nixpkgs_url,
                module_path,
                flake_attr,
                state_path,
                cache_dir,
            },
            ui: TermUi { depth },
        }
    }
}

impl alloy_core::ctx::Ctx for Ctx {
    fn age(&self) -> &dyn alloy_core::ports::Age {
        &self.rage
    }

    fn fs(&self) -> &dyn alloy_core::ports::FileSystem {
        &self.local_fs
    }

    fn gen_runner(&self) -> &dyn alloy_core::ports::GenRunner {
        &self.gen_runner
    }
}
