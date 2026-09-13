import os
import json
import argparse
from ..cli import CLI
from ..di import Container

def handle_show(args, cli: CLI, container: Container):
    if getattr(args, "filter", None) == "path":
        print(os.environ.get("ALLOY_STATE_FILE", ""))
        return

    if args.raw:
        print(json.dumps(container.db, separators=(',', ':')))
    else:
        from rich.syntax import Syntax
        formatted_json = json.dumps(container.db, indent=2, sort_keys=True)
        syntax = Syntax(formatted_json, "json", theme="ansi_dark", word_wrap=True)
        cli._console.print(syntax)

def register_parser(subparsers):
    parser = subparsers.add_parser("state", help="Inspect cluster state")
    subcmds = parser.add_subparsers(title="commands", dest="cmd_state", required=True, metavar="COMMAND")
    
    show_parser = subcmds.add_parser("show", help="Output the full cluster state JSON")
    show_parser.add_argument("filter", nargs="?", help="Optional filter (e.g., 'path' to print the state file path)")
    show_parser.add_argument("--raw", action="store_true", help="Print unformatted raw JSON output")
    show_parser.set_defaults(func=handle_show)
