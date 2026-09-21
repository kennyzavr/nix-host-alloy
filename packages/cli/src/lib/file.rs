use std::path::{Path, PathBuf};

use crate::lib::StyledPath;

use super::git;
use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
pub enum ReadError {
    #[error("File {} not found.", StyledPath(&path))]
    #[diagnostic(code(alloy::file::file_not_found))]
    FileNotFound { path: PathBuf },
    #[error("System I/O error while reading file {}.", StyledPath(&path))]
    #[diagnostic(code(alloy::file::io_error))]
    Io {
        path: PathBuf,
        #[source]
        inner: std::io::Error,
    },
}

#[derive(Error, Diagnostic, Debug)]
pub enum WriteError {
    #[error("File {} already exists.", StyledPath(&path))]
    #[diagnostic(
        code(alloy::file::file_exists),
        help("The operation must be called with override permissions.")
    )]
    FileExists { path: PathBuf },
    #[error(
        "Expected a file or nothing at path {}, but found a directory."
    , StyledPath(&path))]
    #[diagnostic(
        code(alloy::file::dir_found),
        help("Remove or rename the directory, and try again")
    )]
    DirExists { path: PathBuf },
    #[error("Failed to add file {} to git, the file is not placed in git repo", StyledPath(&path))]
    #[diagnostic(code(alloy::file::no_git_repo))]
    NotGitRepo { path: PathBuf },
    #[error("Failed to add file {} to git.", StyledPath(&path))]
    #[diagnostic(forward(inner))]
    Git {
        path: PathBuf,
        #[source]
        inner: git::Error,
    },
    #[error("I/O error while trying to create parent dir for file {}.", StyledPath(&path))]
    #[diagnostic(code(alloy::io_error))]
    ParentDir {
        path: PathBuf,
        #[source]
        inner: std::io::Error,
    },
    #[error("I/O error while writing to file {}.", StyledPath(&path))]
    #[diagnostic(code(alloy::io_error))]
    Write {
        path: PathBuf,
        #[source]
        inner: std::io::Error,
    },
}

pub fn read(path: &Path) -> Result<Vec<u8>, ReadError> {
    if !path.is_file() {
        return Err(ReadError::FileNotFound {
            path: path.to_path_buf(),
        }
        .into());
    }

    let content = std::fs::read(&path).map_err(|err| ReadError::Io {
        path: path.to_path_buf(),
        inner: err,
    })?;

    Ok(content)
}

pub fn write(path: &Path, value: &[u8], force: bool, add_to_git: bool) -> Result<(), WriteError> {
    if path.is_dir() {
        return Err(WriteError::DirExists {
            path: path.to_path_buf(),
        });
    }

    if !force && path.exists() {
        return Err(WriteError::FileExists {
            path: path.to_path_buf(),
        });
    }

    if let Some(parent_dir) = path.parent() {
        std::fs::create_dir_all(parent_dir).map_err(|err| WriteError::ParentDir {
            path: path.to_path_buf(),
            inner: err,
        })?;
    }

    if add_to_git {
        match git::is_repo(&path) {
            Ok(true) => (),
            Ok(false) => {
                return Err(WriteError::NotGitRepo {
                    path: path.to_path_buf(),
                });
            }
            Err(err) => {
                return Err(WriteError::Git {
                    path: path.to_path_buf(),
                    inner: err,
                });
            }
        };
    }

    match std::fs::write(&path, value) {
        Ok(_) => (),
        Err(err) => {
            return Err(WriteError::Write {
                path: path.to_path_buf(),
                inner: err,
            });
        }
    };

    match git::add_file(&path) {
        Ok(_) => (),
        Err(err) => {
            return Err(WriteError::Git {
                path: path.to_path_buf(),
                inner: err,
            });
        }
    };

    Ok(())
}
