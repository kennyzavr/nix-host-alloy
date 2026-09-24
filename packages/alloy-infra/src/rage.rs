use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use alloy_core::ports::Age;

pub struct Rage;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("System error during cryptographic operation")]
    System(#[source] std::io::Error),
    #[error("Cryptographic operation failed with {0}")]
    OperationFailed(std::process::ExitStatus),
}

impl Rage {
    fn encrypt<'p>(
        &self,
        recipients: impl IntoIterator<Item = &'p Path>,
        data: &[u8],
    ) -> Result<Vec<u8>, Error> {
        let mut cmd = Command::new("rage");
        cmd.arg("-e");
        for r in recipients {
            cmd.arg("-R");
            cmd.arg(r);
        }

        let mut child = cmd
            .stdin(Stdio::piped())
            .stderr(Stdio::inherit())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(Error::System)?;

        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(data).map_err(Error::System)?;
        drop(stdin);

        let output = child.wait_with_output().map_err(Error::System)?;
        if !output.status.success() {
            return Err(Error::OperationFailed(output.status));
        }

        Ok(output.stdout)
    }

    fn decrypt<'p>(
        &self,
        identities: impl IntoIterator<Item = &'p Path>,
        data: &[u8],
    ) -> Result<Vec<u8>, Error> {
        let mut cmd = Command::new("rage");
        cmd.arg("-d");
        for i in identities {
            cmd.arg("-i");
            cmd.arg(i);
        }

        let mut child = cmd
            .stdin(Stdio::piped())
            .stderr(Stdio::inherit())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(Error::System)?;

        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(data).map_err(Error::System)?;
        drop(stdin);

        let output = child.wait_with_output().map_err(Error::System)?;
        if !output.status.success() {
            return Err(Error::OperationFailed(output.status));
        }

        Ok(output.stdout)
    }
}

impl Age for Rage {
    fn encrypt(
        &self,
        recipients: &mut dyn Iterator<Item = &alloy_core::models::AgeRecipient>,
        data: &[u8],
    ) -> Result<Vec<u8>, alloy_core::DynError> {
        let data = self.encrypt(recipients.map(|r| r.0.as_path()), data)?;
        Ok(data)
    }

    fn decrypt(
        &self,
        identities: &mut dyn Iterator<Item = &alloy_core::models::AgeIdentity>,
        data: &[u8],
    ) -> Result<Vec<u8>, alloy_core::DynError> {
        let data = self.decrypt(identities.map(|i| i.0.as_path()), data)?;
        Ok(data)
    }
}
