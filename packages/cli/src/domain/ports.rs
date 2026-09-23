use super::models::State;
use std::path::{Path, PathBuf};

pub type InfraError = Box<dyn std::error::Error + Send + Sync + 'static>;

#[derive(Debug, thiserror::Error)]
pub enum NixError {
    #[error("Not in a valid flake workspace")]
    NotFlakeRoot,
    #[error("Failed to evaluate flake attribute")]
    EvalFlakeAttr(#[source] InfraError),
    #[error("Failed to execute nix command")]
    Execution(#[source] InfraError),
    #[error("Failed to parse state configuration")]
    ParseState(#[source] InfraError),
}

pub trait NixEvaluator {
    fn load_state(&self) -> Result<State, NixError>;
    fn get_generator_bin_path(&self, name: &str) -> Result<PathBuf, NixError>;
    fn eval_generator_raw(&self, name: &str) -> Result<(), NixError>;
    fn eval_index_raw(&self, name: &str) -> Result<(), NixError>;
}

#[derive(Debug, thiserror::Error)]
pub enum CommandError {
    #[error("Failed to launch command")]
    LaunchFailed(#[source] InfraError),
    #[error("Command exited with a failure status")]
    CommandFailed,
}

pub trait CommandRunner {
    fn spawn_generator(
        &self,
        bin_path: &Path,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), CommandError>;
}

#[derive(Debug, thiserror::Error)]
pub enum FsError {
    #[error("File '{path}' already exists")]
    FileExists { path: PathBuf },
    #[error("Expected a file or nothing at path '{path}', but found a directory")]
    DirExists { path: PathBuf },
    #[error("File '{path}' not found")]
    FileNotFound { path: PathBuf },
    #[error("Failed to read file '{path}'")]
    ReadFailed {
        path: PathBuf,
        #[source]
        source: InfraError,
    },
    #[error("Failed to write to file '{path}'")]
    WriteFailed {
        path: PathBuf,
        #[source]
        source: InfraError,
    },
    #[error("Failed to create parent directory for file '{path}'")]
    CreateDirFailed {
        path: PathBuf,
        #[source]
        source: InfraError,
    },
}

pub trait FileSystem {
    fn exists(&self, path: &Path) -> bool;
    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError>;
    fn write(&self, path: &Path, data: &[u8], force: bool) -> Result<(), FsError>;
}

#[derive(Debug, thiserror::Error)]
pub enum GitError {
    #[error("System error while interacting with git")]
    System(#[source] InfraError),
    #[error("Git operation failed")]
    OperationFailed,
    #[error("Failed to add file '{path}' to git, the file is not placed in a git repository")]
    NotGitRepo { path: PathBuf },
}

pub trait Git {
    fn check_in_repo(&self, path: &Path) -> Result<(), GitError>;
    fn add_file(&self, path: &Path) -> Result<(), GitError>;
}

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("System error during cryptographic operation")]
    System(#[source] InfraError),
    #[error("Cryptographic operation failed")]
    OperationFailed,
}

pub trait Crypto {
    fn encrypt(&self, recipients: &[String], data: &[u8]) -> Result<Vec<u8>, CryptoError>;
    fn decrypt(&self, identities: &[String], data: &[u8]) -> Result<Vec<u8>, CryptoError>;
}
