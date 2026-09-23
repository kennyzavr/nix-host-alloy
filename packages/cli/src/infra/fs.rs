use crate::{
    domain::ports::{FileSystem, FsError},
    infra::workspace::Workspace,
};
use std::{path::Path, sync::Arc};

pub struct LocalFs {
    pub workspace: Arc<Workspace>,
}

impl FileSystem for LocalFs {
    fn exists(&self, path: &Path) -> bool {
        self.workspace.root().join(path).exists()
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError> {
        let abs_path = self.workspace.root().join(path);

        if abs_path.is_dir() {
            return Err(FsError::DirExists {
                path: path.to_path_buf(),
            });
        }

        if !abs_path.is_file() {
            return Err(FsError::FileNotFound {
                path: path.to_path_buf(),
            });
        }

        std::fs::read(&abs_path).map_err(|e| FsError::ReadFailed {
            path: path.to_path_buf(),
            source: Box::new(e),
        })
    }

    fn write(&self, path: &Path, data: &[u8], force: bool) -> Result<(), FsError> {
        let abs_path = self.workspace.root().join(path);

        if abs_path.is_dir() {
            return Err(FsError::DirExists {
                path: path.to_path_buf(),
            });
        }

        if !force && abs_path.exists() {
            return Err(FsError::FileExists {
                path: path.to_path_buf(),
            });
        }

        if let Some(parent_dir) = abs_path.parent() {
            std::fs::create_dir_all(parent_dir).map_err(|e| FsError::CreateDirFailed {
                path: path.to_path_buf(),
                source: Box::new(e),
            })?;
        }

        std::fs::write(&abs_path, data).map_err(|e| FsError::WriteFailed {
            path: path.to_path_buf(),
            source: Box::new(e),
        })
    }
}
