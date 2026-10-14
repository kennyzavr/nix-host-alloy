use std::{fmt::Display, path::PathBuf, str::FromStr};

use serde::{Deserialize, Serialize};

use crate::domain::ports::NixBuildSpec;

#[derive(Debug, Clone)]
pub struct Env {
    pub state_source: Option<EnvStateSource>,
    pub workspace_root: PathBuf,
    pub flake_url: String,
    pub input_attr: String,
    pub module_attr: String,
    pub depth: u64,
    pub cache_dir: PathBuf,
    pub force: Option<bool>,
    pub add_to_git: Option<bool>,
    pub show_nix_trace: Option<bool>,
}

impl Env {
    pub const STATE_SOURCE: &'static str = "ALLOY_STATE_SOURCE";
    pub const WORKSPACE_ROOT: &'static str = "ALLOY_WORKSPACE_ROOT";
    pub const FLAKE_URL: &'static str = "ALLOY_FLAKE_URL";
    pub const INPUT_ATTR: &'static str = "ALLOY_INPUT_ATTR";
    pub const MODULE_ATTR: &'static str = "ALLOY_MODULE_ATTR";
    pub const CACHE_DIR: &'static str = "ALLOY_CACHE_DIR";
    pub const FORCE: &'static str = "ALLOY_FORCE";
    pub const ADD_TO_GIT: &'static str = "ALLOY_ADD_TO_GIT";
    pub const DEPTH: &'static str = "ALLOY_DEPTH";
    pub const DEFAULT_DEPTH: &'static str = "0";
    pub const SHOW_NIX_TRACE: &'static str = "ALLOY_SHOW_NIX_TRACE";

    pub fn inject_to_cmd(
        &self,
        cmd: &mut std::process::Command,
        force: Option<bool>,
        add_to_git: Option<bool>,
        increase_depth: bool,
    ) {
        cmd.env(Self::WORKSPACE_ROOT, &self.workspace_root);
        cmd.env(Self::FLAKE_URL, &self.flake_url);
        cmd.env(Self::MODULE_ATTR, &self.module_attr);
        cmd.env(Self::INPUT_ATTR, &self.input_attr);
        cmd.env(Self::CACHE_DIR, &self.cache_dir);
        cmd.env(
            Self::DEPTH,
            if increase_depth {
                self.depth + 1
            } else {
                self.depth
            }
            .to_string(),
        );

        if let Some(show_nix_trace) = self.show_nix_trace {
            cmd.env(Self::SHOW_NIX_TRACE, show_nix_trace.to_string());
        }

        if let Some(state_source) = &self.state_source {
            cmd.env(Self::STATE_SOURCE, state_source.to_string());
        }

        if let Some(force) = force.or(self.force) {
            cmd.env(Self::FORCE, force.to_string());
        }

        if let Some(add_to_git) = add_to_git.or(self.add_to_git) {
            cmd.env(Self::ADD_TO_GIT, add_to_git.to_string());
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvStateSource {
    pub spec: NixBuildSpec,
    pub dir_path: PathBuf,
}

#[derive(Debug, thiserror::Error)]
#[error("Failed to parse state source value")]
pub struct EnvStateSourceError(#[from] serde_json::Error);

impl FromStr for EnvStateSource {
    type Err = EnvStateSourceError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let val = serde_json::from_str(s)?;
        Ok(val)
    }
}

impl Display for EnvStateSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", serde_json::to_string(self).unwrap())
    }
}
