use core::fmt;
use std::path::Path;

pub mod env;
pub mod facts;
pub mod gens;
pub mod hosts;
pub mod indexes;
pub mod jails;
pub mod models;
pub mod ports;
pub mod qemu;
pub mod secrets;
pub mod state;

pub struct NameMarker<'s>(pub &'s str);

impl<'s> NameMarker<'s> {
    pub const START: char = '`';
    pub const END: char = '`';
}

impl fmt::Display for NameMarker<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "`{}`", self.0)
    }
}

pub struct PathMarker<'s>(pub &'s Path);

impl<'s> PathMarker<'s> {
    pub const START: char = '\'';
    pub const END: char = '\'';
}

impl fmt::Display for PathMarker<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "'{}'", self.0.display())
    }
}

pub type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;
