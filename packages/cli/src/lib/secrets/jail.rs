use super::age;
use super::host;
use super::master;
use crate::lib::file;
use crate::lib::{StyledName, workspace};
use crate::lib::{hosts, jails, state::State};
use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
#[error("Secret not found for jail {}", StyledName(&jail_name))]
#[diagnostic(code(alloy::secrets::jail::not_found))]
pub struct NotFoundError {
    jail_name: String,
}

#[derive(Error, Diagnostic, Debug)]
pub enum RekeyError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    JailNotFound(#[from] jails::NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    HostNotFound(#[from] hosts::NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    ReadMaster(#[from] master::ReadError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    NotFound(#[from] NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    NoKeys(#[from] host::NoKeysError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    Write(#[from] file::WriteError),
    #[error("Failed to encrypt data")]
    #[diagnostic(transparent)]
    Encrypt(#[from] age::Error),
}

pub fn rekey(
    workspace: &workspace::Workspace,
    state: &State,
    jail_name: &str,
    secret_name: &str,
    force: bool,
    add_to_git: bool,
) -> Result<(), RekeyError> {
    let jail = jails::find(state, jail_name)?;
    let host = hosts::find(state, &jail.host)?;
    let jail_secret = jail.secrets.get(secret_name).ok_or(NotFoundError {
        jail_name: jail_name.to_string(),
    })?;

    let master_secret_value = master::read(workspace, state, secret_name)?;

    let recipients: Vec<String> = host
        .secrets_age_key_pairs
        .iter()
        .map(|k| k.recipient.clone())
        .collect();
    if recipients.is_empty() {
        return Err(host::NoKeysError {
            host_name: jail.host.clone(),
        }
        .into());
    }

    let data = age::encrypt(&recipients, &master_secret_value)?;
    file::write(
        &workspace.root().join(&jail_secret.path),
        &data,
        force,
        add_to_git,
    )?;

    Ok(())
}
