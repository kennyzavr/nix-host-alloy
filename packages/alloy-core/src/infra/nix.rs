use std::path::PathBuf;
use std::str::FromStr;

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
    fn eval_index_keys(
        &self,
        index_name: &str,
        ctx: NixCtx<'_>,
    ) -> Result<(), crate::domain::DynError> {
        self.eval_index_keys(index_name, ctx)?;
        Ok(())
    }

    fn build_gen_package(
        &self,
        gen_name: &str,
        ctx: NixCtx<'_>,
    ) -> Result<(), crate::domain::DynError> {
        self.build_gen_package(gen_name, ctx)?;
        Ok(())
    }

    fn build(
        &self,
        spec: &NixBuildSpec,
        check_assertions: bool,
        ctx: NixCtx<'_>,
    ) -> Result<PathBuf, crate::domain::DynError> {
        let path = self.build(spec, check_assertions, ctx)?;
        Ok(path)
    }
}

impl System {
    pub fn eval_index_keys(&self, index_name: &str, ctx: NixCtx<'_>) -> Result<(), NixError> {
        let expr = format!(r#"res.config.indexes."{}".keys"#, index_name);
        let expr = self.build_nix_expr(None, &expr, false, ctx)?;

        let mut cmd = std::process::Command::new("nix");

        cmd.args(["eval", "--impure", "--raw", "--expr", &expr]);
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

    fn build_gen_package(&self, gen_name: &str, ctx: NixCtx<'_>) -> Result<(), NixError> {
        let expr = format!(
            r#"res.config.generators.instances."{}".package {{ inherit system; }}"#,
            gen_name
        );
        let expr = self.build_nix_expr(None, &expr, false, ctx)?;

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
            log::error!(
                "nix build generator {} package failed: {}",
                gen_name,
                output.status
            );
            return Err(NixError::Nix(output.status));
        }

        Ok(())
    }

    fn build(
        &self,
        spec: &NixBuildSpec,
        check_assertions: bool,
        ctx: NixCtx<'_>,
    ) -> Result<PathBuf, NixError> {
        let expr = format!("res.config.build.package {{ inherit system; }}",);

        log::debug!("Evaluating state spec={:?}: {}", spec, expr);
        let expr = self.build_nix_expr(Some(spec), &expr, check_assertions, ctx)?;

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
        spec: Option<&NixBuildSpec>,
        inner_expr: &str,
        check_assertions: bool,
        ctx: NixCtx<'_>,
    ) -> Result<String, NixError> {
        Ok(format!(
            r#"
            let
                system = builtins.currentSystem;
                flake = builtins.getFlake "{}";
                alloyLib = flake{}.lib;
                alloyModule = flake.{};
                res = alloyLib.evalModules {{
                    modules = [
                        alloyModule
                        {}
                    ];
                    checkAssertions = {};
                }};
            in
                {}
            "#,
            ctx.flake_url,
            if ctx.input_attr.is_empty() {
                "".to_string()
            } else {
                format!(".{}", ctx.input_attr)
            },
            ctx.module_attr,
            if let Some(spec) = spec {
                format!(
                    "{{ build.spec = builtins.fromJSON ''{}''; }}",
                    serde_json::to_string(spec).unwrap()
                )
            } else {
                "".to_string()
            },
            if check_assertions { "true" } else { "false" },
            inner_expr
        ))
    }
}
