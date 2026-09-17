from pathlib import Path
from typing import List, Optional

from ..data.state import QemuNetRepository, QemuGuestRepository
from ..data.models import QemuGuestRecord, QemuNetRecord
from ..infrastructure.qemu import QemuAdapter, QemuProcess, VdeAdapter, VdeSwitch
from .exceptions import (
    QemuNotDefinedError,
    QemuVariantNotFoundError,
)


class QemuService:
    def __init__(
        self,
        guest_repo: QemuGuestRepository,
        net_repo: QemuNetRepository,
        qemu: QemuAdapter,
        vde: VdeAdapter,
    ):
        self.guest_repo = guest_repo
        self.net_repo = net_repo
        self.qemu = qemu
        self.vde = vde

    def resolve(
        self,
        names: Optional[List[str]] = None,
        tags: Optional[List[str]] = None,
    ) -> List[QemuGuestRecord]:
        guests = self.guest_repo.find_all()

        if tags:
            tag_set = set(tags)
            guests = [guest for guest in guests if tag_set & set(guest.tags)]

        if names:
            name_set = set(names)
            for name in name_set:
                if not any(guest.name == name for guest in self.guest_repo.find_all()):
                    raise QemuNotDefinedError(name)
            guests = [guest for guest in guests if guest.name in name_set]

        return guests

    def get_run_script(
        self, guests: QemuGuestRecord, variant: Optional[str] = None
    ) -> str:
        variant_name = variant or guests.variant
        if variant_name is None or variant_name not in guests.variants:
            available = list(guests.variants.keys())
            raise QemuVariantNotFoundError(
                guests.name, variant_name or "<none>", available
            )
        return guests.variants[variant_name]

    def collect_vde_networks(
        self, guests: List[QemuGuestRecord]
    ) -> list[QemuNetRecord]:
        all_nets = self.net_repo.find_all()
        qnets = [qnet.net for guest in guests for qnet in guest.nets]
        return [net for net in all_nets if net.name in qnets]

    def start_vde_switches(
        self, nets: list[QemuNetRecord], detach: bool = False
    ) -> dict[int, VdeSwitch]:
        switches = self.vde.start_for_networks(nets, detach=detach)
        self.vde.wait_for_sockets(switches)
        return switches

    def stop_vde_switches(self, switches: dict[int, VdeSwitch]):
        VdeAdapter.stop(switches)

    def launch_all(
        self,
        guests: List[QemuGuestRecord],
        variant: Optional[str] = None,
        sockets: Optional[dict[int, Path]] = None,
        detach: bool = False,
    ) -> List[QemuProcess]:
        processes = []
        for guest in guests:
            run_script = self.get_run_script(guest, variant)
            proc = self.qemu.launch(
                guest.name, run_script, sockets=sockets, detach=detach
            )
            processes.append(proc)
        return processes

    def stop_all(self):
        self.qemu.stop_all()
        self.vde.stop_all()

    def wait_until_ready(
        self, processes: List[QemuProcess], timeout: int = 60, on_ready=None
    ) -> bool:
        import time

        ready = set()
        log_fds = {}
        for proc in processes:
            try:
                log_fds[proc.name] = open(proc.log_path, "r", errors="replace")
            except FileNotFoundError:
                pass

        start_time = time.monotonic()
        try:
            while len(ready) < len(processes):
                if timeout > 0 and (time.monotonic() - start_time) > timeout:
                    return False

                alive = []
                for proc in processes:
                    if proc._process and proc._process.poll() is not None:
                        if proc.name in log_fds:
                            log_fds[proc.name].close()
                            del log_fds[proc.name]
                        continue
                    alive.append(proc)

                    if proc.name not in ready and proc.name in log_fds:
                        f = log_fds[proc.name]
                        while True:
                            pos = f.tell()
                            line = f.readline()
                            if not line:
                                f.seek(pos)
                                break
                            if "Welcome to NixOS" in line or "login:" in line:
                                ready.add(proc.name)
                                if on_ready:
                                    on_ready(proc.name)
                                break

                if len(ready) == len(processes):
                    return True

                if len(alive) < len(processes):
                    return False

                time.sleep(0.5)
            return True
        finally:
            for f in log_fds.values():
                f.close()

    def wait_and_cleanup(self, processes: List[QemuProcess], on_ready=None):
        import time

        ready = set()
        log_fds = {}
        if on_ready:
            for proc in processes:
                try:
                    log_fds[proc.name] = open(proc.log_path, "r", errors="replace")
                except FileNotFoundError:
                    pass

        try:
            while processes:
                alive = []
                for proc in processes:
                    if proc._process and proc._process.poll() is not None:
                        if proc.name in log_fds:
                            log_fds[proc.name].close()
                            del log_fds[proc.name]
                        continue

                    alive.append(proc)

                    if on_ready and proc.name not in ready and proc.name in log_fds:
                        f = log_fds[proc.name]
                        while True:
                            pos = f.tell()
                            line = f.readline()
                            if not line:
                                f.seek(pos)
                                break
                            if "Welcome to NixOS" in line or "login:" in line:
                                on_ready(proc.name)
                                ready.add(proc.name)
                                break

                processes = alive
                if not processes:
                    break
                time.sleep(0.5)
        except KeyboardInterrupt:
            import signal

            signal.signal(signal.SIGINT, signal.SIG_IGN)
            self.qemu.terminate_all(processes)
            raise
        finally:
            for f in log_fds.values():
                f.close()
