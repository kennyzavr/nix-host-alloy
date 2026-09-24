use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use alloy_core::DynError;
use alloy_core::ports::GenRunner;

use crate::workspace::Workspace;

pub struct GenScriptSpawner {
    pub workspace: Arc<Workspace>,
    pub depth: u32,
    pub alloy_url: String,
    pub nixpkgs_url: String,
    pub module_path: Option<PathBuf>,
    pub flake_attr: Option<String>,
    pub cache_dir: PathBuf,
    pub state_path: Arc<std::sync::Mutex<Option<PathBuf>>>,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Failed to launch script")]
    LaunchFailed(#[source] std::io::Error),
    #[error("Command exited with {0}")]
    CommandFailed(std::process::ExitStatus),
}

impl GenScriptSpawner {
    fn spawn_generator(&self, bin_path: &Path, force: bool, add_to_git: bool) -> Result<(), Error> {
        // FIXME
        let state_path = self.state_path.lock().unwrap();
        let state_path = state_path.as_ref().unwrap();

        let relative_bin_path = bin_path.strip_prefix("/").unwrap_or(bin_path);
        let mut cmd = Command::new(state_path.join(relative_bin_path));

        if let Ok(current_exe) = std::env::current_exe() {
            cmd.env("ALLOY_BIN", current_exe);
        }

        cmd.env("ALLOY_STATE_PATH", state_path);

        cmd.env("ALLOY_ROOT", &self.workspace.root());
        cmd.env("ALLOY_DEPTH", (self.depth + 1).to_string());
        cmd.env("ALLOY_URL", &self.alloy_url);
        cmd.env("ALLOY_NIXPKGS_URL", &self.nixpkgs_url);
        cmd.env("ALLOY_CACHE_DIR", &self.cache_dir);

        if let Some(module_path) = &self.module_path {
            cmd.env("ALLOY_MODULE", module_path);
        }

        if let Some(flake_attr) = &self.flake_attr {
            cmd.env("ALLOY_ATTR", flake_attr);
        }

        if force {
            cmd.env("ALLOY_FORCE", "true");
        }

        if add_to_git {
            cmd.env("ALLOY_ADD_TO_GIT", "true");
        }

        log::debug!(
            "Spawning generator script: {}",
            cmd.get_program().to_string_lossy()
        );

        let status = cmd.status().map_err(|e| {
            log::error!("Failed to launch script {}: {}", bin_path.display(), e);
            Error::LaunchFailed(e)
        })?;

        if !status.success() {
            log::error!("Command failed with status: {}", status);
            return Err(Error::CommandFailed(status));
        }

        log::debug!("Script execution successful");
        Ok(())
    }
}

impl GenRunner for GenScriptSpawner {
    fn run(&self, bin_path: &Path, force: bool, add_to_git: bool) -> Result<(), DynError> {
        self.spawn_generator(bin_path, force, add_to_git)?;
        Ok(())
    }
}
