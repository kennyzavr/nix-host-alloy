import argparse
from ..cli import CLI
from ..di import Container

def handle_list(args, cli: CLI, container: Container):
    records = container.jails_repo.find_all()
    if not records:
        cli.info("No jails defined.")
        return

    index_record = container.indexes_repo.find_by_name("jails")
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
    table.add_column("Host")
    table.add_column("Tags")
    if verbose:
        table.add_column("IPv6 Addresses")

    jail_overlays = container.jail_overlays_repo.find_all()

    for record in records:
        idx = str(index_state.get(record.name)) if record.name in index_state else "-"
        tags = ", ".join(record.tags) if record.tags else "-"
        row = [record.name, idx, record.host, tags]
        if verbose:
            ips = []
            for ho in jail_overlays:
                if ho.jail == record.name:
                    ips.append(f"{ho.name}: {ho.ipv6}")
            row.append(", ".join(ips) if ips else "-")
        table.add_row(*row)

    cli._console.print(table)


def handle_show(args, cli: CLI, container: Container):
    record = container.jails_repo.find_by_name(args.name)
    if not record:
        cli.error(f"Jail '{args.name}' not found.")
        return

    index_record = container.indexes_repo.find_by_name("jails")
    index_state = {}
    if index_record:
        try:
            index_state, _ = container.indexes_service._read_state(index_record, force=False)
        except Exception:
            pass
    idx = str(index_state.get(record.name)) if record.name in index_state else "-"

    jail_overlays = [ho for ho in container.jail_overlays_repo.find_all() if ho.jail == record.name]

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text

    content = []
    content.append(Text(f"Host: {record.host}"))
    content.append(Text(f"Index: {idx}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))
    
    if jail_overlays:
        content.append(Text("\nIPv6 Addresses (Overlays):", style="bold"))
        for ho in jail_overlays:
            content.append(Text(f"  {ho.name}: ", style="cyan").append(ho.ipv6))

    cli._console.print(Panel(Group(*content), title=f"Jail: [bold]{record.name}[/bold]", expand=False))

def register_parser(subparsers):
    parser = subparsers.add_parser("jails", help="Manage jails")
    subcmds = parser.add_subparsers(title="commands", dest="cmd_jails", required=True, metavar="COMMAND")
    
    list_parser = subcmds.add_parser("list", help="List all jails")
    list_parser.add_argument("-v", "--verbose", action="store_true", help="Show IPv6 addresses")
    list_parser.set_defaults(func=handle_list)

    show_parser = subcmds.add_parser("show", help="Show details of a jail")
    show_parser.add_argument("name", help="Name of the jail")
    show_parser.set_defaults(func=handle_show)
