use std::path::{Path, PathBuf};

use crate::domain::{DynError, PathMarker, ports};

use super::System;

#[derive(thiserror::Error, Debug)]
enum ReadError {
    #[error("File {} not found", PathMarker(&path))]
    FileNotFound { path: PathBuf },

    #[error("Expected a file or nothing at path {}, but found a directory", PathMarker(&path))]
    DirExists { path: PathBuf },

    #[error("Failed to read file {}", PathMarker(&path))]
    ReadFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(thiserror::Error, Debug)]
enum WriteError {
    #[error("File {} already exists", PathMarker(&path))]
    FileExists { path: PathBuf },

    #[error("Expected a file or nothing at path {}, but found a directory", PathMarker(&path))]
    DirExists { path: PathBuf },

    #[error("Failed to write to file {}", PathMarker(&path))]
    WriteFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Failed to create parent directory for file {}", PathMarker(&path))]
    CreateDirFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(thiserror::Error, Debug)]
#[error("Failed to crate parent dirs for path {}", PathMarker(&path))]
struct ParentDirError {
    path: PathBuf,
    #[source]
    source: std::io::Error,
}

impl System {
    fn exists(&self, file: &Path) -> bool {
        file.exists()
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, ReadError> {
        log::debug!("Reading file from local fs: {}", path.display());

        if path.is_dir() {
            log::error!("Cannot read file, it's a directory: {}", path.display());
            return Err(ReadError::DirExists {
                path: path.to_path_buf(),
            });
        }

        if !path.is_file() {
            log::warn!("File not found: {}", path.display());
            return Err(ReadError::FileNotFound {
                path: path.to_path_buf(),
            });
        }

        std::fs::read(&path).map_err(|source| ReadError::ReadFailed {
            path: path.to_path_buf(),
            source,
        })
    }

    fn mk_parent_dirs(&self, path: &Path) -> Result<(), ParentDirError> {
        let parent_dir = path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(parent_dir).map_err(|source| ParentDirError {
            path: path.to_path_buf(),
            source,
        })?;
        Ok(())
    }

    fn write(&self, path: &Path, data: &[u8], force: bool) -> Result<(), WriteError> {
        log::debug!("Writing to file: {}, force={}", path.display(), force);

        if path.is_dir() {
            log::error!("Cannot write, target is a directory: {}", path.display());
            return Err(WriteError::DirExists {
                path: path.to_path_buf(),
            });
        }

        if !force && path.exists() {
            log::warn!(
                "File already exists and force is not set: {}",
                path.display()
            );
            return Err(WriteError::FileExists {
                path: path.to_path_buf(),
            });
        }

        if let Some(parent_dir) = path.parent() {
            std::fs::create_dir_all(parent_dir).map_err(|source| WriteError::CreateDirFailed {
                path: path.to_path_buf(),
                source,
            })?;
        }

        std::fs::write(&path, data).map_err(|source| WriteError::WriteFailed {
            path: path.to_path_buf(),
            source,
        })
    }
}

impl ports::Fs for System {
    fn exists(&self, file: &Path) -> bool {
        self.exists(file)
    }

    fn read(&self, file: &Path) -> Result<Vec<u8>, DynError> {
        let data = self.read(file)?;
        Ok(data)
    }

    fn mk_parent_dirs(&self, path: &Path) -> Result<(), DynError> {
        self.mk_parent_dirs(path)?;
        Ok(())
    }

    fn write(&self, file: &Path, data: &[u8], force: bool) -> Result<(), DynError> {
        self.write(file, data, force)?;
        Ok(())
    }
}
