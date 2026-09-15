import argparse
from ..cli import CLI
from ..di import Container

def handle_list(args, cli: CLI, container: Container):
    records = container.hosts_repo.find_all()
    if not records:
        cli.info("No hosts defined.")
        return

    index_record = container.indexes_repo.find_by_name("hosts")
    index_state = {}
    if index_record:
        try:
            index_state, _ = container.indexes_service._read_state(index_record, force=False)
        except Exception:
            pass

    verbose = getattr(args, "verbose", False)

    from rich.table import Table
    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Name")
    table.add_column("Index")
    table.add_column("Tags")
    table.add_column("Jails")
    if verbose:
        table.add_column("IPv6 Addresses")

    host_overlays = container.host_overlays_repo.find_all()
    all_jails = container.jails_repo.find_all()

    for record in records:
        idx = str(index_state.get(record.name)) if record.name in index_state else "-"
        tags = ", ".join(record.tags) if record.tags else "-"
        host_jails = [j.name for j in all_jails if j.host == record.name]
        row = [record.name, idx, tags, str(len(host_jails))]
        if verbose:
            ips = []
            for ho in host_overlays:
                if ho.host == record.name:
                    ips.append(f"{ho.name}: {ho.ipv6}")
            row.append(", ".join(ips) if ips else "-")
        table.add_row(*row)

    cli.console.print(table)


def handle_show(args, cli: CLI, container: Container):
    record = container.hosts_repo.find_by_name(args.name)
    if not record:
        cli.error(f"Host '{args.name}' not found.")
        return

    index_record = container.indexes_repo.find_by_name("hosts")
    index_state = {}
    if index_record:
        try:
            index_state, _ = container.indexes_service._read_state(index_record, force=False)
        except Exception:
            pass
    idx = str(index_state.get(record.name)) if record.name in index_state else "-"

    host_overlays = [ho for ho in container.host_overlays_repo.find_all() if ho.host == record.name]
    host_jails = [j for j in container.jails_repo.find_all() if j.host == record.name]

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text

    content = []
    content.append(Text(f"Index: {idx}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))
    
    if host_jails:
        content.append(Text("\nJails:", style="bold"))
        for j in host_jails:
            content.append(Text(f"  - {j.name}", style="green"))

    if host_overlays:
        content.append(Text("\nIPv6 Addresses (Overlays):", style="bold"))
        for ho in host_overlays:
            content.append(Text(f"  {ho.name}: ", style="cyan").append(ho.ipv6))

    cli.console.print(Panel(Group(*content), title=f"Host: [bold]{record.name}[/bold]", expand=False))

def register_parser(subparsers):
    parser = subparsers.add_parser("hosts", help="Manage hosts")
    subcmds = parser.add_subparsers(title="commands", dest="cmd_hosts", required=True, metavar="COMMAND")
    
    list_parser = subcmds.add_parser("list", help="List all hosts")
    list_parser.add_argument("-v", "--verbose", action="store_true", help="Show IPv6 addresses")
    list_parser.set_defaults(func=handle_list)

    show_parser = subcmds.add_parser("show", help="Show details of a host")
    show_parser.add_argument("name", help="Name of the host")
    show_parser.set_defaults(func=handle_show)
