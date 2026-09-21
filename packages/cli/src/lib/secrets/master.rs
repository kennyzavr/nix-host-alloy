use super::age;
use crate::lib::workspace;
use crate::lib::{
    file,
    state::{SecretState, State},
};
use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
#[error("Master secret not found")]
#[diagnostic(code(alloy::secrets::master::not_found))]
pub struct NotFoundError;

#[derive(Error, Diagnostic, Debug)]
#[error("Master age key pairs not defined")]
#[diagnostic(code(alloy::secrets::master::age_key_pairs_not_defined))]
pub struct NoKeysError;

#[derive(Error, Diagnostic, Debug)]
pub enum ReadError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    NotFound(#[from] NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    NoKeys(#[from] NoKeysError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    Read(#[from] file::ReadError),
    #[error("Failed to decrypt data")]
    #[diagnostic(transparent)]
    Decrypt(#[from] age::Error),
}

#[derive(Error, Diagnostic, Debug)]
pub enum WriteError {
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

pub fn read(
    workspace: &workspace::Workspace,
    state: &State,
    name: &str,
) -> Result<Vec<u8>, ReadError> {
    let secret = state.secrets.get(name).ok_or(NotFoundError)?;

    let identities: Vec<String> = state
        .secrets_age_key_pairs
        .iter()
        .map(|k| k.identity.clone())
        .collect();
    if identities.is_empty() {
        return Err(NoKeysError.into());
    }

    let data = file::read(&workspace.root().join(&secret.file))?;
    let data = age::decrypt(&identities, &data)?;

    Ok(data)
}

pub fn write<'s>(
    workspace: &workspace::Workspace,
    state: &'s State,
    name: &str,
    data: &[u8],
    force: bool,
    add_to_git: bool,
) -> Result<&'s SecretState, WriteError> {
    let secret = state.secrets.get(name).ok_or(NotFoundError)?;

    let recipients: Vec<String> = state
        .secrets_age_key_pairs
        .iter()
        .map(|k| k.recipient.clone())
        .collect();
    if recipients.is_empty() {
        return Err(NoKeysError.into());
    }

    let data = age::encrypt(&recipients, data)?;
    file::write(
        &workspace.root().join(&secret.file),
        &data,
        force,
        add_to_git,
    )?;

    Ok(secret)
}
