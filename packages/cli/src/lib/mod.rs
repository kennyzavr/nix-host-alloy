use std::{fmt, path::Path};

use owo_colors::OwoColorize;

mod file;
mod git;

pub mod facts;
pub mod generators;
pub mod hosts;
pub mod indexes;
pub mod jails;
pub mod secrets;
pub mod state;
pub mod workspace;

pub struct StyledName<'a>(pub &'a str);
pub struct StyledPath<'a>(pub &'a Path);

impl<'a> fmt::Display for StyledName<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.cyan().bold())
    }
}

impl<'a> fmt::Display for StyledPath<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.display().bright_blue().underline())
    }
}
