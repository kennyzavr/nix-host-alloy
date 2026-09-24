use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

use alloy_core::models;

use crate::workspace::Workspace;

pub struct NixAdapter {
    pub module_source: ModuleSource,
    pub workspace: Arc<Workspace>,
    pub alloy_url: String,
    pub nixpkgs_url: String,
    pub state_path: Arc<std::sync::Mutex<Option<PathBuf>>>,
}

#[derive(Debug)]
pub enum ModuleSource {
    ModuleFile(PathBuf),
    FlakeAttr(String),
}

#[derive(Debug, thiserror::Error)]
pub enum NixError {
    #[error("Not in a valid flake workspace")]
    NotFlakeRoot,
    #[error("Nix command failed with {0}")]
    Nix(std::process::ExitStatus),
    #[error("Failed to execute nix command")]
    Execution(#[source] std::io::Error),
    #[error("Failed to parse state configuration")]
    ParseState(#[source] serde_json::Error),
}

impl NixAdapter {
    fn build_nix_expr(&self, inner_expr: &str, check_assertions: bool) -> Result<String, NixError> {
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
                    .status()
                    .map_err(NixError::Execution)?;

                if !status.success() {
                    return Err(NixError::Nix(status));
                }
                format!(r#"(builtins.getFlake "{}").{}"#, flake_url, flake_attr)
            }
            ModuleSource::FlakeAttr(_) => {
                return Err(NixError::NotFlakeRoot);
            }
        };

        Ok(format!(
            r#"
            let
                pkgs = (builtins.getFlake "{}").legacyPackages.${{builtins.currentSystem}};
                alloyLib = (builtins.getFlake "{}").lib;
                alloyModule = {};
                res = alloyLib.evalModules {{
                    modules = [alloyModule];
                    checkAssertions = {};
                }};
            in
                {}
            "#,
            &self.nixpkgs_url,
            &self.alloy_url,
            module_source_expr,
            if check_assertions { "true" } else { "false" },
            inner_expr
        ))
    }

    fn eval_nix(
        &self,
        inner_expr: &str,
        check_assertions: bool,
        is_raw: bool,
    ) -> Result<String, NixError> {
        let nix_expr = self.build_nix_expr(inner_expr, check_assertions)?;

        let format_flag = if is_raw { "--raw" } else { "--json" };

        let output = std::process::Command::new("nix")
            .args(["eval", "--impure", format_flag, "--expr", &nix_expr])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(NixError::Execution)?;

        if !output.status.success() {
            return Err(NixError::Nix(output.status));
        }

        let result_str = String::from_utf8(output.stdout).unwrap();
        Ok(result_str)
    }

    pub fn eval_state(&self, full: bool) -> Result<PathBuf, NixError> {
        let expr = format!(
            "res.config._internal.statePackage {{ inherit pkgs; mode = \"{}\"; }}",
            if full { "full" } else { "base" }
        );
        log::debug!("Evaluating state (full={}): {}", full, expr);
        let expr = self.build_nix_expr(&expr, full)?;
        
        let output = std::process::Command::new("nix")
            .args([
                "build",
                "--impure",
                "--no-link",
                "--print-out-paths",
                "--expr",
                &expr,
            ])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(NixError::Execution)?;

        if !output.status.success() {
            log::error!("nix build for state failed: {}", output.status);
            return Err(NixError::Nix(output.status));
        }

        let result_str = String::from_utf8(output.stdout).unwrap();
        let path = PathBuf::from_str(result_str.trim()).unwrap();
        log::info!("Evaluated state path: {}", path.display());
        Ok(path)
    }

    pub fn load_state_data(&self, full: bool) -> Result<models::State, NixError> {
        log::debug!("Loading state data (full={})", full);
        let mut path_slot = self.state_path.lock().unwrap();

        let path = if let Some(path) = &*path_slot {
            log::debug!("Using cached state path: {}", path.display());
            path.clone()
        } else {
            let path = self.eval_state(full)?;
            *path_slot = Some(path.clone());

            path
        };

        let state_file = path.join("state.json");
        log::debug!("Reading state data from {}", state_file.display());
        let raw_state =
            std::fs::read_to_string(&state_file).map_err(NixError::Execution)?;
        let state = serde_json::from_str(&raw_state).map_err(NixError::ParseState)?;

        Ok(state)
    }

    pub fn eval_generator_raw(&self, name: &str) -> Result<(), NixError> {
        log::info!("Evaluating generator '{}'", name);
        let eval_expr = format!(
            "res.config.generators.instances.\"{}\".package {{ inherit pkgs; }}",
            name
        );
        self.eval_nix(&eval_expr, false, true)?;
        Ok(())
    }

    pub fn eval_index_raw(&self, name: &str) -> Result<(), NixError> {
        log::info!("Evaluating index '{}'", name);
        let eval_expr = format!(
            "builtins.deepSeq (res.config.indexes.\"{}\".keys, null)",
            name
        );
        self.eval_nix(&eval_expr, false, true)?;
        Ok(())
    }
}
