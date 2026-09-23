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
}

impl NixEvaluator for NixAdapter {
    fn load_state(&self) -> Result<State, NixError> {
        let mut slot = self.state_file_slot.lock().unwrap();

        let raw_state = if let Some(path) = &*slot {
            std::fs::read_to_string(path).map_err(|e| NixError::Execution(Box::new(e)))?
        } else {
            let inner_expr = "res.config._internal.state { inherit pkgs; }";
            let state_json = self.eval_nix(inner_expr, false)?;
            
            let pid_file = std::env::temp_dir().join(format!("alloy-state-{}.json", std::process::id()));
            std::fs::write(&pid_file, &state_json).map_err(|e| NixError::Execution(Box::new(e)))?;
            *slot = Some(pid_file);
            
            state_json
        };

        let state =
            serde_json::from_str(&raw_state).map_err(|e| NixError::ParseState(Box::new(e)))?;
        Ok(state)
    }

    fn build_generator(&self, name: &str) -> Result<std::path::PathBuf, NixError> {
        let build_expr = format!(
            "res.config.generators.instances.\"{}\".package {{ inherit pkgs; }}",
            name
        );
        self.build_nix(&build_expr)?;

        let eval_expr = format!(
            "let package = res.config.generators.instances.\"{}\".package {{ inherit pkgs; }}; in pkgs.lib.getExe package",
            name
        );
        let path_str = self.eval_nix(&eval_expr, true)?;

        Ok(std::path::PathBuf::from(path_str.trim()))
    }
}
