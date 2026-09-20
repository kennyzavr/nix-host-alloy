use std::path::PathBuf;

use eyre::Context;

pub struct Workspace {
    pub curr_dir: PathBuf,
    pub git: Option<WorkspaceGit>,
}

pub struct WorkspaceGit {
    pub dir: PathBuf,
    pub flake: Option<WorkspaceFlake>,
}

pub struct WorkspaceFlake {
    pub rel_dir: PathBuf,
}

impl Workspace {
    pub fn new(default_dir: Option<PathBuf>) -> eyre::Result<Self> {
        let curr_dir = match default_dir {
            Some(v) => v,
            None => std::env::current_dir().wrap_err("Failed to get current working directory")?,
        };

        let mut git_dir = None;
        let mut flake_dir = None;
        for dir in curr_dir.ancestors() {
            if flake_dir.is_none() && dir.join("flake.nix").is_file() {
                flake_dir = Some(dir.to_path_buf());
            }

            if git_dir.is_none() && dir.join(".git").is_dir() {
                git_dir = Some(dir.to_path_buf());
            }

            if git_dir.is_some() && flake_dir.is_some() {
                break;
            }
        }

        let flake_rel_dir = if let Some(ref git_dir) = git_dir
            && let Some(ref flake_dir) = flake_dir
            && let Ok(dir) = flake_dir.strip_prefix(git_dir)
        {
            Some(dir.to_path_buf())
        } else if let Some(ref _flake_dir) = flake_dir {
            // TODO: log warning: found 'flake.nix' outside of a git repo
            None
        } else {
            None
        };

        Ok(Self {
            curr_dir,
            git: git_dir.map(|dir| WorkspaceGit {
                dir,
                flake: flake_rel_dir.map(|rel_dir| WorkspaceFlake { rel_dir }),
            }),
        })
    }

    pub fn flake_url(&self) -> Option<String> {
        let Some(ref git) = self.git else {
            return None;
        };

        let Some(ref flake) = git.flake else {
            return None;
        };

        return Some(format!(
            "git+file://{}?dir={}",
            git.dir.to_str().unwrap(),
            flake.rel_dir.to_str().unwrap()
        ));
    }

    pub fn root(&self) -> String {
        match self.git {
            Some(ref git) if let Some(ref flake) = git.flake => {
                git.dir.join(&flake.rel_dir).into_string().unwrap()
            }
            _ => self.curr_dir.clone().into_string().unwrap(),
        }
    }
}
