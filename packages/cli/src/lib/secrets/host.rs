use super::age;
use super::master;
use crate::lib::file;
use crate::lib::{StyledName, workspace};
use crate::lib::{hosts, state::State};
use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
#[error("Secret not found for host {}", StyledName(&host_name))]
#[diagnostic(code(alloy::secrets::host::not_found))]
pub struct NotFoundError {
    pub host_name: String,
}

#[derive(Error, Diagnostic, Debug)]
#[error("Age key pairs not defined for host {}", StyledName(&host_name))]
#[diagnostic(code(alloy::secrets::host::age_key_pairs_not_defined))]
pub struct NoKeysError {
    pub host_name: String,
}

#[derive(Error, Diagnostic, Debug)]
pub enum RekeyError {
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
    NoKeys(#[from] NoKeysError),
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
    host_name: &str,
    secret_name: &str,
    force: bool,
    add_to_git: bool,
) -> Result<(), RekeyError> {
    let host = hosts::find(state, host_name)?;
    let host_secret = host.secrets.get(secret_name).ok_or(NotFoundError {
        host_name: host_name.to_string(),
    })?;

    let master_secret_value = master::read(workspace, state, secret_name)?;

    let recipients: Vec<String> = host
        .secrets_age_key_pairs
        .iter()
        .map(|k| k.recipient.clone())
        .collect();
    if recipients.is_empty() {
        return Err(NoKeysError {
            host_name: host_name.to_string(),
        }
        .into());
    }

    let data = age::encrypt(&recipients, &master_secret_value)?;
    file::write(
        &workspace.root().join(&host_secret.path),
        &data,
        force,
        add_to_git,
    )?;

    Ok(())
}
