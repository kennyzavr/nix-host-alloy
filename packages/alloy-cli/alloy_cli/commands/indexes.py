from ..cli import CLI
from ..di import Container
from .utils import resolve_force, resolve_add_to_git

from ..domain.exceptions import (
    IndexNotDefinedError,
    IndexAllocationFailedError,
    IndexStateCorruptedError,
)


def handle_allocate(args, cli: CLI, container: Container):
    service = container.indexes_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    try:
        records = service.get_generation_plan(args.index)
    except IndexNotDefinedError as e:
        cli.error(f"Index '{cli.id(e.name)}' is not defined in the cluster state.")
        return
    except Exception as e:
        cli.error(
            f"Unexpected error during plan generation: {getattr(e, 'error_msg', str(e))}"
        )
        return

    if not records:
        cli.skip("No indexes to allocate.")
        return

    for record in records:
        try:
            changed, size = service.allocate_index(
                record, force=force, add_to_git=add_to_git
            )
            if changed:
                cli.ok(f"Index '{cli.id(record.name)}' saved ({size} entries).")
            else:
                cli.skip(f"No changes in index '{cli.id(record.name)}'.")
        except IndexAllocationFailedError as e:
            cli.error(
                f"Allocation failed for '{cli.id(e.name)}': Need {e.needed} new slots, but not enough gaps in range [{e.min_val}, {e.max_val}]."
            )
        except IndexStateCorruptedError as e:
            cli.error(
                f"State for index '{cli.id(e.name)}' (fact '{cli.path(e.fact_name)}') is corrupted: {e.reason}"
            )
        except Exception as e:
            cli.error(
                f"Unexpected error allocating index '{cli.id(record.name)}': {getattr(e, 'error_msg', str(e))}"
            )


def handle_list(args, cli: CLI, container: Container):
    service = container.indexes_service
    records = service.indexes_repo.find_all()

    if not records:
        cli.info("No indexes defined.")
        return

    from rich.table import Table

    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Name")
    table.add_column("Fact Name")
    table.add_column("Min")
    table.add_column("Max")
    table.add_column("Keys")

    for record in records:
        table.add_row(
            record.name,
            record.fact_name,
            str(record.min_value),
            str(record.max_value),
            str(len(record.keys)),
        )

    cli.console.print(table)


def handle_show(args, cli: CLI, container: Container):
    record = container.indexes_service.indexes_repo.find_by_name(args.name)
    if not record:
        cli.error(f"Index '{args.name}' not found.")
        return

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text

    content = []
    content.append(Text(f"Fact Name: {record.fact_name}"))
    content.append(Text(f"Range: {record.min_value} - {record.max_value}"))
    content.append(Text(f"Defined Keys ({len(record.keys)}):"))
    for k in sorted(record.keys):
        content.append(Text(f"  - {k}"))

    cli.console.print(
        Panel(Group(*content), title=f"Index: [bold]{record.name}[/bold]", expand=False)
    )


def register_parser(subparsers):
    parser = subparsers.add_parser("indexes", help="Manage index allocations")
    subcmds = parser.add_subparsers(
        title="commands", dest="cmd_indexes", required=True, metavar="COMMAND"
    )

    gen_parser = subcmds.add_parser("allocate", help="Allocate or update indexes")
    gen_parser.add_argument(
        "index", nargs="*", help="Specific indexes to allocate (default: all)"
    )
    gen_parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Force allocation even if the state is corrupted. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    gen_parser.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add the modified fact file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    gen_parser.set_defaults(func=handle_allocate)

    list_parser = subcmds.add_parser("list", help="List all indexes")
    list_parser.set_defaults(func=handle_list)

    show_parser = subcmds.add_parser("show", help="Show details of an index")
    show_parser.add_argument("name", help="Name of the index")
    show_parser.set_defaults(func=handle_show)
