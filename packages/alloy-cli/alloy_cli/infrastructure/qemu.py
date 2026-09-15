import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, IO
import fcntl

from alloy_cli.data.models import QemuNetRecord

from ..domain.exceptions import QemuAlreadyRunningError


@dataclass
class QemuProcess:
    name: str
    pid: int
    log_path: Path
    _process: Optional[subprocess.Popen]
    _log_file: Optional[IO]

    def wait(self, timeout: Optional[float] = None) -> int:
        if self._process is None:
            raise RuntimeError(f"No live process handle for VM '{self.name}'")
        return self._process.wait(timeout=timeout)

    def terminate(self):
        if self._process is not None:
            self._process.terminate()

    def kill(self):
        if self._process is not None:
            self._process.kill()

    def close_log(self):
        if self._log_file is not None and not self._log_file.closed:
            self._log_file.close()

    def clear_pid_file(self, state_dir: Path):
        try:
            (state_dir / f"{self.name}.pid").unlink()
        except FileNotFoundError:
            pass


@dataclass
class VdeSwitch:
    """A running vde_switch process with its associated socket directory."""

    socket_dir: Path
    socket_path: Path
    _process: Optional[subprocess.Popen]

    def terminate(self, timeout: float = 5.0):
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._process.kill()
            self._process.wait()

    @property
    def is_alive(self) -> bool:
        if self._process is None:
            return self.socket_path.exists()
        return self._process.poll() is None


class VdeAdapter:
    def __init__(self, alloy_name: str, state_dir: Path):
        self._alloy_name = alloy_name
        self._state_dir = state_dir

    def socket_path(self, idx: int) -> Path:
        return self._state_dir / f"vde_net{idx}.sock"

    def pid_path(self, idx: int) -> Path:
        return self._state_dir / f"vde_net{idx}.pid"

    def start_for_networks(
        self, nets: list[QemuNetRecord], detach: bool = False
    ) -> dict[int, VdeSwitch]:
        unique = {n.idx: n for n in nets}
        self._state_dir.mkdir(parents=True, exist_ok=True)
        switches = {}
        for idx in unique:
            sock = self.socket_path(idx)
            pidf = self.pid_path(idx)

            if sock.exists():
                try:
                    sock.unlink()
                except OSError:
                    pass

            cmd = ["vde_switch", "-s", str(sock), "--nostdin"]
            if detach:
                cmd.extend(["-d", "--pidfile", str(pidf)])

            proc = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            switches[idx] = VdeSwitch(
                socket_dir=self._state_dir,
                socket_path=sock,
                _process=proc if not detach else None,
            )
        return switches

    def wait_for_sockets(self, switches: dict[int, VdeSwitch], timeout: float = 5.0):
        import time

        deadline = time.monotonic() + timeout
        pending = set(switches.keys())
        while pending:
            pending = {i for i in pending if not switches[i].socket_path.exists()}
            if not pending:
                break
            if time.monotonic() > deadline:
                raise TimeoutError(
                    f"VDE sockets not ready after {timeout}s, idx: {pending}"
                )
            time.sleep(0.05)

    def stop_all(self):
        import signal

        for pidf in self._state_dir.glob("vde_net*.pid"):
            try:
                pid = int(pidf.read_text().strip())
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass
            try:
                pidf.unlink()
            except OSError:
                pass
        for sock in self._state_dir.glob("vde_net*.sock"):
            try:
                sock.unlink()
            except OSError:
                pass

    @staticmethod
    def stop(switches: dict[int, VdeSwitch]):
        for sw in switches.values():
            if sw._process:
                sw.terminate()
            try:
                if sw.socket_path.exists():
                    sw.socket_path.unlink()
            except OSError:
                pass


class QemuAdapter:
    def __init__(self, state_dir: Path):
        self._state_dir = state_dir

    @property
    def state_dir(self) -> Path:
        return self._state_dir

    def ensure_state_dir(self):
        self._state_dir.mkdir(parents=True, exist_ok=True)

    def disk_image_path(self, vm_name: str) -> Path:
        return self._state_dir / f"{vm_name}.qcow2"

    def log_path(self, vm_name: str) -> Path:
        return self._state_dir / f"{vm_name}.log"

    def pid_path(self, vm_name: str) -> Path:
        return self._state_dir / f"{vm_name}.pid"

    def lock_path(self, vm_name: str) -> Path:
        return self._state_dir / f"{vm_name}.lock"

    def _acquire_start_lock(self, vm_name: str) -> IO:
        self.ensure_state_dir()
        lock_file = open(self.lock_path(vm_name), "w")
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(
                f"Another process is currently starting or stopping VM '{vm_name}'."
            )
        return lock_file

    def _check_and_write_pid(self, vm_name: str, pid: int):
        pid_file = self.pid_path(vm_name)
        if pid_file.exists():
            try:
                old_pid = int(pid_file.read_text().strip() or "0")
                if old_pid > 0:
                    try:
                        os.kill(old_pid, 0)
                        with open(f"/proc/{old_pid}/comm", "r") as f:
                            comm = f.read().strip()
                            if (
                                "qemu" in comm
                                or "run-" in comm
                                or "python" in comm
                                or "bash" in comm
                            ):
                                raise QemuAlreadyRunningError(vm_name, old_pid)
                    except OSError:
                        pass
            except ValueError:
                pass

        if pid > 0:
            pid_file.write_text(str(pid))

    def launch(
        self,
        vm_name: str,
        run_script: str,
        sockets: Optional[dict[int, Path]] = None,
        detach: bool = False,
    ) -> QemuProcess:
        self.ensure_state_dir()

        env = os.environ.copy()
        env["NIX_DISK_IMAGE"] = str(self.disk_image_path(vm_name))
        for idx, sock_path in (sockets or {}).items():
            env[f"ALLOY_VDE_SOCKET_{idx}"] = str(sock_path)

        log = self.log_path(vm_name)
        log_f = open(log, "w")

        lock = self._acquire_start_lock(vm_name)
        try:
            self._check_and_write_pid(vm_name, -1)

            proc = subprocess.Popen(
                [run_script],
                env=env,
                stdout=log_f,
                stderr=log_f,
                stdin=subprocess.DEVNULL if detach else subprocess.PIPE,
                start_new_session=detach,
            )

            self._check_and_write_pid(vm_name, proc.pid)
        finally:
            lock.close()

        return QemuProcess(
            name=vm_name,
            pid=proc.pid,
            log_path=log,
            _process=proc,
            _log_file=log_f,
        )

    def stop_all(self):
        import signal

        for pidf in self._state_dir.glob("*.pid"):
            if pidf.name.startswith("vde_"):
                continue
            try:
                pid = int(pidf.read_text().strip())
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass
            try:
                pidf.unlink()
            except OSError:
                pass

    @staticmethod
    def terminate_all(processes: list["QemuProcess"], timeout: float = 10.0):
        import time

        for proc in processes:
            if proc._process and proc._process.stdin:
                try:
                    proc._process.stdin.close()
                except Exception:
                    pass
            proc.terminate()

        deadline = time.monotonic() + timeout
        for proc in processes:
            rem = deadline - time.monotonic()
            if rem <= 0:
                rem = 0.01
            try:
                proc.wait(timeout=rem)
            except subprocess.TimeoutExpired:
                pass

            if proc._process and proc._process.poll() is None:
                proc.kill()
                proc.wait()
            proc.close_log()
            proc.clear_pid_file(proc.log_path.parent)

    @staticmethod
    def terminate_process(proc: QemuProcess, timeout: float = 10.0):
        QemuAdapter.terminate_all([proc], timeout=timeout)
