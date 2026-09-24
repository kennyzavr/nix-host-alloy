use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
};

use alloy_core::{DynError, PathMark, ports::FileSystem};

use crate::workspace::Workspace;

pub struct LocalFs {
    pub workspace: Arc<Workspace>,
}

#[derive(thiserror::Error, Debug)]
enum ReadError {
    #[error("File {} not found", PathMark(&path))]
    FileNotFound { path: PathBuf },

    #[error("Expected a file or nothing at path {}, but found a directory", PathMark(&path))]
    DirExists { path: PathBuf },

    #[error("Failed to read file {}", PathMark(&path))]
    ReadFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(thiserror::Error, Debug)]
enum WriteError {
    #[error("File {} already exists", PathMark(&path))]
    FileExists { path: PathBuf },

    #[error("Expected a file or nothing at path {}, but found a directory", PathMark(&path))]
    DirExists { path: PathBuf },

    #[error("Failed to write to file {}", PathMark(&path))]
    WriteFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Failed to create parent directory for file {}", PathMark(&path))]
    CreateDirFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum GitError {
    #[error("System error while interacting with git")]
    System(#[source] std::io::Error),
    #[error("Git operation failed")]
    OperationFailed,
    #[error("Failed to add file {} to git, the file is not placed in a git repository", PathMark(&path))]
    NotGitRepo { path: PathBuf },
}

impl LocalFs {
    fn read(&self, path: &Path) -> Result<Vec<u8>, ReadError> {
        let abs_path = self.workspace.root().join(path);
        log::debug!("Reading file from local fs: {}", abs_path.display());

        if abs_path.is_dir() {
            log::error!("Cannot read file, it's a directory: {}", abs_path.display());
            return Err(ReadError::DirExists { path: abs_path });
        }

        if !abs_path.is_file() {
            log::warn!("File not found: {}", abs_path.display());
            return Err(ReadError::FileNotFound { path: abs_path });
        }

        std::fs::read(&abs_path).map_err(|source| ReadError::ReadFailed {
            path: path.to_path_buf(),
            source,
        })
    }

    fn write(&self, path: &Path, data: &[u8], force: bool) -> Result<(), WriteError> {
        let abs_path = self.workspace.root().join(path);
        log::debug!("Writing to file: {}, force={}", abs_path.display(), force);

        if abs_path.is_dir() {
            log::error!("Cannot write, target is a directory: {}", abs_path.display());
            return Err(WriteError::DirExists { path: abs_path });
        }

        if !force && abs_path.exists() {
            log::warn!("File already exists and force is not set: {}", abs_path.display());
            return Err(WriteError::FileExists { path: abs_path });
        }

        if let Some(parent_dir) = abs_path.parent() {
            std::fs::create_dir_all(parent_dir).map_err(|source| WriteError::CreateDirFailed {
                path: abs_path.clone(),
                source,
            })?;
        }

        std::fs::write(&abs_path, data).map_err(|source| WriteError::WriteFailed {
            path: abs_path,
            source,
        })
    }

    fn check_in_repo(&self, _path: &Path) -> Result<(), GitError> {
        log::debug!("Checking if workspace is a git repository: {}", self.workspace.root().display());
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.workspace.root())
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
                path: self.workspace.root(),
            })
        }
    }

    fn add_file_to_git(&self, path: &Path) -> Result<(), GitError> {
        log::info!("Adding file to git: {}", path.display());
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.workspace.root())
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

impl FileSystem for LocalFs {
    fn exists(&self, path: &Path) -> bool {
        self.workspace.root().join(path).exists()
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, DynError> {
        let data = self.read(path)?;

        Ok(data)
    }

    fn write(
        &self,
        path: &Path,
        data: &[u8],
        force: bool,
        add_to_git: bool,
    ) -> Result<(), DynError> {
        if add_to_git {
            self.check_in_repo(path)?;
        }

        self.write(path, data, force)?;
        self.add_file_to_git(path)?;

        Ok(())
    }
}
