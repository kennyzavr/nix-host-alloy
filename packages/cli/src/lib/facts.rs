

use crate::lib::workspace;

use super::{
    file,
    state::{FactState, State},
};

use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
pub enum ReadError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    NotFound(#[from] NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    File(#[from] file::ReadError),
    #[error("Not valid utf8 string")]
    #[diagnostic()]
    Utf8(#[from] std::string::FromUtf8Error),
}

#[derive(Error, Diagnostic, Debug)]
pub enum WriteError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    NotFound(#[from] NotFoundError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    File(#[from] file::WriteError),
}

#[derive(Error, Diagnostic, Debug)]
#[error("Fact not found")]
#[diagnostic(
    code(alloy::facts::not_found),
    help("Define the fact in your nix configuration")
)]
pub struct NotFoundError;

pub fn read(
    workspace: &workspace::Workspace,
    state: &State,
    name: &str,
) -> Result<String, ReadError> {
    let Some((_, fact)) = state
        .facts
        .iter()
        .find(|(fact_name, _)| name == **fact_name)
    else {
        return Err(NotFoundError.into());
    };

    let data = file::read(&workspace.root().join(&fact.file))?;
    let data = String::from_utf8(data)?;

    Ok(data)
}

pub fn write<'s>(
    workspace: &workspace::Workspace,
    state: &'s State,
    name: &str,
    value: String,
    force: bool,
    add_to_git: bool,
) -> Result<&'s FactState, WriteError> {
    let Some((_, fact)) = state
        .facts
        .iter()
        .find(|(fact_name, _)| name == **fact_name)
    else {
        return Err(NotFoundError.into());
    };

    file::write(
        &workspace.root().join(&fact.file),
        &value.into_bytes(),
        force,
        add_to_git,
    )?;

    Ok(fact)
}
