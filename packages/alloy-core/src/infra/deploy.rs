use std::{
    fs::File,
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use nix::{
    sys::{
        memfd::{MFdFlags, memfd_create},
        signal::{Signal, kill},
    },
    unistd::Pid,
};
use tempfile::TempDir;

use super::{ExecError, NixError, System};
use crate::domain::{
    DynError,
    models::{DeployActivation, DeployActivationMethod, DeployActivationPolicy, DeployConnection},
    ports::{DeployBuild, DeployRunner, NixCtx},
};

#[derive(Debug, thiserror::Error)]
pub enum DeployRunnerError {
    #[error("Deployment I/O operation failed")]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Exec(#[from] ExecError),

    #[error("Failed to construct Nix build expression")]
    Nix(#[from] NixError),

    #[error("Failed to create signing key memory file")]
    Memfd(#[from] nix::errno::Errno),

    #[error("Nix returned a public key with invalid UTF-8")]
    PublicKeyUtf8(#[from] std::str::Utf8Error),

    #[error("Deployment cancelled")]
    Cancelled,

    #[error("SSH options contain unmatched quotes or an invalid escape")]
    ParseSshOptions,

    #[error("SSH identity path {} is not valid UTF-8", path.display())]
    IdentityPath { path: PathBuf },

    #[error("Nix did not return a system toplevel in /nix/store: {}", path.display())]
    InvalidStorePath { path: PathBuf },

    #[error("Invalid Nix signing secret: public key conversion failed with {0}")]
    InvalidSigningSecret(std::process::ExitStatus),

    #[error("Decrypted signing secret does not match its public key fact")]
    SigningKeyMismatch,

    #[error("Use an SSH alias or IP address instead of Nix's special `localhost` authority")]
    Localhost,
}

struct Build {
    toplevel: PathBuf,
    _root: TempDir,
}

impl DeployBuild for Build {
    fn toplevel(&self) -> &Path {
        &self.toplevel
    }
}

// Reap children even if a wait or later operation fails.
struct RunningChild(Child);
impl Drop for RunningChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn check_cancelled(cancelled: &AtomicBool) -> Result<(), DeployRunnerError> {
    if cancelled.load(Ordering::SeqCst) {
        Err(DeployRunnerError::Cancelled)
    } else {
        Ok(())
    }
}

fn run(cmd: &mut Command, cancelled: &AtomicBool) -> Result<(), DeployRunnerError> {
    check_cancelled(cancelled)?;
    let mut child = RunningChild(cmd.spawn().map_err(ExecError::Exec)?);
    loop {
        if let Some(status) = child.0.try_wait()? {
            check_cancelled(cancelled)?;
            return if status.success() {
                Ok(())
            } else {
                Err(ExecError::Status(status).into())
            };
        }
        if check_cancelled(cancelled).is_err() {
            // Keep children in the foreground process group for SSH/PIN/sudo prompts.
            // They normally receive terminal SIGINT too; allow Nix to clean up first.
            let _ = kill(Pid::from_raw(child.0.id() as i32), Signal::SIGINT);
            let deadline = Instant::now() + Duration::from_secs(3);
            while child.0.try_wait()?.is_none() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            check_cancelled(cancelled)?;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn ssh_args(
    connection: &DeployConnection,
    identity_file: Option<&Path>,
    ssh_options: &str,
) -> Result<Vec<String>, DeployRunnerError> {
    let extra_args = shlex::split(ssh_options).ok_or(DeployRunnerError::ParseSshOptions)?;
    // OpenSSH uses the first user/port value, including -oUser/-oPort.
    let mut args = Vec::new();
    if let Some(user) = &connection.user {
        args.extend(["-l".into(), user.clone()]);
    }
    if let Some(port) = connection.port {
        args.extend(["-p".into(), port.to_string()]);
    }
    if let Some(identity) = identity_file {
        let identity_str = identity
            .to_str()
            .ok_or_else(|| DeployRunnerError::IdentityPath {
                path: identity.to_owned(),
            })?;
        args.extend(["-i".into(), identity_str.into()]);
    }
    args.extend(extra_args);
    Ok(args)
}

fn ssh_address(address: &str) -> &str {
    address
        .strip_prefix('[')
        .and_then(|address| address.strip_suffix(']'))
        .unwrap_or(address)
}

fn remote(
    connection: &DeployConnection,
    identity_file: Option<&Path>,
    ssh_options: &str,
    activation: &DeployActivation,
    command: &str,
    cancelled: &AtomicBool,
) -> Result<(), DeployRunnerError> {
    let command = match activation.method {
        DeployActivationMethod::Direct => format!("sh -c {}", shell_quote(command)),
        // A single privileged shell keeps profile/activation command semantics explicit.
        DeployActivationMethod::Sudo => format!(
            "sudo {} -- sh -c {}",
            if activation.ask_password { "" } else { "-n" },
            shell_quote(command)
        ),
    };
    let mut cmd = Command::new("ssh");
    cmd.args(ssh_args(connection, identity_file, ssh_options)?);
    // Only password-based sudo needs a remote tty. Nix copy always uses a stream.
    cmd.arg(if activation.ask_password { "-t" } else { "-T" });
    cmd.arg("--")
        .arg(ssh_address(&connection.address))
        .arg(command);
    run(&mut cmd, cancelled)
}

impl DeployRunner for System {
    fn build_host(
        &self,
        host: &str,
        ctx: NixCtx<'_>,
        cancelled: &AtomicBool,
    ) -> Result<Box<dyn DeployBuild>, DynError> {
        let build = self.build_host(host, ctx, cancelled)?;
        Ok(Box::new(build))
    }

    fn sign(
        &self,
        toplevel: &Path,
        private_key: &[u8],
        public_key: &str,
        cancelled: &AtomicBool,
    ) -> Result<(), DynError> {
        self.sign(toplevel, private_key, public_key, cancelled)?;
        Ok(())
    }

    fn copy(
        &self,
        toplevel: &Path,
        connection: &DeployConnection,
        identity_file: Option<&Path>,
        ssh_options: &str,
        cancelled: &AtomicBool,
    ) -> Result<(), DynError> {
        self.copy(toplevel, connection, identity_file, ssh_options, cancelled)?;
        Ok(())
    }

    fn activate(
        &self,
        toplevel: &Path,
        connection: &DeployConnection,
        identity_file: Option<&Path>,
        ssh_options: &str,
        activation: &DeployActivation,
        cancelled: &AtomicBool,
    ) -> Result<(), DynError> {
        self.activate(
            toplevel,
            connection,
            identity_file,
            ssh_options,
            activation,
            cancelled,
        )?;
        Ok(())
    }
}

impl System {
    fn build_host(
        &self,
        host: &str,
        ctx: NixCtx<'_>,
        cancelled: &AtomicBool,
    ) -> Result<Build, DeployRunnerError> {
        let root = tempfile::Builder::new().prefix("alloy-deploy-").tempdir()?;
        let link = root.path().join("system");
        let expr = self.build_nix_expr(
            None,
            &format!(r#"res.config.hosts."{host}".deploy.targetToplevel"#),
            true,
            ctx,
        )?;
        let mut cmd = Command::new("nix");
        cmd.args(["build", "--impure", "--out-link"])
            .arg(&link)
            .args(["--expr", &expr]);
        if ctx.show_nix_trace {
            cmd.arg("--show-trace");
        }
        run(&mut cmd, cancelled)?;
        let toplevel = std::fs::canonicalize(&link)?;
        // Only a store toplevel may be interpolated into remote activation commands.
        if toplevel.parent() != Some(Path::new("/nix/store")) {
            return Err(DeployRunnerError::InvalidStorePath { path: toplevel });
        }
        Ok(Build {
            toplevel,
            _root: root,
        })
    }

    fn sign(
        &self,
        toplevel: &Path,
        private_key: &[u8],
        public_key: &str,
        cancelled: &AtomicBool,
    ) -> Result<(), DeployRunnerError> {
        check_cancelled(cancelled)?;
        // No named plaintext file and no key in argv/env. Stdio duplicates this fd
        // to stdin, so /proc/self/fd/0 remains available across exec with CLOEXEC.
        let mut key = File::from(memfd_create(c"alloy-signing-key", MFdFlags::MFD_CLOEXEC)?);
        key.write_all(private_key)?;
        key.seek(SeekFrom::Start(0))?;
        let output = Command::new("nix")
            .args(["key", "convert-secret-to-public"])
            .stdin(Stdio::from(key.try_clone()?))
            .stdout(Stdio::piped())
            // Nix parse errors must never echo malformed private key material.
            .stderr(Stdio::null())
            .output()?;
        check_cancelled(cancelled)?;
        if !output.status.success() {
            return Err(DeployRunnerError::InvalidSigningSecret(output.status));
        }
        if std::str::from_utf8(&output.stdout)?.trim() != public_key {
            return Err(DeployRunnerError::SigningKeyMismatch);
        }
        key.seek(SeekFrom::Start(0))?;
        let mut cmd = Command::new("nix");
        cmd.args([
            "store",
            "sign",
            "--recursive",
            "--key-file",
            "/proc/self/fd/0",
        ])
        .arg(toplevel)
        .stdin(Stdio::from(key));
        run(&mut cmd, cancelled)
    }

    fn copy(
        &self,
        toplevel: &Path,
        connection: &DeployConnection,
        identity_file: Option<&Path>,
        ssh_options: &str,
        cancelled: &AtomicBool,
    ) -> Result<(), DeployRunnerError> {
        // Nix treats the literal authority `localhost` as a local store, bypassing SSH.
        let address = ssh_address(&connection.address);
        if address == "localhost" {
            return Err(DeployRunnerError::Localhost);
        }
        // Nix 2.34 shell-splits NIX_SSHOPTS without shell evaluation. Quoting each
        // argument preserves spaces in identity paths and ProxyCommand values.
        let options = ssh_args(connection, identity_file, ssh_options)?
            .iter()
            .map(|arg| shell_quote(arg))
            .collect::<Vec<_>>()
            .join(" ");
        let mut cmd = Command::new("nix");
        let authority = if address.contains(':') {
            format!("[{address}]")
        } else {
            address.to_owned()
        };
        cmd.args(["copy", "--to", &format!("ssh-ng://{authority}")])
            .arg(toplevel)
            .env("NIX_SSHOPTS", options);
        run(&mut cmd, cancelled)
    }

    fn activate(
        &self,
        toplevel: &Path,
        connection: &DeployConnection,
        identity_file: Option<&Path>,
        ssh_options: &str,
        activation: &DeployActivation,
        cancelled: &AtomicBool,
    ) -> Result<(), DeployRunnerError> {
        let target = shell_quote(&toplevel.to_string_lossy());
        let switch = shell_quote(
            &toplevel
                .join("bin/switch-to-configuration")
                .to_string_lossy(),
        );
        let switch_command = match &activation.policy {
            DeployActivationPolicy::Strict => format!(
                "{switch} switch || {{ echo 'Alloy: activation failed; system profile was updated; no automatic rollback' >&2; exit 1; }}"
            ),
            DeployActivationPolicy::Warn => format!(
                "{switch} switch\nswitch_status=$?\nif [ \"$switch_status\" -ne 0 ]; then\n  current_system=$(readlink -f /run/current-system 2>/dev/null || true)\n  if [ \"$current_system\" = {target} ]; then\n    echo 'Alloy: warning: switch-to-configuration returned non-zero, but /run/current-system points to the requested toplevel; treating deploy as completed with activation warnings' >&2\n  else\n    echo 'Alloy: activation failed; /run/current-system does not point to the requested toplevel; system profile was updated; no automatic rollback' >&2\n    exit \"$switch_status\"\n  fi\nfi"
            ),
        };
        remote(
            connection,
            identity_file,
            ssh_options,
            activation,
            &format!(
                "nix-env --profile /nix/var/nix/profiles/system --set {target} || {{ echo 'Alloy: system profile update failed' >&2; exit 1; }}; {switch_command}"
            ),
            cancelled,
        )
    }
}
