use std::path::Path;
use std::process::Command;

#[derive(thiserror::Error, miette::Diagnostic, Debug)]
pub enum Error {
    #[error("failed to execute git command")]
    #[diagnostic(code(alloy::git::io))]
    Io(#[from] std::io::Error),

    #[error("git command failed with {0}")]
    #[diagnostic(code(alloy::git::execution))]
    Execution(std::process::ExitStatus),
}

pub fn is_repo<P: AsRef<Path>>(path: P) -> Result<bool, Error> {
    let status = Command::new("git")
        .arg("-C")
        .arg(path.as_ref().parent().unwrap_or(Path::new(".")))
        .args(["rev-parse", "--is-inside-work-tree"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;

    Ok(status.success())
}

pub fn add_file<P: AsRef<Path>>(file_path: P) -> Result<(), Error> {
    let status = Command::new("git")
        .arg("add")
        .arg(file_path.as_ref())
        .status()?;

    if !status.success() {
        return Err(Error::Execution(status));
    }

    Ok(())
}
