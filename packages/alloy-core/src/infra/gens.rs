use std::{path::Path, process::Command};

use crate::domain::{DynError, env::Env, ports::GenRunner};

use super::{ExecError, System};

impl GenRunner for System {
    fn exec_gen(
        &self,
        script_path: &Path,
        force: bool,
        add_to_git: bool,
        env: &Env,
    ) -> Result<(), DynError> {
        self.exec_gen(script_path, force, add_to_git, env)?;
        Ok(())
    }
}

impl System {
    fn exec_gen(
        &self,
        script_path: &Path,
        force: bool,
        add_to_git: bool,
        env: &Env,
    ) -> Result<(), ExecError> {
        let mut cmd = Command::new(script_path);

        // TODO
        if let Ok(current_exe) = std::env::current_exe() {
            cmd.env("ALLOY_BIN", current_exe);
        }

        env.inject_to_cmd(&mut cmd, Some(force), Some(add_to_git), true);

        log::debug!(
            "Spawning generator script: {}",
            cmd.get_program().to_string_lossy()
        );

        let status = cmd.status().map_err(|e| {
            log::error!("Failed to launch script {}: {}", script_path.display(), e);
            ExecError::Exec(e)
        })?;

        if !status.success() {
            log::error!("Command failed with status: {}", status);
            return Err(ExecError::Status(status));
        }

        log::debug!("Script execution successful");
        Ok(())
    }
}
