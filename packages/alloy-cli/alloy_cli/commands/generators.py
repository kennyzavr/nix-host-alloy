import argparse
from ..cli import CLI
from ..di import Container
from .utils import resolve_force, resolve_add_to_git, ensure_indexes_consistency

from ..domain.exceptions import GeneratorNotDefinedError, GeneratorCycleError, GeneratorExecutionError

def handle_run(args, cli: CLI, container: Container):
    service = container.generators_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)
    
    ensure_indexes_consistency(cli, container)

    try:
        plan = service.get_execution_plan(names=args.generator, tags=args.tag)
    except GeneratorNotDefinedError as e:
        cli.error(f"Generator '{cli.id(e.name)}' is not defined in the cluster state.")
        return
    except GeneratorCycleError as e:
        cli.error(f"A dependency cycle was detected in the generators graph: {e.error_msg}")
        return
    except Exception as e:
        cli.error(f"Unexpected error during plan generation: {getattr(e, 'error_msg', str(e))}")
        return

    if not plan:
        cli.skip("No generators to run.")
        return

    original_names = set(args.generator) if args.generator else set()

    for i, record in enumerate(plan):
        if i > 0:
            cli._console.print()
        cli.step(f"Running generator '{cli.id(record.name)}'...")
        # Apply force only if generator was explicitly requested by name
        should_force = force and (not args.generator or record.name in original_names)
        try:
            service.run_generator(record, force=should_force, add_to_git=add_to_git)
            cli.ok(f"Generator '{cli.id(record.name)}' finished successfully.")
        except GeneratorExecutionError as e:
            cli.error(f"Generator '{cli.id(e.name)}' failed with exit code {e.return_code}.")
        except Exception as e:
            cli.error(f"Unexpected error running generator '{cli.id(record.name)}': {getattr(e, 'error_msg', str(e))}")

def register_parser(subparsers):
    parser = subparsers.add_parser("generators", help="Run state generators")
    subcmds = parser.add_subparsers(title="commands", dest="cmd_generators", required=True, metavar="COMMAND")
    
    run_parser = subcmds.add_parser("run", help="Run generators and their dependencies")
    run_parser.add_argument("generator", nargs="*", help="Specific generators to run (default: all)")
    run_parser.add_argument("-t", "--tag", action="append", help="Filter generators by tag")
    run_parser.add_argument("-f", "--force", action="store_true", help="Pass ALLOY_FORCE=1 to generator scripts. Can also be enabled via ALLOY_FORCE=1 env var.")
    run_parser.add_argument("-a", "--add-to-git", action="store_true", help="Pass ALLOY_ADD_TO_GIT=1 to generator scripts. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.")
    run_parser.set_defaults(func=handle_run)
