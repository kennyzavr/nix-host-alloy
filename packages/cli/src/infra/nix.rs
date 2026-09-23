use std::path::PathBuf;
use std::sync::Arc;

use crate::domain::models::State;
use crate::domain::ports::{NixError, NixEvaluator};
use crate::infra::workspace::Workspace;

pub struct NixAdapter {
    pub module_source: ModuleSource,
    pub workspace: Arc<Workspace>,
    pub alloy_url: String,
    pub nixpkgs_url: String,
    pub state_file_slot: Arc<std::sync::Mutex<Option<PathBuf>>>,
}

#[derive(Debug)]
pub enum ModuleSource {
    ModuleFile(PathBuf),
    FlakeAttr(String),
}

impl NixAdapter {
    fn build_nix_expr(&self, inner_expr: &str) -> Result<String, NixError> {
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
                    .map_err(|e| NixError::EvalFlakeAttr(Box::new(e)))?;

                if !status.success() {
                    return Err(NixError::EvalFlakeAttr(Box::new(std::io::Error::new(
                        std::io::ErrorKind::Other,
                        format!("Exit status: {}", status),
                    ))));
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
                    checkAssertions = false;
                }};
            in
                {}
            "#,
            &self.nixpkgs_url, &self.alloy_url, module_source_expr, inner_expr
        ))
    }

    fn eval_nix(&self, inner_expr: &str, is_raw: bool) -> Result<String, NixError> {
        let nix_expr = self.build_nix_expr(inner_expr)?;

        let format_flag = if is_raw { "--raw" } else { "--json" };

        let output = std::process::Command::new("nix")
            .args(["eval", "--impure", format_flag, "--expr", &nix_expr])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(|e| NixError::Execution(Box::new(e)))?;

        if !output.status.success() {
            return Err(NixError::Execution(Box::new(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("Exit status: {}", output.status),
            ))));
        }

        let result_str =
            String::from_utf8(output.stdout).map_err(|e| NixError::Execution(Box::new(e)))?;
        Ok(result_str)
    }

    fn build_nix(&self, inner_expr: &str) -> Result<(), NixError> {
        let nix_expr = self.build_nix_expr(inner_expr)?;

        let output = std::process::Command::new("nix")
            .args(["build", "--impure", "--no-link", "--expr", &nix_expr])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(|e| NixError::Execution(Box::new(e)))?;

        if !output.status.success() {
            return Err(NixError::Execution(Box::new(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("Exit status: {}", output.status),
            ))));
        }

        Ok(())
    }
    fn build_and_get_path_nix(&self, inner_expr: &str) -> Result<String, NixError> {
        let nix_expr = self.build_nix_expr(inner_expr)?;

        let output = std::process::Command::new("nix")
            .args(["build", "--impure", "--no-link", "--print-out-paths", "--expr", &nix_expr])
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(|e| NixError::Execution(Box::new(e)))?;

        if !output.status.success() {
            return Err(NixError::Execution(Box::new(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("Exit status: {}", output.status),
            ))));
        }

        let result_str =
            String::from_utf8(output.stdout).map_err(|e| NixError::Execution(Box::new(e)))?;
        Ok(result_str.trim().to_string())
    }
}

impl NixEvaluator for NixAdapter {
    fn load_state(&self) -> Result<State, NixError> {
        let mut slot = self.state_file_slot.lock().unwrap();

        let state_path = if let Some(path) = &*slot {
            path.clone()
        } else {
            let inner_expr = "res.config._internal.statePackage { inherit pkgs; }";
            let state_pkg_path = self.build_and_get_path_nix(inner_expr)?;
            let state_json_path = std::path::PathBuf::from(state_pkg_path).join("state.json");
            
            *slot = Some(state_json_path.clone());
            
            state_json_path
        };

        let raw_state = std::fs::read_to_string(&state_path).map_err(|e| NixError::Execution(Box::new(e)))?;
        let state =
            serde_json::from_str(&raw_state).map_err(|e| NixError::ParseState(Box::new(e)))?;
        Ok(state)
    }

    fn get_generator_bin_path(&self, name: &str) -> Result<std::path::PathBuf, NixError> {
        let slot = self.state_file_slot.lock().unwrap();
        if let Some(state_json_path) = &*slot {
            Ok(state_json_path.parent().unwrap().join("bin").join(name))
        } else {
            Err(NixError::Execution(Box::new(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "State file slot is empty, cannot resolve generator binary path",
            ))))
        }
    }

    fn eval_generator_raw(&self, name: &str) -> Result<(), NixError> {
        let eval_expr = format!(
            "res.config.generators.instances.\"{}\".package {{ inherit pkgs; }}",
            name
        );
        self.eval_nix(&eval_expr, true)?;
        Ok(())
    }

    fn eval_index_raw(&self, name: &str) -> Result<(), NixError> {
        let eval_expr = format!(
            "res.config.indexes.\"{}\".values",
            name
        );
        self.eval_nix(&eval_expr, true)?;
        Ok(())
    }
}
