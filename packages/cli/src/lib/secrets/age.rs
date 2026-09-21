use std::process::Command;

use miette::Diagnostic;
use thiserror::Error;

#[derive(Error, Diagnostic, Debug)]
pub enum Error {
    #[error("age process spawn I/O error")]
    #[diagnostic(code(alloy::secrets::rage::spawn))]
    Io(#[from] std::io::Error),

    #[error("Age execution failed with {0}")]
    #[diagnostic(code(alloy::secrets::rage::decrypt))]
    ExitStatus(std::process::ExitStatus),
}

pub fn encrypt(recipients: &[String], data: &[u8]) -> Result<Vec<u8>, Error> {
    let mut cmd = Command::new("rage");
    cmd.arg("-e");
    for r in recipients {
        cmd.args(["-R", r]);
    }

    use std::io::Write;
    use std::process::Stdio;
    let mut child = cmd
        .stdin(Stdio::piped())
        .stderr(Stdio::inherit())
        .stdout(Stdio::piped())
        .spawn()?;

    child.stdin.take().unwrap().write_all(data)?;

    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(Error::ExitStatus(output.status));
    }

    Ok(output.stdout)
}

pub fn decrypt(identities: &[String], data: &[u8]) -> Result<Vec<u8>, Error> {
    let mut cmd = Command::new("rage");
    cmd.arg("-d");
    for i in identities {
        cmd.args(["-i", i]);
    }

    use std::io::Write;
    use std::process::Stdio;
    let mut child = cmd
        .stdin(Stdio::piped())
        .stderr(Stdio::inherit())
        .stdout(Stdio::piped())
        .spawn()?;

    child.stdin.take().unwrap().write_all(data)?;

    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(Error::ExitStatus(output.status));
    }

    Ok(output.stdout)
}
