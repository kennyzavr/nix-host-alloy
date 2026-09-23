use crate::domain::ports::{Crypto, CryptoError};
use std::io::Write;
use std::process::{Command, Stdio};

pub struct Rage;

impl Crypto for Rage {
    fn encrypt(&self, recipients: &[String], data: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let mut cmd = Command::new("rage");
        cmd.arg("-e");
        for r in recipients {
            cmd.args(["-R", r]);
        }

        let mut child = cmd
            .stdin(Stdio::piped())
            .stderr(Stdio::inherit())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| CryptoError::System(Box::new(e)))?;

        let mut stdin = child.stdin.take().unwrap();
        stdin
            .write_all(data)
            .map_err(|e| CryptoError::System(Box::new(e)))?;
        drop(stdin);

        let output = child
            .wait_with_output()
            .map_err(|e| CryptoError::System(Box::new(e)))?;
        if !output.status.success() {
            return Err(CryptoError::OperationFailed);
        }

        Ok(output.stdout)
    }

    fn decrypt(&self, identities: &[String], data: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let mut cmd = Command::new("rage");
        cmd.arg("-d");
        for i in identities {
            cmd.args(["-i", i]);
        }

        let mut child = cmd
            .stdin(Stdio::piped())
            .stderr(Stdio::inherit())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| CryptoError::System(Box::new(e)))?;

        let mut stdin = child.stdin.take().unwrap();
        stdin
            .write_all(data)
            .map_err(|e| CryptoError::System(Box::new(e)))?;
        drop(stdin);

        let output = child
            .wait_with_output()
            .map_err(|e| CryptoError::System(Box::new(e)))?;
        if !output.status.success() {
            return Err(CryptoError::OperationFailed);
        }

        Ok(output.stdout)
    }
}
