import sys
from ..cli import CLI
from ..di import Container
from ..domain.exceptions import *
from .utils import resolve_force, resolve_add_to_git

def handle_set(args, cli: CLI, container: Container):
    service = container.facts_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    new_data = sys.stdin.read()
    cli.step(f"Writing fact '{cli.id(args.fact)}'...")
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

    cli.ok(f"Fact '{cli.id(args.fact)}' successfully written to {cli.path(cli.root / fact_file)}")

def handle_view(args, cli: CLI, container: Container):
    service = container.facts_service

    try:
        fact_value = service.get(args.fact)
    except FactNotDefinedError:
        cli.abort(f"Fact '{cli.id(args.fact)}' is not defined in the configuration.")
    except FactFileNotFoundError as e:
        cli.abort(f"File for fact '{cli.id(args.fact)}' does not exist at {cli.path(e.fact_file)}.")

    sys.stdout.write(fact_value)
    sys.stdout.flush()

def handle_edit(args, cli: CLI, container: Container):
    service = container.facts_service
    add_to_git = resolve_add_to_git(args.add_to_git)

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

def register_parser(subparsers):
    parser = subparsers.add_parser("facts", help="Manage generic cluster facts")
    subs = parser.add_subparsers(title="commands", dest="subcommand", required=True, metavar="COMMAND")

    cmd_set = subs.add_parser("set", help="Set a fact value from stdin")
    cmd_set.add_argument("fact", help="Name of the fact")
    cmd_set.add_argument(
        "-f", "--force",
        action="store_true",
        help="Force overwrite existing fact file. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_set.add_argument(
        "-a", "--add-to-git",
        action="store_true",
        help="Add file to git after writing. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_set.set_defaults(func=handle_set)

    cmd_view = subs.add_parser("view", help="View a fact value")
    cmd_view.add_argument("fact", help="Name of the fact")
    cmd_view.set_defaults(func=handle_view)

    cmd_edit = subs.add_parser("edit", help="Edit a fact interactively")
    cmd_edit.add_argument("fact", help="Name of the fact to edit")
    cmd_edit.add_argument(
        "-a", "--add-to-git",
        action="store_true",
        help="Add the resulting fact file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_edit.set_defaults(func=handle_edit)
