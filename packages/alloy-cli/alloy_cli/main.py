import os
import argparse
import json
from pathlib import Path

from .cli import CLI
from .commands import facts
from .commands import secrets
from .commands import indexes
from .commands import generators
from .commands import hosts
from .commands import jails
from .commands import overlays
from .commands import state as state_cmd


def load_state(cli: CLI) -> dict:
    state_file = os.environ.get("ALLOY_STATE_FILE")
    if not state_file:
        cli.abort("Missing state file. Provide ALLOY_STATE_FILE environment variable.")
    p = Path(str(state_file))
    if not p.exists():
        cli.abort(f"State file {p} does not exist.")
    with open(p, "r") as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(
        prog="alloy",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
environment variables:
  ALLOY_STATE_FILE    Path to the state JSON file (required).
  ALLOY_FORCE         Set to '1' to globally enable --force behavior across all commands.
  ALLOY_ADD_TO_GIT    Set to '1' to globally enable --add-to-git behavior across all commands.
""",
    )

    subparsers = parser.add_subparsers(
        title="commands", dest="command", required=True, metavar="COMMAND"
    )

    facts.register_parser(subparsers)
    secrets.register_parser(subparsers)
    indexes.register_parser(subparsers)
    generators.register_parser(subparsers)
    hosts.register_parser(subparsers)
    jails.register_parser(subparsers)
    overlays.register_parser(subparsers)
    state_cmd.register_parser(subparsers)

    args = parser.parse_args()

    cli = CLI()
    state = load_state(cli)

    from .di import Container

    container = Container(cli, state)

    if hasattr(args, "func"):
        args.func(args, cli, container)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
