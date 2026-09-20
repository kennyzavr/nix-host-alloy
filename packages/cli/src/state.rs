use std::io::Read;
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
};

use eyre::{OptionExt, Result};
use serde::Deserialize;
use tempfile::NamedTempFile;

use crate::sh::exec_sh_script;
use crate::workspace::Workspace;

#[derive(Deserialize, Debug, Clone)]
pub struct State {
    pub name: String,
    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,
    pub hosts: HashMap<String, HostState>,
    pub jails: HashMap<String, JailState>,
    pub overlays: HashMap<String, OverlayState>,
    pub secrets: HashMap<String, SecretState>,
    pub facts: HashMap<String, FactState>,
    pub generators: HashMap<String, GeneratorState>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct HostState {
    pub tags: Vec<String>,
    pub overlays: HashMap<String, NodeOverlayState>,
    pub secrets: HashMap<String, NodeSecretState>,
    pub facts: HashMap<String, NodeFactState>,
    #[serde(rename = "secretsAgeKeyPairs")]
    pub secrets_age_key_pairs: Vec<AgeKeyPair>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct JailState {
    pub host: String,
    pub tags: Vec<String>,
    pub secrets: HashMap<String, NodeSecretState>,
    pub overlays: HashMap<String, NodeOverlayState>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct FactState {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct NodeFactState {
    pub path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
pub struct GeneratorState {
    pub wants: Vec<String>,
    #[serde(rename = "wantedBy")]
    pub wanted_by: Vec<String>,
    pub before: Vec<String>,
    pub after: Vec<String>,
    pub tags: Vec<String>,
    pub secrets: HashSet<String>,
    pub facts: HashSet<String>,
    pub bin: Option<PathBuf>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct IndexState {
    pub keys: HashSet<String>,
    #[serde(rename = "minValue")]
    pub min_value: u64,
    #[serde(rename = "maxValue")]
    pub max_value: u64,
    #[serde(rename = "factName")]
    pub fact_name: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct OverlayState {
    #[serde(rename = "ipv6Prefix")]
    pub ipv6_prefix: String,
    pub tags: Vec<String>,
    pub links: Vec<OverlayLinkState>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct NodeOverlayState {
    pub ipv6: String,
}

#[derive(Deserialize, Debug, Clone)]
struct OverlayLinkState {
    #[serde(rename = "aHost")]
    pub a_host: String,
    #[serde(rename = "bHost")]
    pub b_host: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SecretState {
    pub file: PathBuf,
    pub tags: Vec<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct NodeSecretState {
    pub file: PathBuf,
    pub path: PathBuf,
}

#[derive(Deserialize, Debug, Clone)]
pub struct AgeKeyPair {
    pub identity: String,
    pub recipient: String,
}

#[derive(Debug)]
pub enum ModuleSource {
    ModuleFile(PathBuf),
    FlakeAttr(String),
}

pub struct StateLoader {
    pub module_source: ModuleSource,
    pub workspace: Workspace,
    pub alloy_url: String,
    pub nixpkgs_url: String,
}

impl StateLoader {
    pub fn load(&self) -> Result<State> {
        let module_source_expr = match &self.module_source {
            ModuleSource::ModuleFile(module_path) => format!(
                "import {}",
                module_path
                    .to_str()
                    .ok_or_eyre("module path is not valid utf8 string")?
            ),
            ModuleSource::FlakeAttr(flake_attr)
                if let Some(flake_url) = self.workspace.flake_url() =>
            {
                exec_sh_script(&format!("nix eval {}#{}", flake_url, flake_attr))?;
                format!(r#"(builtins.getFlake "{}").{}"#, flake_url, flake_attr)
            }
            ModuleSource::FlakeAttr(_) => {
                eyre::bail!(
                    "workspace root '{}' must be a flake root",
                    self.workspace.root()
                )
            }
        };

        let nix_expr = format!(
            r#"
            let
                pkgs = (builtins.getFlake "{}").legacyPackages.${{builtins.currentSystem}};
                alloyLib = (builtins.getFlake "{}").lib;
                alloyModule = {};
                res = alloyLib.evalModules {{
                    modules = [alloyModule];
                    checkAssertions = false;
                }};
            in
                res.config._internal.state {{ inherit pkgs; }}
            "#,
            &self.nixpkgs_url, &self.alloy_url, module_source_expr
        );

        let mut tempfile = NamedTempFile::new()?;
        exec_sh_script(&format!(
            "nix eval --impure --json --expr '{}' > {}",
            nix_expr,
            tempfile.path().to_str().unwrap(),
        ))?;

        let mut raw_state = String::new();
        tempfile.read_to_string(&mut raw_state)?;

        let state = serde_json::from_str(&raw_state)?;
        Ok(state)
    }

    pub fn load_generator_script(&self, generator_name: &str) -> Result<PathBuf> {
        let module_source_expr = match &self.module_source {
            ModuleSource::ModuleFile(module_path) => format!(
                "import {}",
                module_path
                    .to_str()
                    .ok_or_eyre("module path is not valid utf8 string")?
            ),
            ModuleSource::FlakeAttr(flake_attr)
                if let Some(flake_url) = self.workspace.flake_url() =>
            {
                exec_sh_script(&format!("nix eval {}#{}", flake_url, flake_attr))?;
                format!(r#"(builtins.getFlake "{}").{}"#, flake_url, flake_attr)
            }
            ModuleSource::FlakeAttr(_) => {
                eyre::bail!(
                    "workspace root '{}' must be a flake root",
                    self.workspace.root()
                )
            }
        };

        let nix_expr = format!(
            r#"
            let
                pkgs = (builtins.getFlake "{}").legacyPackages.${{builtins.currentSystem}};
                alloyLib = (builtins.getFlake "{}").lib;
                alloyModule = {};
                res = alloyLib.evalModules {{
                    modules = [alloyModule];
                    checkAssertions = false;
                }};
                package = res.config.generators.{generator_name}.package {{ inherit pkgs; }};
            in
                lib.getExe package
            "#,
            &self.nixpkgs_url, &self.alloy_url, module_source_expr
        );

        let mut tempfile = NamedTempFile::new()?;
        exec_sh_script(&format!(
            "nix eval --impure --json --expr '{}' > {}",
            nix_expr,
            tempfile.path().to_str().unwrap(),
        ))?;

        let mut raw_path = String::new();
        tempfile.read_to_string(&mut raw_path)?;

        let path = PathBuf::try_from(raw_path)?;
        Ok(path)
    }
}
