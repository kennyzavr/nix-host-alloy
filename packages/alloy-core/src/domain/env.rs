use std::{fmt::Display, path::PathBuf, str::FromStr};

use serde::{Deserialize, Serialize};

use crate::domain::ports::NixBuildSpec;

#[derive(Debug, Clone)]
pub struct Env {
    pub state_source: Option<EnvStateSource>,
    pub workspace_root: PathBuf,
    pub flake_url: Option<String>,
    pub module_source: EnvModuleSource,
    pub depth: u64,
    pub alloy_url: String,
    pub nixpkgs_url: String,
    pub cache_dir: PathBuf,
    pub force: Option<bool>,
    pub add_to_git: Option<bool>,
    pub show_nix_trace: Option<bool>,
}

impl Env {
    pub const WORKSPACE_ROOT: &'static str = "ALLOY_WORKSPACE_ROOT";
    pub const STATE_SOURCE: &'static str = "ALLOY_STATE_SOURCE";
    pub const MODULE_SOURCE: &'static str = "ALLOY_MODULE_SOURCE";
    pub const DEFAULT_MODULE_SOURCE: &'static str = "flake-attr=alloyModules.default";
    pub const FLAKE_URL: &'static str = "ALLOY_FLAKE_URL";
    pub const NIXPKGS_URL: &'static str = "ALLOY_NIXPKGS_URL";
    pub const DEFAULT_NIXPKGS_URL: &'static str = "nixpkgs";
    pub const ALLOY_URL: &'static str = "ALLOY_ALLOY_URL";
    pub const DEFAULT_ALLOY_URL: &'static str = "github:kennyzavr/nix-host-alloy";
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
        cmd.env(Self::NIXPKGS_URL, &self.nixpkgs_url);
        cmd.env(Self::ALLOY_URL, &self.alloy_url);
        cmd.env(Self::CACHE_DIR, &self.cache_dir);
        cmd.env(Self::MODULE_SOURCE, self.module_source.to_string());
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

        if let Some(path) = &self.flake_url {
            cmd.env(Self::FLAKE_URL, path);
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

#[derive(Debug, Clone)]
pub enum EnvModuleSource {
    File(PathBuf),
    FlakeAttr(String),
}

#[derive(Debug, thiserror::Error)]
#[error(
    r#"Failed to parse module source value, expected format: "{}=path" or "{}=str""#,
    EnvModuleSource::FILE,
    EnvModuleSource::FLAKE_ATTR
)]
pub struct EnvModuleSourceError;

impl FromStr for EnvModuleSource {
    type Err = EnvModuleSourceError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_once('=') {
            Some((Self::FILE, path)) => Ok(Self::File(PathBuf::from(path))),
            Some((Self::FLAKE_ATTR, path)) => Ok(Self::FlakeAttr(String::from(path))),
            Some((_, _)) => Err(EnvModuleSourceError),
            None => Ok(Self::FlakeAttr(String::from(s))),
        }
    }
}

impl Display for EnvModuleSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::File(path) => write!(f, "{}={}", Self::FILE, path.display()),
            Self::FlakeAttr(attr) => write!(f, "{}={}", Self::FLAKE_ATTR, attr),
        }
    }
}

impl EnvModuleSource {
    pub const FILE: &'static str = "file";
    pub const FLAKE_ATTR: &'static str = "flake-attr";
}
