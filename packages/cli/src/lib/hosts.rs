use miette::Diagnostic;
use thiserror::Error;
use crate::lib::state::{State, HostState};

#[derive(Error, Diagnostic, Debug)]
#[error("Host not found")]
#[diagnostic(code(alloy::hosts::not_found))]
pub struct NotFoundError;

pub fn find<'a>(state: &'a State, name: &str) -> Result<&'a HostState, NotFoundError> {
    state.hosts.get(name).ok_or(NotFoundError)
}
