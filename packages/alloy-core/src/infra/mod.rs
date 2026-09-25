mod age;
mod fs;
mod gens;
mod git;
mod nix;
mod qemu;

pub use nix::*;
pub use qemu::*;

pub struct System {}

#[derive(Debug, thiserror::Error)]
pub enum ExecError {
    #[error("Failed to execute process")]
    Exec(#[source] std::io::Error),

    #[error("Command exited with {0}")]
    Status(std::process::ExitStatus),
}
