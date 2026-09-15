import argparse
from ..cli import CLI
from ..di import Container
from .utils import resolve_force, resolve_add_to_git, ensure_indexes_consistency

from ..domain.exceptions import (
    GeneratorNotDefinedError,
    GeneratorCycleError,
    GeneratorExecutionError,
)


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
        cli.error(
            f"A dependency cycle was detected in the generators graph: {e.error_msg}"
        )
        return
    except Exception as e:
        cli.error(
            f"Unexpected error during plan generation: {getattr(e, 'error_msg', str(e))}"
        )
        return

    if not plan:
        cli.skip("No generators to run.")
        return

    original_names = set(args.generator) if args.generator else set()

    secrets_service = container.secrets_service
    facts_service = container.facts_service

    import os

    original_depth = os.environ.get("ALLOY_CLI_DEPTH", "0")

    for i, record in enumerate(plan):
        should_force = force and (not args.generator or record.name in original_names)

        all_present = True
        has_outputs = bool(record.secrets or record.facts)

        if has_outputs:
            for s_name in record.secrets:
                s_rec = secrets_service.master.find_by_name(s_name)
                if not s_rec or not container.fs.exists(s_rec.file):
                    all_present = False
                    break

            if all_present:
                for f_name in record.facts:
                    f_rec = facts_service.repo.find_by_name(f_name)
                    if not f_rec or not container.fs.exists(f_rec.file):
                        all_present = False
                        break
        else:
            all_present = False

        if all_present and not should_force:
            cli.skip(f"⚙️  Generator '{cli.id(record.name)}' [dim](up to date)[/dim]")
            continue

        cli.step(f"⚙️  Generator '{cli.id(record.name)}'")

        try:
            os.environ["ALLOY_CLI_DEPTH"] = str(cli._depth + 1)
            service.run_generator(record, force=should_force, add_to_git=add_to_git)
        except GeneratorExecutionError as e:
            cli.error(
                f"Generator '{cli.id(e.name)}' failed with exit code {e.return_code}."
            )
        except Exception as e:
            cli.error(
                f"Unexpected error running generator '{cli.id(record.name)}': {getattr(e, 'error_msg', str(e))}"
            )
        finally:
            os.environ["ALLOY_CLI_DEPTH"] = original_depth

def handle_list(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    service = container.generators_service
    secrets_service = container.secrets_service
    facts_service = container.facts_service
    
    verbose = args.verbose
    tags_filter = args.tag or []
    
    all_gens = service.repo.find_all()
    if tags_filter:
        all_gens = [g for g in all_gens if any(t in tags_filter for t in g.tags)]

    if not all_gens:
        cli.info("No generators match the criteria.")
        return

    from rich.tree import Tree
    from datetime import datetime
    import os
    from .views import render_tree_view

    def get_status_str(file_path):
        if container.fs.exists(file_path):
            if verbose:
                stat = os.stat(container.fs.resolve(file_path))
                mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
                return f"✅ Present [dim](Modified: {mtime})[/dim]"
            return "✅ Present"
        return "❌ Missing"

    def render_leaf(node, key, gen):
        leaf = node.add(f"[bold cyan]{key}[/bold cyan]")
        
        if verbose and gen.tags:
            leaf.add(f"[dim]Tags:[/dim] {', '.join(gen.tags)}")
            
        has_outputs = False
        if gen.secrets:
            has_outputs = True
            for s_name in sorted(gen.secrets):
                s_rec = secrets_service.master.find_by_name(s_name)
                status = get_status_str(s_rec.file) if s_rec else "❌ Not defined in state"
                
                display_name = s_name
                prefix = gen.name + "/"
                if s_name.startswith(prefix):
                    display_name = s_name[len(prefix):]
                elif s_name == gen.name:
                    display_name = ".(self)"
                    
                s_node = leaf.add(f"🔑 Secret: [cyan]{display_name}[/cyan] ({status})")
                if verbose and s_rec:
                    s_node.add(f"[dim]Path:[/dim] {cli.path(s_rec.file)}")
                    
        if gen.facts:
            has_outputs = True
            for f_name in sorted(gen.facts):
                f_rec = facts_service.repo.find_by_name(f_name)
                status = get_status_str(f_rec.file) if f_rec else "❌ Not defined in state"
                
                display_name = f_name
                prefix = gen.name + "/"
                if f_name.startswith(prefix):
                    display_name = f_name[len(prefix):]
                elif f_name == gen.name:
                    display_name = ".(self)"
                    
                f_node = leaf.add(f"📌 Fact: [cyan]{display_name}[/cyan] ({status})")
                if verbose and f_rec:
                    f_node.add(f"[dim]Path:[/dim] {cli.path(f_rec.file)}")
                    
        if not has_outputs:
            leaf.add("[dim]No secrets or facts declared[/dim]")

    tree = Tree("[bold]Generators[/bold]", guide_style="dim")
    render_tree_view(tree, all_gens, lambda g: g.name, render_leaf, flat=args.flat)
    cli.console.print(tree)
    
    cli.console.print(f"──────────────────────────\n[dim]Total: {len(all_gens)} generators[/dim]")


def handle_show(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    record = container.generators_service.repo.find_by_name(args.name)
    if not record:
        cli.error(f"Generator '{args.name}' not found.")
        return

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text
    
    content = []
    content.append(Text(f"Script: {record.script_path}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))
    
    if record.wants:
        content.append(Text(f"Wants: {', '.join(record.wants)}"))
    if record.wanted_by:
        content.append(Text(f"Wanted By: {', '.join(record.wanted_by)}"))
    if record.before:
        content.append(Text(f"Before: {', '.join(record.before)}"))
    if record.after:
        content.append(Text(f"After: {', '.join(record.after)}"))
        
    if record.secrets:
        content.append(Text("\nGenerated Secrets:", style="bold"))
        for s in record.secrets:
            content.append(Text(f"  - {s}"))
    if record.facts:
        content.append(Text("\nGenerated Facts:", style="bold"))
        for f in record.facts:
            content.append(Text(f"  - {f}"))

    cli.console.print(Panel(Group(*content), title=f"Generator: [bold]{record.name}[/bold]", expand=False))


def register_parser(subparsers):
    parser = subparsers.add_parser("generators", help="Run state generators")
    subcmds = parser.add_subparsers(
        title="commands", dest="cmd_generators", required=True, metavar="COMMAND"
    )

    run_parser = subcmds.add_parser("run", help="Run generators and their dependencies")
    run_parser.add_argument(
        "generator", nargs="*", help="Specific generators to run (default: all)"
    )
    run_parser.add_argument(
        "-t", "--tag", action="append", help="Filter generators by tag"
    )
    run_parser.add_argument("-f", "--force", action="store_true", help="Pass ALLOY_FORCE=1 to generator scripts. Can also be enabled via ALLOY_FORCE=1 env var.")
    run_parser.add_argument("-a", "--add-to-git", action="store_true", help="Pass ALLOY_ADD_TO_GIT=1 to generator scripts. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.")
    run_parser.set_defaults(func=handle_run)
    
    list_parser = subcmds.add_parser("list", help="List all generators and their outputs")
    list_parser.add_argument("-t", "--tag", action="append", help="Filter generators by tag")
    list_parser.add_argument("-v", "--verbose", action="store_true", help="Show full paths, modified times, and tags")
    list_parser.add_argument("--flat", action="store_true", help="Display generators as a flat list instead of a hierarchy")
    list_parser.set_defaults(func=handle_list)

    show_parser = subcmds.add_parser("show", help="Show details of a generator")
    show_parser.add_argument("name", help="Name of the generator")
    show_parser.set_defaults(func=handle_show)
