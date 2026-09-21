use miette::Diagnostic;
use thiserror::Error;
use crate::lib::state::{State, JailState};

#[derive(Error, Diagnostic, Debug)]
#[error("Jail not found")]
#[diagnostic(code(alloy::jails::not_found))]
pub struct NotFoundError;

pub fn find<'a>(state: &'a State, name: &str) -> Result<&'a JailState, NotFoundError> {
    state.jails.get(name).ok_or(NotFoundError)
}
