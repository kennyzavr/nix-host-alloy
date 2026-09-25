use std::{
    path::{Path, PathBuf},
    process::Command,
};

use crate::{
    domain::{PathMarker, ports},
    infra::System,
};

#[derive(Debug, thiserror::Error)]
pub enum GitError {
    #[error("System error while interacting with git")]
    System(#[source] std::io::Error),
    #[error("Git operation failed")]
    OperationFailed,
    #[error("Failed to add file {} to git, the file is not placed in a git repository", PathMarker(&path))]
    NotGitRepo { path: PathBuf },
}

impl System {
    fn check_in_repo(&self, path: &Path) -> Result<(), GitError> {
        let parent_dir = path.parent().unwrap_or(&Path::new("."));
        let status = Command::new("git")
            .arg("-C")
            .arg(parent_dir)
            .args(["rev-parse", "--is-inside-work-tree"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(GitError::System)?;

        if status.success() {
            Ok(())
        } else {
            log::warn!("Workspace is not a git repository");
            Err(GitError::NotGitRepo {
                path: path.to_path_buf(),
            })
        }
    }

    fn add_file_to_git(&self, path: &Path) -> Result<(), GitError> {
        let parent_dir = path.parent().unwrap_or(&Path::new("."));
        log::info!("Adding file to git: {}", path.display());
        let status = Command::new("git")
            .arg("-C")
            .arg(parent_dir)
            .arg("add")
            .arg(path)
            .status()
            .map_err(GitError::System)?;

        if !status.success() {
            log::error!("Failed to add file to git: {}", path.display());
            return Err(GitError::OperationFailed);
        }

        Ok(())
    }
}

impl ports::Git for System {
    fn check(&self, file: &Path) -> Result<(), crate::domain::DynError> {
        self.check_in_repo(file)?;
        Ok(())
    }

    fn add(&self, path: &Path) -> Result<(), crate::domain::DynError> {
        self.add_file_to_git(path)?;
        Ok(())
    }
}
