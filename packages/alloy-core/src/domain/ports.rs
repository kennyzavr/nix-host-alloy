use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::domain::{
    DynError,
    env::{Env, EnvModuleSource},
    models::{AgeIdentity, AgeRecipient},
};

pub trait Ctx {
    fn env(&self) -> &Env;

    fn env_mut(&mut self) -> &mut Env;

    fn nix(&self) -> &dyn Nix;

    fn fs(&self) -> &dyn Fs;

    fn git(&self) -> &dyn Git;

    fn age(&self) -> &dyn Age;

    fn gen_runner(&self) -> &dyn GenRunner;

    fn qemu_runner(&self) -> &dyn QemuRunner;
}

#[derive(Debug, Clone, Copy)]
pub struct NixCtx<'a> {
    pub module_source: &'a EnvModuleSource,
    pub nixpkgs_url: &'a str,
    pub alloy_url: &'a str,
    pub flake_url: &'a str,
    pub show_nix_trace: bool,
}

impl<'a> From<&'a Env> for NixCtx<'a> {
    fn from(env: &'a Env) -> Self {
        Self {
            module_source: &env.module_source,
            nixpkgs_url: &env.nixpkgs_url,
            alloy_url: &env.alloy_url,
            flake_url: &env
                .flake_url
                .as_ref()
                .map(String::as_str)
                .unwrap_or(env.workspace_root.to_str().unwrap()),
            show_nix_trace: env.show_nix_trace.unwrap_or(false),
        }
    }
}

#[derive(Default, Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct NixBuildSpec {
    pub generators: NixBuildGensSpec,
    pub qemu: NixBuildQemuSpec,
}

#[derive(Default, Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct NixBuildGensSpec {
    #[serde(rename = "buildScripts")]
    pub build_scripts: bool,
}

#[derive(Default, Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct NixBuildQemuSpec {
    pub build: bool,
    #[serde(rename = "buildScripts")]
    pub build_scripts: Option<Vec<String>>,
}

pub trait Nix {
    fn trigger_assertions(&self, spec: &NixBuildSpec, ctx: NixCtx<'_>) -> Result<(), DynError>;

    fn build(&self, spec: &NixBuildSpec, ctx: NixCtx<'_>) -> Result<PathBuf, DynError>;
}

pub trait Fs {
    fn exists(&self, file: &Path) -> bool;

    fn mk_parent_dirs(&self, path: &Path) -> Result<(), DynError>;

    fn read(&self, path: &Path) -> Result<Vec<u8>, DynError>;

    fn write(&self, path: &Path, data: &[u8], force: bool) -> Result<(), DynError>;
}

pub trait Git {
    fn check(&self, file: &Path) -> Result<(), DynError>;

    fn add(&self, path: &Path) -> Result<(), DynError>;
}

pub trait Age {
    fn encrypt(
        &self,
        recipients: &mut dyn Iterator<Item = &AgeRecipient>,
        data: &[u8],
    ) -> Result<Vec<u8>, DynError>;

    fn decrypt(
        &self,
        identities: &mut dyn Iterator<Item = &AgeIdentity>,
        data: &[u8],
    ) -> Result<Vec<u8>, DynError>;
}

pub trait GenRunner {
    fn exec_gen(
        &self,
        script_path: &Path,
        force: bool,
        add_to_git: bool,
        env: &Env,
    ) -> Result<(), DynError>;
}

pub trait QemuRunner {
    fn launch_guest(
        &self,
        // alloy_name: &str,
        guest_name: &str,
        cache_dir: &Path,
        script_path: &Path,
        vde_switches: &mut dyn Iterator<Item = &dyn VdeSwitchProc>,
    ) -> Result<Box<dyn QemuGuestProc>, DynError>;

    fn create_vde(&self, cache_dir: &Path, idx: u64) -> Result<Box<dyn VdeSwitchProc>, DynError>;
}

pub trait VdeSwitchProc {
    fn index(&self) -> u64;
    fn socket_path(&self) -> &Path;
    fn stop(self: Box<Self>) -> Result<(), DynError>;
}

pub trait QemuGuestProc {
    fn name(&self) -> &str;
    fn wait(self: Box<Self>) -> Result<(), DynError>;
}

pub trait Reporter<C: Ctx, T> {
    fn report(&mut self, ctx: &mut C, event: T);
}

impl<C: Ctx, T, F: FnMut(&mut C, T)> Reporter<C, T> for F {
    fn report(&mut self, ctx: &mut C, event: T) {
        (self)(ctx, event)
    }
}
