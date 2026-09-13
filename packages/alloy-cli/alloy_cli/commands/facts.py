import sys
from ..cli import CLI
from ..di import Container
from ..domain.exceptions import *
from .utils import resolve_force, resolve_add_to_git, ensure_indexes_consistency


def handle_set(args, cli: CLI, container: Container):
    service = container.facts_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    ensure_indexes_consistency(cli, container)

    new_data = sys.stdin.read()
    try:
        fact_file = service.set(
            args.fact,
            new_data,
            force=force,
            add_to_git=add_to_git,
        )
    except FactNotDefinedError:
        cli.abort(f"Fact '{cli.id(args.fact)}' is not defined in the configuration.")
    except FactFileAlreadyExistsError as e:
        cli.skip(
            f"Fact '{cli.id(args.fact)}' already exists at {cli.path(e.fact_file)}. "
            f"Use --force to overwrite (or set ALLOY_FORCE=1)."
        )
        sys.exit(0)
    except GitAddError as e:
        cli.abort(f"Operation failed on '{cli.id(e.target)}': {e.error_msg}")

    cli.ok(f"Fact '{cli.id(args.fact)}' written to {cli.path(cli.root / fact_file)}")


def handle_get(args, cli: CLI, container: Container):
    service = container.facts_service

    ensure_indexes_consistency(cli, container)

    try:
        fact_value = service.get(args.fact)
    except FactNotDefinedError:
        cli.abort(f"Fact '{cli.id(args.fact)}' is not defined in the configuration.")
    except FactFileNotFoundError as e:
        cli.abort(
            f"File for fact '{cli.id(args.fact)}' does not exist at {cli.path(e.fact_file)}."
        )

    sys.stdout.write(fact_value)
    sys.stdout.flush()


def handle_edit(args, cli: CLI, container: Container):
    service = container.facts_service
    add_to_git = resolve_add_to_git(args.add_to_git)

    ensure_indexes_consistency(cli, container)

    try:
        current_data = service.get(args.fact)
    except FactFileNotFoundError:
        current_data = None
        cli.step(f"Creating new fact '{cli.id(args.fact)}'...")
    except FactNotDefinedError:
        cli.abort(f"Fact '{cli.id(args.fact)}' is not defined in the configuration.")

    try:
        new_data = container.editor.edit(current_data)
    except ValueError:
        cli.abort("The file is empty. Aborting operation.")

    if new_data is None:
        cli.skip("No changes made, exiting.")
        sys.exit(0)

    try:
        service.set(
            args.fact,
            new_data,
            force=True,
            add_to_git=add_to_git,
        )
    except GitAddError as e:
        cli.abort(f"Operation failed on '{cli.id(e.target)}': {e.error_msg}")

    cli.ok(f"Fact '{cli.id(args.fact)}' saved successfully.")


def handle_list(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    facts = container.facts_service.repo.find_all()

    if args.tags:
        required_tags = set(args.tags)
        facts = [f for f in facts if f.tags and required_tags.issubset(set(f.tags))]

    if not facts:
        if args.tags:
            cli.info(f"No facts found matching tags: {', '.join(args.tags)}")
        else:
            cli.info("No facts defined.")
        return

    verbose = args.verbose

    from rich.tree import Tree
    from datetime import datetime
    import os

    def get_status_str(file_path):
        if container.fs.exists(file_path):
            if verbose:
                stat = os.stat(container.fs.resolve(file_path))
                mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
                return f"✅ Present [dim](Modified: {mtime})[/dim]"
            return "✅ Present"
        return "❌ Missing"

    from .views import render_tree_view

    def render_leaf(node, key, fact):
        status = get_status_str(fact.file)
        leaf = node.add(f"[bold cyan]{key}[/bold cyan]  ({status})")

        if verbose:
            if fact.tags:
                leaf.add(f"[dim]Tags:[/dim] {', '.join(fact.tags)}")
            leaf.add(f"[dim]Path:[/dim] {cli.path(fact.file)}")

    tree = Tree("[bold]Facts[/bold]", guide_style="dim")
    render_tree_view(tree, facts, lambda f: f.name, render_leaf, flat=args.flat)
    cli._console.print(tree)

    cli._console.print(
        f"──────────────────────────\n[dim]Total: {len(facts)} facts[/dim]"
    )


def handle_show(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    service = container.facts_service
    record = service.repo.find_by_name(args.name)
    
    if not record:
        cli.error(f"Fact '{args.name}' not found.")
        return

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text
    import os
    
    status = "❌ Missing"
    mtime_str = ""
    if container.fs.exists(record.file):
        from datetime import datetime
        stat = os.stat(container.fs.resolve(record.file))
        mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        status = "✅ Present"
        mtime_str = f" (Modified: {mtime})"
        
    content = []
    content.append(Text.from_markup(f"Path: {cli.path(record.file)}"))
    content.append(Text(f"Status: {status}{mtime_str}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))

    cli._console.print(Panel(Group(*content), title=f"Fact: [bold]{record.name}[/bold]", expand=False))


def register_parser(subparsers):
    parser = subparsers.add_parser("facts", help="Manage generic cluster facts")
    subs = parser.add_subparsers(
        title="commands", dest="subcommand", required=True, metavar="COMMAND"
    )

    cmd_set = subs.add_parser("set", help="Set a fact value from stdin")
    cmd_set.add_argument("fact", help="Name of the fact")
    cmd_set.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Force overwrite existing fact file. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_set.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add file to git after writing. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_set.set_defaults(func=handle_set)

    cmd_get = subs.add_parser("get", help="Output a fact value to stdout")
    cmd_get.add_argument("fact", help="Name of the fact")
    cmd_get.set_defaults(func=handle_get)

    cmd_edit = subs.add_parser("edit", help="Edit a fact interactively")
    cmd_edit.add_argument("fact", help="Name of the fact to edit")
    cmd_edit.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add the resulting fact file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_edit.set_defaults(func=handle_edit)

    cmd_list = subs.add_parser("list", help="List all facts")
    cmd_list.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show full paths, modified times, and tags",
    )
    cmd_list.add_argument(
        "--flat",
        action="store_true",
        help="Display facts as a flat list instead of a hierarchy",
    )
    cmd_list.add_argument(
        "-t",
        "--tag",
        action="append",
        dest="tags",
        help="Filter facts by tag. Can be specified multiple times.",
    )
    cmd_list.set_defaults(func=handle_list)

    show_parser = subs.add_parser("show", help="Show details of a fact")
    show_parser.add_argument("name", help="Name of the fact")
    show_parser.set_defaults(func=handle_show)
