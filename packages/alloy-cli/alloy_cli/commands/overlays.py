import argparse
from ..cli import CLI
from ..di import Container

def handle_list(args, cli: CLI, container: Container):
    records = container.overlays_repo.find_all()
    if not records:
        cli.info("No overlays defined.")
        return

    index_record = container.indexes_repo.find_by_name("overlays")
    index_state = {}
    if index_record:
        try:
            index_state, _ = container.indexes_service._read_state(index_record, force=False)
        except Exception:
            pass

    from rich.table import Table
    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Name")
    table.add_column("Index")
    table.add_column("Tags")
    table.add_column("IPv6 Prefix")

    for record in records:
        idx = str(index_state.get(record.name)) if record.name in index_state else "-"
        tags = ", ".join(record.tags) if record.tags else "-"
        table.add_row(
            record.name,
            idx,
            tags,
            record.ipv6Prefix
        )

    cli.console.print(table)

def handle_show(args, cli: CLI, container: Container):
    record = container.overlays_repo.find_by_name(args.name)
    if not record:
        cli.error(f"Overlay '{args.name}' not found.")
        return

    index_record = container.indexes_repo.find_by_name("overlays")
    index_state = {}
    if index_record:
        try:
            index_state, _ = container.indexes_service._read_state(index_record, force=False)
        except Exception:
            pass
    idx = str(index_state.get(record.name)) if record.name in index_state else "-"

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text
    from rich.table import Table

    content = []
    content.append(Text(f"Index: {idx}"))
    content.append(Text(f"IPv6 Prefix: {record.ipv6Prefix}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))

    hosts = set()
    for link in record.links:
        hosts.add(link.host_a)
        hosts.add(link.host_b)
    
    sorted_hosts = sorted(list(hosts))
    if not sorted_hosts:
        content.append(Text("\nTopology: No links defined.", style="dim"))
        cli.console.print(Panel(Group(*content), title=f"Overlay: [bold]{record.name}[/bold]", expand=False))
        return

    matrix = Table(show_header=True, header_style="bold magenta", title="Topology (Adjacency Matrix)")
    matrix.add_column("Host")
    for h in sorted_hosts:
        matrix.add_column(h, justify="center")
        
    for h1 in sorted_hosts:
        row = [f"[bold]{h1}[/bold]"]
        for h2 in sorted_hosts:
            if h1 == h2:
                row.append("-")
            else:
                connected = False
                for link in record.links:
                    if (link.host_a == h1 and link.host_b == h2) or (link.host_a == h2 and link.host_b == h1):
                        connected = True
                        break
                row.append("✅" if connected else "❌")
        matrix.add_row(*row)
    
    content.append(Text(""))
    content.append(matrix)

    cli.console.print(Panel(Group(*content), title=f"Overlay: [bold]{record.name}[/bold]", expand=False))

def register_parser(subparsers):
    parser = subparsers.add_parser("overlays", help="Manage overlays")
    subcmds = parser.add_subparsers(title="commands", dest="cmd_overlays", required=True, metavar="COMMAND")
    
    list_parser = subcmds.add_parser("list", help="List all overlays")
    list_parser.set_defaults(func=handle_list)

    show_parser = subcmds.add_parser("show", help="Show details of an overlay and its topology")
    show_parser.add_argument("name", help="Name of the overlay")
    show_parser.set_defaults(func=handle_show)
