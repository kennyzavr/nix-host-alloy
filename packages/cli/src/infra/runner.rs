use crate::domain::ports::{CommandError, CommandRunner};
use crate::infra::workspace::Workspace;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

pub struct SystemRunner {
    pub workspace: Arc<Workspace>,
    pub depth: u32,
    pub alloy_url: String,
    pub nixpkgs_url: String,
    pub module_path: Option<PathBuf>,
    pub flake_attr: Option<String>,
    pub state_file_slot: Arc<std::sync::Mutex<Option<PathBuf>>>,
}

impl CommandRunner for SystemRunner {
    fn spawn_generator(
        &self,
        bin_path: &Path,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), CommandError> {
        let mut cmd = Command::new(self.workspace.root().join(bin_path));

        if let Ok(current_exe) = std::env::current_exe() {
            cmd.env("ALLOY_BIN", current_exe);
        }

        if let Some(path) = &*self.state_file_slot.lock().unwrap() {
            cmd.env("ALLOY_STATE_FILE", path);
        }

        cmd.env("ALLOY_ROOT", &self.workspace.root());
        cmd.env("ALLOY_DEPTH", (self.depth + 1).to_string());
        cmd.env("ALLOY_URL", &self.alloy_url);
        cmd.env("ALLOY_NIXPKGS_URL", &self.nixpkgs_url);

        if let Some(module_path) = &self.module_path {
            cmd.env("ALLOY_MODULE", module_path);
        }

        if let Some(flake_attr) = &self.flake_attr {
            cmd.env("ALLOY_ATTR", flake_attr);
        }

        if force {
            cmd.env("ALLOY_FORCE", "1");
        }

        if add_to_git {
            cmd.env("ALLOY_ADD_TO_GIT", "1");
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| CommandError::LaunchFailed(Box::new(e)))?;

        let status = child
            .wait()
            .map_err(|e| CommandError::LaunchFailed(Box::new(e)))?;

        if !status.success() {
            return Err(CommandError::CommandFailed);
        }

        Ok(())
    }
}
