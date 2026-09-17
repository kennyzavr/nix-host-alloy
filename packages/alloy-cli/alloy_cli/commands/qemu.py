from ..cli import CLI
from ..di import Container
from ..domain.exceptions import (
    QemuNotDefinedError,
    QemuVariantNotFoundError,
    QemuAlreadyRunningError,
)
from .utils import ensure_indexes_consistency


def _resolve_records(args, cli, container):
    """Resolve VM records from args, aborting on errors."""
    service = container.qemu_guest_service
    names = getattr(args, "name", None) or None
    tags = getattr(args, "tag", None) or None
    try:
        return service.resolve(names=names, tags=tags)
    except QemuNotDefinedError as e:
        cli.abort(
            f"VM '{cli.id(e.vm_name)}' is not defined. "
            "Set vm.enable = true on a host to define one."
        )


def _print_port_table(cli, records):
    """Print a summary table of port forwards and SSH connection hints."""
    from rich.table import Table

    has_ports = any(r.forward_ports for r in records)
    if not has_ports:
        return

    table = Table(show_header=True, header_style="bold magenta", title="Port Forwards")
    table.add_column("Host")
    table.add_column("Service")
    table.add_column("Guest")
    table.add_column("Hypervisor")
    table.add_column("Proto")

    for record in records:
        for pf in record.forward_ports:
            table.add_row(
                record.name,
                pf.name,
                f":{pf.guest}",
                f"localhost:{pf.hypervisor}",
                pf.proto,
            )

    cli.console.print(table)


def handle_list(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)

    records = _resolve_records(args, cli, container)
    if not records:
        cli.info(
            "No VMs match the criteria. Set vm.enable = true on a host to define one."
        )
        return

    from rich.table import Table

    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Name")
    table.add_column("Tags")
    table.add_column("Nets")
    table.add_column("Variants")
    table.add_column("Forwarded Ports")

    for record in records:
        tags = ", ".join(record.tags) if record.tags else "-"
        ports_str = (
            ", ".join(
                f"{pf.name}({pf.proto} {pf.hypervisor}->{pf.guest})"
                for pf in record.forward_ports
            )
            if record.forward_ports
            else "-"
        )
        variants_str = (
            ", ".join(f"{v}*" if v == record.variant else v for v in record.variants)
            or "-"
        )
        nets_str = (
            ", ".join(
                f"{qnet.net.name}({qnet.iface} {qnet.mac})" for qnet in record.nets
            )
            if record.nets
            else "-"
        )
        table.add_row(
            record.name,
            tags,
            nets_str,
            variants_str,
            ports_str,
        )

    cli.console.print(table)
    cli.console.print("")
    _print_port_table(cli, records)


def handle_run(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)

    service = container.qemu_guest_service
    records = _resolve_records(args, cli, container)
    if not records:
        cli.abort("No VMs match the criteria.")

    variant = getattr(args, "variant", None)

    try:
        for record in records:
            service.get_run_script(record, variant)
    except QemuVariantNotFoundError as e:
        available = ", ".join(e.available) or "none"
        cli.abort(
            f"No variant '{e.variant_name}' registered for VM '{cli.id(e.vm_name)}'. "
            f"Available: {available}"
        )

    _print_port_table(cli, records)
    cli.console.print("")

    detach = getattr(args, "detach", False)

    nets = service.collect_vde_networks(records)
    try:
        switches = service.start_vde_switches(nets, detach=detach)
    except TimeoutError as e:
        cli.abort(f"VDE switch failed to start: {e}")

    for idx, sw in switches.items():
        net_name = next((n.name for n in nets if n.idx == idx), str(idx))
        cli.step(f"VDE [{net_name}] ready  {cli.path(sw.socket_path)}")

    sockets = {idx: sw.socket_path for idx, sw in switches.items()}

    try:
        processes = service.launch_all(records, variant, sockets=sockets, detach=detach)
        for proc in processes:
            cli.ok(
                f"'{cli.id(proc.name)}'  pid {proc.pid}  log: {cli.path(proc.log_path)}"
            )

        if detach:
            if getattr(args, "wait", False):
                timeout = getattr(args, "wait_timeout", 60)
                cli.step(f"Waiting for VMs to boot (timeout {timeout}s)...")

                def on_ready(vm_name):
                    cli.ok(f"VM '{cli.id(vm_name)}' is ready!")

                if not service.wait_until_ready(
                    processes, timeout=timeout, on_ready=on_ready
                ):
                    cli.console.print()
                    cli.step(
                        "Aborting: timeout or process died while waiting for boot."
                    )
                    service.qemu.terminate_all(processes)
                    service.stop_vde_switches(switches)
                    cli.abort("Failed to boot VMs within timeout.")

            cli.step("VMs and VDE switches detached and running in background.")
            return

        if processes:
            cli.info(f"{len(processes)} VMs running. Ctrl+C to stop.")
            try:

                def on_ready(vm_name):
                    cli.ok(f"VM '{cli.id(vm_name)}' is ready!")

                service.wait_and_cleanup(processes, on_ready=on_ready)
            except KeyboardInterrupt:
                cli.console.print()
                cli.step("Stopping all VMs...")
    except QemuAlreadyRunningError as e:
        cli.abort(f"VM '{cli.id(e.vm_name)}' is already running (PID {e.pid}).")
    except RuntimeError as e:
        cli.abort(str(e))
    finally:
        if not getattr(args, "detach", False):
            service.stop_vde_switches(switches)
            cli.step("VDE switches stopped.")


def handle_stop(args, cli: CLI, container: Container):
    cli.step("Stopping all detached VMs and VDE switches...")
    container.qemu_guest_service.stop_all()
    cli.ok("Stopped.")


def handle_show(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)

    record = container.qemu_guest_service.repo.find_by_name(args.name)
    if not record:
        cli.abort(f"VM '{cli.id(args.name)}' not found.")

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text

    content = [
        Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"),
    ]

    if record.nets:
        content.append(Text("\nNets:", style="bold"))
        for qnet in record.nets:
            content.append(
                Text(f"  {qnet.net.name}: {qnet.iface} {qnet.mac} (idx {qnet.net.idx})")
            )

    if record.variants:
        content.append(Text("\nVariants:", style="bold"))
        for name, script in record.variants.items():
            marker = " (default)" if name == record.variant else ""
            content.append(Text(f"  {name}{marker}: {script}"))
    else:
        content.append(Text("\nVariants: none", style="dim"))

    if record.forward_ports:
        content.append(Text("\nPort Forwards:", style="bold"))
        for pf in record.forward_ports:
            content.append(
                Text(f"  {pf.name}: {pf.proto} localhost:{pf.hypervisor} -> guest:{pf.guest}")
            )
    else:
        content.append(Text("\nPort Forwards: none", style="dim"))

    cli.console.print(
        Panel(Group(*content), title=f"VM: [bold]{record.name}[/bold]", expand=False)
    )


def register_parser(subparsers):
    parser = subparsers.add_parser("qemu", help="Manage and run QEMU VMs")
    subcmds = parser.add_subparsers(
        title="commands", dest="cmd_qemu", required=True, metavar="COMMAND"
    )

    list_parser = subcmds.add_parser(
        "list", help="List all defined VMs and their port mappings"
    )
    list_parser.add_argument("name", nargs="*", help="Filter by VM names")
    list_parser.add_argument(
        "-t", "--tag", action="append", help="Filter VMs by tag (repeatable, OR logic)"
    )
    list_parser.set_defaults(func=handle_list)

    run_parser = subcmds.add_parser(
        "run",
        help="Run one or more VMs. Always attached to this terminal (foreground); "
        "there is no background/detach mode -- stop with Ctrl+C.",
    )
    run_parser.add_argument(
        "name", nargs="*", help="Names of VMs to run (default: all)"
    )
    run_parser.add_argument(
        "-t", "--tag", action="append", help="Filter VMs by tag (repeatable, OR logic)"
    )
    run_parser.add_argument(
        "--variant",
        default=None,
        help='Launch-script variant to use (e.g. "qemu-vm", "disko"). '
        "Defaults to each VM's `variant`.",
    )
    run_parser.add_argument(
        "--detach",
        action="store_true",
        help="Run VMs in the background and exit immediately. Use 'qemu stop' to terminate them.",
    )
    run_parser.add_argument(
        "--wait",
        action="store_true",
        help="When used with --detach, wait until VMs are fully booted before exiting.",
    )
    run_parser.add_argument(
        "--wait-timeout",
        type=int,
        default=60,
        help="Timeout in seconds for --wait. Default is 60. 0 means infinite.",
    )
    run_parser.set_defaults(func=handle_run)

    stop_parser = subcmds.add_parser(
        "stop", help="Stop all detached VMs and VDE switches"
    )
    stop_parser.set_defaults(func=handle_stop)

    show_parser = subcmds.add_parser("show", help="Show details of a VM")
    show_parser.add_argument("name", help="Name of the VM")
    show_parser.set_defaults(func=handle_show)
