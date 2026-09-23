use crate::domain::ports::{Git, GitError};
use crate::infra::workspace::Workspace;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;

pub struct GitCli {
    pub workspace: Arc<Workspace>,
}

impl Git for GitCli {
    fn check_in_repo(&self, path: &Path) -> Result<(), GitError> {
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.workspace.root())
            // .arg(path.as_ref().parent().unwrap_or(Path::new(".")))
            .args(["rev-parse", "--is-inside-work-tree"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|e| GitError::System(Box::new(e)))?;

        if status.success() {
            Ok(())
        } else {
            Err(GitError::NotGitRepo {
                path: self.workspace.root(),
            })
        }
    }

    fn add_file(&self, path: &Path) -> Result<(), GitError> {
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.workspace.root())
            .arg("add")
            .arg(path)
            .status()
            .map_err(|e| GitError::System(Box::new(e)))?;

        if !status.success() {
            return Err(GitError::OperationFailed);
        }

        Ok(())
    }
}
