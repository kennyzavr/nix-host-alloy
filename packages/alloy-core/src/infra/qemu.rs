use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use chrono::Local;
use tempfile::TempDir;

use crate::domain::ports::QemuRunner;
use crate::domain::{DynError, ports};

use super::{ExecError, System};

pub struct QemuGuestProc {
    name: String,
    child: Child,
}

pub struct VdeSwitchProc {
    idx: u64,
    socket_path: PathBuf,
    child: Child,
    _temp_dir: TempDir,
}

#[derive(Debug, thiserror::Error)]
pub enum WaitError {
    #[error("Failed to wait the process")]
    Wait(#[source] std::io::Error),

    #[error("Proccess exited with {0}")]
    Status(std::process::ExitStatus),
}

#[derive(Debug, thiserror::Error)]
pub enum StopError {
    #[error("Failed to kill the process")]
    Kill(#[source] std::io::Error),

    #[error("Failed to wait the process")]
    Wait(#[source] std::io::Error),

    #[error("Proccess exited with {0}")]
    Status(std::process::ExitStatus),
}

#[derive(thiserror::Error, Debug)]
pub enum LaunchError {
    #[error("Failed to crate log file")]
    LogFile(#[source] std::io::Error),

    #[error(transparent)]
    Exec(#[from] ExecError),

    #[error("Failed to create cache dir")]
    CreateCacheDir {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Failed to create temp dir")]
    CreateTempDir {
        #[source]
        source: std::io::Error,
    },
}

impl System {
    pub fn launch_guest<'v>(
        &self,
        guest_name: &str,
        cache_dir: &Path,
        script_path: &Path,
        vde_switches: impl IntoIterator<Item = &'v dyn ports::VdeSwitchProc>,
    ) -> Result<QemuGuestProc, LaunchError> {
        let cwd = std::env::current_dir().unwrap_or(".".into());
        let cache_dir = cwd.join(cache_dir).join("qemu");
        let script_path = cwd.join(script_path);

        std::fs::create_dir_all(&cache_dir).map_err(|source| LaunchError::CreateCacheDir {
            path: cache_dir.to_path_buf(),
            source,
        })?;

        let mut cmd = Command::new(&script_path);
        cmd.current_dir(&cache_dir);

        let disk_img = cache_dir.join(format!("{}.qcow2", guest_name));
        cmd.env("NIX_DISK_IMAGE", &disk_img);

        for switch in vde_switches {
            cmd.env(
                format!("ALLOY_VDE_SOCKET_{}", switch.index()),
                switch.socket_path(),
            );
        }

        let timestamp = Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
        let log_filename = cache_dir.join(format!("{guest_name}_log_{timestamp}.log"));

        let stdout_file = File::create(log_filename).map_err(LaunchError::LogFile)?;
        let stderr_file = stdout_file.try_clone().map_err(LaunchError::LogFile)?;

        cmd.stdin(Stdio::inherit());
        cmd.stdout(Stdio::from(stdout_file));
        cmd.stderr(Stdio::from(stderr_file));

        log::info!(
            "Launching QEMU guest `{}` from {:?}",
            guest_name,
            script_path.display()
        );
        log::debug!("QEMU disk image: {:?}", disk_img);
        let child = match cmd.spawn() {
            Ok(c) => {
                log::debug!("Spawned QEMU process with PID {}", c.id());
                c
            }
            Err(e) => {
                log::error!("Failed to spawn QEMU for guest `{}`: {}", guest_name, e);
                return Err(ExecError::Exec(e).into());
            }
        };

        Ok(QemuGuestProc {
            name: guest_name.to_string(),
            child,
        })
    }

    pub fn launch_vde(&self, cache_dir: &Path, idx: u64) -> Result<VdeSwitchProc, LaunchError> {
        let cwd = std::env::current_dir().unwrap_or(".".into());
        let cache_dir = cwd.join(cache_dir).join("qemu");

        std::fs::create_dir_all(&cache_dir).map_err(|source| LaunchError::CreateCacheDir {
            path: cache_dir.to_path_buf(),
            source,
        })?;

        let temp_dir = TempDir::new().map_err(|source| LaunchError::CreateTempDir { source })?;

        let socket_path = temp_dir.path().join(format!("vde{}", idx));
        if socket_path.exists() {
            let _ = std::fs::remove_file(&socket_path);
        }

        let mut cmd = Command::new("vde_switch");
        cmd.args(["-s", socket_path.to_str().unwrap(), "--nostdin"]);

        let timestamp = Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
        let log_filename = cache_dir.join(format!("vde{idx}_log_{timestamp}.log"));

        let stdout_file = File::create(log_filename).map_err(LaunchError::LogFile)?;
        let stderr_file = stdout_file.try_clone().map_err(LaunchError::LogFile)?;

        cmd.stdin(Stdio::inherit());
        cmd.stdout(Stdio::from(stdout_file));
        cmd.stderr(Stdio::from(stderr_file));

        log::info!("Launching VDE switch with index {}", idx,);
        let child = match cmd.spawn() {
            Ok(c) => {
                log::debug!("Spawned vde switch process with PID {}", c.id());
                c
            }
            Err(e) => {
                log::error!("Failed to spawn vde switch with index `{}`: {}", idx, e);
                return Err(ExecError::Exec(e).into());
            }
        };

        Ok(VdeSwitchProc {
            idx,
            socket_path,
            child,
            _temp_dir: temp_dir,
        })
    }
}

impl QemuGuestProc {
    pub fn wait(mut self) -> Result<(), WaitError> {
        let status = self.child.wait().map_err(WaitError::Wait)?;
        if status.success() {
            Ok(())
        } else {
            Err(WaitError::Status(status))
        }
    }
}

impl VdeSwitchProc {
    pub fn stop(mut self) -> Result<(), StopError> {
        self.child.kill().map_err(StopError::Kill)?;

        let status = self.child.wait().map_err(StopError::Wait)?;

        #[cfg(unix)]
        let is_expected_signal = {
            use std::os::unix::process::ExitStatusExt;
            if let Some(sig) = status.signal()
                && (sig == 2 || sig == 15 || sig == 9)
            {
                true
            } else {
                false
            }
        };

        #[cfg(not(unix))]
        let is_expected_signal = false;

        if !(status.success() || is_expected_signal) {
            return Err(StopError::Status(status));
        }

        if self.socket_path.exists() {
            let _ = std::fs::remove_file(&self.socket_path);
        }

        Ok(())
    }
}
impl QemuRunner for System {
    fn launch_guest(
        &self,
        guest_name: &str,
        cache_dir: &Path,
        script_path: &Path,
        vde_switches: &mut dyn Iterator<Item = &dyn ports::VdeSwitchProc>,
    ) -> Result<Box<dyn ports::QemuGuestProc>, DynError> {
        let proc = self.launch_guest(guest_name, cache_dir, script_path, vde_switches)?;
        Ok(Box::new(proc))
    }

    fn create_vde(
        &self,
        cache_dir: &Path,
        idx: u64,
    ) -> Result<Box<dyn ports::VdeSwitchProc>, DynError> {
        let proc = self.launch_vde(cache_dir, idx)?;
        Ok(Box::new(proc))
    }
}

impl ports::QemuGuestProc for QemuGuestProc {
    fn name(&self) -> &str {
        &self.name
    }

    fn wait(self: Box<Self>) -> Result<(), DynError> {
        (*self).wait()?;
        Ok(())
    }
}

impl ports::VdeSwitchProc for VdeSwitchProc {
    fn index(&self) -> u64 {
        self.idx
    }

    fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    fn stop(self: Box<Self>) -> Result<(), DynError> {
        (*self).stop()?;
        Ok(())
    }
}
