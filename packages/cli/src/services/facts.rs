use crate::domain::models::{FactRecord, State};
use crate::domain::ports::{self, FileSystem, FsError, Git, GitError, NixEvaluator};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
pub enum ReadError {
    #[error("Failed to read fact file '{path}'")]
    File {
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Fact file '{path}' contains invalid UTF-8")]
    Utf8 {
        path: PathBuf,
        #[source]
        source: std::string::FromUtf8Error,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum WriteError {
    #[error("Failed to write fact file '{path}'")]
    File {
        path: PathBuf,
        #[source]
        source: FsError,
    },

    #[error("Failed to add fact file '{path}' to git")]
    Git {
        path: PathBuf,
        #[source]
        source: GitError,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum GetError {
    #[error("Failed to load state")]
    Nix(#[from] ports::NixError),

    #[error(transparent)]
    NotFound(#[from] NotFoundError),
}

#[derive(Debug, thiserror::Error)]
#[error("Fact `{name}` not found")]
pub struct NotFoundError {
    pub name: String,
}

pub struct Service {
    pub nix: Arc<dyn NixEvaluator>,
    pub fs: Arc<dyn FileSystem>,
    pub git: Arc<dyn Git>,
}

impl Service {
    pub fn get(&self, name: String) -> Result<FactRecord, GetError> {
        let mut state = self.nix.load_state()?;

        let fact = state
            .facts
            .remove(&name)
            .map(|state| FactRecord {
                name: name.clone(),
                state,
            })
            .ok_or_else(|| NotFoundError { name: name })?;

        Ok(fact)
    }

    pub fn exists(&self, record: &FactRecord) -> bool {
        self.fs.exists(&record.state.file)
    }

    pub fn read(&self, record: &FactRecord) -> Result<String, ReadError> {
        let data = self
            .fs
            .read(&record.state.file)
            .map_err(|e| ReadError::File {
                path: record.state.file.clone(),
                source: e,
            })?;

        String::from_utf8(data).map_err(|e| ReadError::Utf8 {
            path: record.state.file.clone(),
            source: e,
        })
    }

    pub fn write(
        &self,
        record: &FactRecord,
        value: String,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), WriteError> {
        let path = record.state.file.clone();

        if add_to_git {
            self.git.check_in_repo(&path).map_err(|e| WriteError::Git {
                path: path.clone(),
                source: e,
            })?;
        }

        self.fs
            .write(&path, value.as_bytes(), force)
            .map_err(|e| WriteError::File {
                path: path.clone(),
                source: e,
            })?;

        if add_to_git {
            self.git
                .add_file(&path)
                .map_err(|e| WriteError::Git { path, source: e })?;
        }

        Ok(())
    }
}
