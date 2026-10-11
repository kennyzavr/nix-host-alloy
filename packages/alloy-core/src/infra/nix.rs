use std::path::PathBuf;
use std::str::FromStr;

use crate::domain::env::EnvModuleSource;
use crate::domain::ports::{Nix, NixBuildSpec, NixCtx};

use super::System;

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

impl Nix for System {
    fn trigger_assertions(
        &self,
        spec: &NixBuildSpec,
        ctx: NixCtx<'_>,
    ) -> Result<(), crate::domain::DynError> {
        self.trigger_assertions(spec, ctx)?;
        Ok(())
    }

    fn build(
        &self,
        spec: &NixBuildSpec,
        ctx: NixCtx<'_>,
    ) -> Result<PathBuf, crate::domain::DynError> {
        let path = self.build(spec, ctx)?;
        Ok(path)
    }
}

impl System {
    pub fn trigger_assertions(&self, spec: &NixBuildSpec, ctx: NixCtx<'_>) -> Result<(), NixError> {
        let nix_expr = self.build_nix_expr(spec, "res.config.name", true, ctx)?;

        let mut cmd = std::process::Command::new("nix");

        cmd.args(["eval", "--impure", "--raw", "--expr", &nix_expr]);
        if ctx.show_nix_trace {
            cmd.arg("--show-trace");
        }

        let output = cmd
            .stderr(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::piped())
            .output()
            .map_err(NixError::Execution)?;

        if !output.status.success() {
            return Err(NixError::Nix(output.status));
        }

        Ok(())
    }

    fn build(&self, spec: &NixBuildSpec, ctx: NixCtx<'_>) -> Result<PathBuf, NixError> {
        let expr = format!("res.config.build.package {{ inherit pkgs; }}",);

        log::debug!("Evaluating state spec={:?}: {}", spec, expr);
        let expr = self.build_nix_expr(spec, &expr, false, ctx)?;

        let output = std::process::Command::new("nix")
            .args([
                "build",
                "--impure",
                if ctx.show_nix_trace {
                    "--show-trace"
                } else {
                    ""
                },
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

    fn build_nix_expr(
        &self,
        spec: &NixBuildSpec,
        inner_expr: &str,
        check_assertions: bool,
        ctx: NixCtx<'_>,
    ) -> Result<String, NixError> {
        let module_source_expr = match ctx.module_source {
            EnvModuleSource::File(path) => {
                format!("import {}", path.to_str().unwrap())
            }
            EnvModuleSource::FlakeAttr(attr) => {
                format!(r#"(builtins.getFlake "{}").{}"#, ctx.flake_url, attr)
            }
        };

        Ok(format!(
            r#"
            let
                pkgs = (builtins.getFlake "{}").legacyPackages.${{builtins.currentSystem}};
                alloyLib = (builtins.getFlake "{}").lib;
                alloyModule = {};
                res = alloyLib.evalModules {{
                    modules = [
                        alloyModule
                        {{
                            build.spec = builtins.fromJSON ''{}'';
                        }}
                    ];
                    checkAssertions = {};
                }};
            in
                {}
            "#,
            ctx.nixpkgs_url,
            ctx.alloy_url,
            module_source_expr,
            serde_json::to_string(spec).unwrap(),
            if check_assertions { "true" } else { "false" },
            inner_expr
        ))
    }
}
