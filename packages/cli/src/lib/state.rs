use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

use serde::Deserialize;

use crate::lib::StyledPath;

use super::workspace::Workspace;

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
pub struct OverlayLinkState {
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

pub struct Loader {
    pub module_source: ModuleSource,
    pub workspace: Workspace,
    pub alloy_url: String,
    pub nixpkgs_url: String,
}

#[derive(thiserror::Error, miette::Diagnostic, Debug)]
pub enum EvalError {
    #[error("workspace root {} must be a flake root", StyledPath(&path))]
    #[diagnostic(
        code(state::eval::not_flake_root),
        help("Ensure you are in a valid flake workspace")
    )]
    NotFlakeRoot { path: PathBuf },
    #[error("failed to evaluate flake attribute with {0}")]
    #[diagnostic(code(state::eval::flake_attr))]
    EvalFlakeAttr(std::process::ExitStatus),
    #[error("nix evaluation failed with {0}")]
    #[diagnostic(code(state::eval::execution))]
    Execution(std::process::ExitStatus),
    #[error("I/O error occurred while executing nix")]
    #[diagnostic(code(state::eval::io))]
    Io(#[from] std::io::Error),
}

#[derive(thiserror::Error, miette::Diagnostic, Debug)]
pub enum LoadError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    Eval(#[from] EvalError),
    #[error("failed to deserialize state json")]
    #[diagnostic(code(state::deserialize))]
    Deserialize(#[source] serde_json::Error),
}

#[derive(thiserror::Error, miette::Diagnostic, Debug)]
pub enum LoadGenScriptError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    Eval(#[from] EvalError),
}

impl Loader {
    fn eval_nix(&self, inner_expr: &str, is_raw: bool) -> Result<String, EvalError> {
        let module_source_expr = match &self.module_source {
            ModuleSource::ModuleFile(module_path) => {
                format!("import {}", module_path.to_str().unwrap())
            }
            ModuleSource::FlakeAttr(flake_attr)
                if let Some(flake_url) = self.workspace.flake_url() =>
            {
                let status = std::process::Command::new("nix")
                    .args(["eval", &format!("{}#{}", flake_url, flake_attr)])
                    .stderr(std::process::Stdio::inherit())
                    .stdout(std::process::Stdio::null())
                    .status()?;

                if !status.success() {
                    return Err(EvalError::EvalFlakeAttr(status));
                }
                format!(r#"(builtins.getFlake "{}").{}"#, flake_url, flake_attr)
            }
            ModuleSource::FlakeAttr(_) => {
                return Err(EvalError::NotFlakeRoot {
                    path: self.workspace.root(),
                });
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
                {}
            "#,
            &self.nixpkgs_url, &self.alloy_url, module_source_expr, inner_expr
        );

        let format_flag = if is_raw { "--raw" } else { "--json" };

        let output = std::process::Command::new("nix")
            .args(["eval", "--impure", format_flag, "--expr", &nix_expr])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()?;

        if !output.status.success() {
            return Err(EvalError::Execution(output.status));
        }

        let result_str = String::from_utf8(output.stdout).unwrap();
        Ok(result_str)
    }

    pub fn load(&self) -> Result<State, LoadError> {
        let inner_expr = "res.config._internal.state { inherit pkgs; }";
        let raw_state = self.eval_nix(inner_expr, false)?;
        let state = serde_json::from_str(&raw_state).map_err(LoadError::Deserialize)?;
        Ok(state)
    }

    pub fn load_gen_script(&self, generator_name: &str) -> Result<PathBuf, LoadGenScriptError> {
        let inner_expr = format!(
            "let package = res.config.generators.{}.package {{ inherit pkgs; }}; in pkgs.lib.getExe package",
            generator_name
        );
        let raw_path = self.eval_nix(&inner_expr, true)?;
        Ok(PathBuf::from(raw_path))
    }
}
