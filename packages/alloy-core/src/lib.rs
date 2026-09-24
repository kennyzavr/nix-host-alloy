use std::{fmt, path::Path};

pub mod ctx;
pub mod facts;
pub mod gens;
pub mod hosts;
pub mod indexes;
pub mod jails;
pub mod models;
pub mod ports;
pub mod secrets;

pub struct NameMark<'s>(pub &'s str);

impl<'s> NameMark<'s> {
    pub const START: char = '`';
    pub const END: char = '`';
}

impl fmt::Display for NameMark<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "`{}`", self.0)
    }
}

pub struct PathMark<'s>(pub &'s Path);

impl<'s> PathMark<'s> {
    pub const START: char = '\'';
    pub const END: char = '\'';
}

impl fmt::Display for PathMark<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "'{}'", self.0.display())
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Not defined")]
pub struct NotDefinedError;

pub type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;
