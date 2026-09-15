import sys

from ..cli import CLI
from ..di import Container
from ..domain.exceptions import *
from .utils import resolve_force, resolve_add_to_git, ensure_indexes_consistency


def handle_set(args, cli: CLI, container: Container):
    service = container.secrets_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    ensure_indexes_consistency(cli, container)

    new_data = sys.stdin.buffer.read()
    try:
        secret_file = service.set(
            args.secret, new_data, force=force, add_to_git=add_to_git
        )
    except NoMasterRecipientsDefinedError:
        cli.abort("No master recipients defined in workspace.secrets.age.keyPairs.")
    except MasterSecretNotDefinedError:
        cli.abort(
            f"Master secret '{cli.id(args.secret)}' is not defined in the configuration."
        )
    except MasterSecretFileAlreadyExistsError:
        cli.skip(
            f"Secret '{cli.id(args.secret)}' already exists. "
            f"Use --force to overwrite (or set ALLOY_FORCE=1)."
        )
        sys.exit(0)
    except (RageEncryptionError, RageDecryptionError, GitAddError) as e:
        cli.abort(
            f"Operation failed on '{cli.id(e.target)}': {getattr(e, 'error_msg', str(e))}"
        )
    cli.ok(
        f"Secret '{cli.id(args.secret)}' encrypted to {cli.path(cli.root / secret_file)}"
    )


def handle_get(args, cli: CLI, container: Container):
    service = container.secrets_service

    ensure_indexes_consistency(cli, container)
    try:
        decrypted = service.get(args.secret)
    except NoMasterIdentitiesDefinedError:
        cli.abort("No master identities defined in workspace.secrets.age.keyPairs.")
    except MasterSecretNotDefinedError:
        cli.abort(
            f"Master secret '{cli.id(args.secret)}' is not defined in the configuration."
        )
    except MasterSecretFileNotFoundError as e:
        cli.abort(
            f"File for master secret '{cli.id(args.secret)}' does not exist at {cli.path(e.master_secret_file)}."
        )
    except (RageEncryptionError, RageDecryptionError, GitAddError) as e:
        cli.abort(
            f"Operation failed on '{cli.id(e.target)}': {getattr(e, 'error_msg', str(e))}"
        )

    sys.stdout.buffer.write(decrypted)
    sys.stdout.buffer.flush()


def handle_edit(args, cli: CLI, container: Container):
    service = container.secrets_service
    add_to_git = resolve_add_to_git(args.add_to_git)

    ensure_indexes_consistency(cli, container)

    try:
        current_data = service.get(args.secret)
        current_data_str = current_data.decode("utf-8")
    except MasterSecretFileNotFoundError:
        current_data_str = None
        cli.step(f"Creating new secret '{cli.id(args.secret)}'...")
    except MasterSecretNotDefinedError:
        cli.abort(
            f"Master secret '{cli.id(args.secret)}' is not defined in the configuration."
        )
    except NoMasterIdentitiesDefinedError:
        cli.abort("No master identities defined in workspace.secrets.age.keyPairs.")
    except (RageEncryptionError, RageDecryptionError, GitAddError) as e:
        cli.abort(
            f"Operation failed on '{cli.id(e.target)}': {getattr(e, 'error_msg', str(e))}"
        )

    try:
        new_data = container.editor.edit(current_data_str)
    except ValueError:
        cli.abort("The file is empty. Aborting operation.")

    if new_data is None:
        cli.skip("No changes made, exiting.")
        sys.exit(0)

    try:
        service.set(
            args.secret,
            new_data.encode("utf-8") if isinstance(new_data, str) else new_data,
            force=True,
            add_to_git=add_to_git,
        )
    except NoMasterRecipientsDefinedError:
        cli.abort("No master recipients defined in workspace.secrets.age.keyPairs.")
    except (RageEncryptionError, RageDecryptionError, GitAddError) as e:
        cli.abort(
            f"Operation failed on '{cli.id(e.target)}': {getattr(e, 'error_msg', str(e))}"
        )

    cli.ok(f"Secret '{cli.id(args.secret)}' saved successfully.")


def handle_rekey(args, cli: CLI, container: Container):
    service = container.secrets_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    ensure_indexes_consistency(cli, container)

    try:
        host_plan, jail_plan = service.get_rekey_plan(
            masters=args.secret, hosts=args.host, jails=args.jail, tags=args.tag
        )
    except HostNotDefinedError as e:
        cli.error(
            f"Host '{cli.id(e.host_name)}' is not defined in the cluster configuration."
        )
        return
    except JailNotDefinedError as e:
        cli.error(
            f"Jail '{cli.id(e.jail_name)}' is not defined in the cluster configuration."
        )
        return
    except Exception as e:
        cli.error(
            f"Unexpected error during plan generation: {getattr(e, 'error_msg', str(e))}"
        )
        return

    for h_sec in host_plan:
        try:
            service.rekey_host_secret(h_sec.host, h_sec.name, force, add_to_git)
            cli.ok(f"Rekeyed host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}'")
        except HostSecretFileAlreadyExistsError:
            cli.skip(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': "
                f"Already exists. Use --force to overwrite (or set ALLOY_FORCE=1)."
            )
        except NoMasterIdentitiesDefinedError:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': No master identities defined."
            )
        except NoHostRecipientsDefinedError:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': No host recipients defined."
            )
        except HostSecretNotDefinedError:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': Host secret not defined."
            )
        except MasterSecretNotDefinedError as e:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': "
                f"Master secret '{cli.id(e.master_secret_name)}' not defined."
            )
        except MasterSecretFileNotFoundError as e:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': "
                f"Master file '{cli.path(e.master_secret_file)}' not found."
            )
        except Exception as e:
            cli.error(
                f"Host '{cli.id(h_sec.host)}' secret '{cli.id(h_sec.name)}': "
                f"{getattr(e, 'error_msg', str(e))}"
            )

    for j_sec in jail_plan:
        try:
            service.rekey_jail_secret(j_sec.jail, j_sec.name, force, add_to_git)
            cli.ok(f"Rekeyed jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}'")
        except JailSecretFileAlreadyExistsError:
            cli.skip(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': "
                f"Already exists. Use --force to overwrite (or set ALLOY_FORCE=1)."
            )
        except NoMasterIdentitiesDefinedError:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': No master identities defined."
            )
        except NoJailRecipientsDefinedError:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': No jail recipients defined."
            )
        except JailSecretNotDefinedError:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': Jail secret not defined."
            )
        except MasterSecretNotDefinedError as e:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': "
                f"Master secret '{cli.id(e.master_secret_name)}' not defined."
            )
        except MasterSecretFileNotFoundError as e:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': "
                f"Master file '{cli.path(e.master_secret_file)}' not found."
            )
        except Exception as e:
            cli.error(
                f"Jail '{cli.id(j_sec.jail)}' secret '{cli.id(j_sec.name)}': "
                f"{getattr(e, 'error_msg', str(e))}"
            )


def handle_list(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    service = container.secrets_service

    verbose = args.verbose
    hosts_filter = args.host or []
    jails_filter = args.jail or []
    tags_filter = args.tag or []

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

    def render_target_leaf(node, key, master, target_type, target_name):
        if target_type == "host":
            secret = service.host_secrets.find_by_host_and_name(
                target_name, master.name
            )
        else:
            secret = service.jail_secrets.find_by_jail_and_name(
                target_name, master.name
            )

        if secret:
            status = get_status_str(secret.file)
            leaf = node.add(f"[bold cyan]{key}[/bold cyan]  ({status})")
            if verbose:
                leaf.add(f"[dim]Path:[/dim] {cli.path(secret.file)}")

    def render_global_leaf(node, key, master):
        status = get_status_str(master.file)
        leaf = node.add(f"[bold cyan]{key}[/bold cyan]  ({status})")
        if verbose:
            if master.tags:
                leaf.add(f"[dim]Tags:[/dim] {', '.join(master.tags)}")
            leaf.add(f"[dim]Path:[/dim] {cli.path(master.file)}")

        targets_node = leaf.add("[bold]Targets:[/bold]")

        host_secrets = [
            s for s in service.host_secrets.find_all() if s.name == master.name
        ]
        jail_secrets = [
            s for s in service.jail_secrets.find_all() if s.name == master.name
        ]

        if not host_secrets and not jail_secrets:
            targets_node.add("[dim]No targets[/dim]")
        else:
            for hs in sorted(host_secrets, key=lambda s: s.host):
                hs_status = get_status_str(hs.file)
                hs_node = targets_node.add(
                    f"Host: [cyan]{hs.host}[/cyan] ({hs_status})"
                )
                if verbose:
                    hs_node.add(f"[dim]Path:[/dim] {cli.path(hs.file)}")
            for js in sorted(jail_secrets, key=lambda s: s.jail):
                js_status = get_status_str(js.file)
                js_node = targets_node.add(
                    f"Jail: [cyan]{js.jail}[/cyan] ({js_status})"
                )
                if verbose:
                    js_node.add(f"[dim]Path:[/dim] {cli.path(js.file)}")

    all_masters = service.master.find_all()
    if tags_filter:
        all_masters = [m for m in all_masters if any(t in tags_filter for t in m.tags)]

    if not all_masters:
        cli.info("No secrets match the criteria.")
        return

    if hosts_filter or jails_filter:
        for h in hosts_filter:
            tree = Tree(f"Host: [bold]{h}[/bold] (Secrets)", guide_style="dim")
            h_secrets = [s for s in service.host_secrets.find_all() if s.host == h]
            h_masters = [
                m for m in all_masters if any(hs.name == m.name for hs in h_secrets)
            ]
            if not h_masters:
                tree.add("[dim]No secrets[/dim]")
            else:
                render_tree_view(
                    tree,
                    h_masters,
                    lambda m: m.name,
                    lambda n, k, m: render_target_leaf(n, k, m, "host", h),
                    flat=args.flat,
                )
            cli.console.print(tree)
            cli.console.print("")

        for j in jails_filter:
            tree = Tree(f"Jail: [bold]{j}[/bold] (Secrets)", guide_style="dim")
            j_secrets = [s for s in service.jail_secrets.find_all() if s.jail == j]
            j_masters = [
                m for m in all_masters if any(js.name == m.name for js in j_secrets)
            ]
            if not j_masters:
                tree.add("[dim]No secrets[/dim]")
            else:
                render_tree_view(
                    tree,
                    j_masters,
                    lambda m: m.name,
                    lambda n, k, m: render_target_leaf(n, k, m, "jail", j),
                    flat=args.flat,
                )
            cli.console.print(tree)
            cli.console.print("")
    else:
        tree = Tree("[bold]Master Secrets[/bold]", guide_style="dim")
        render_tree_view(
            tree, all_masters, lambda m: m.name, render_global_leaf, flat=args.flat
        )
        cli.console.print(tree)

    if hosts_filter or jails_filter:
        printed_hosts = set()
        printed_jails = set()
        printed_masters = set()

        for h in hosts_filter:
            h_secrets = [s for s in service.host_secrets.find_all() if s.host == h]
            h_masters = [
                m for m in all_masters if any(hs.name == m.name for hs in h_secrets)
            ]
            if h_masters:
                printed_hosts.add(h)
                printed_masters.update(m.name for m in h_masters)

        for j in jails_filter:
            j_secrets = [s for s in service.jail_secrets.find_all() if s.jail == j]
            j_masters = [
                m for m in all_masters if any(js.name == m.name for js in j_secrets)
            ]
            if j_masters:
                printed_jails.add(j)
                printed_masters.update(m.name for m in j_masters)

        total_masters = len(printed_masters)
        total_hosts = len(printed_hosts)
        total_jails = len(printed_jails)
    else:
        total_masters = len(all_masters)
        master_names = {m.name for m in all_masters}
        total_hosts = len(
            set(
                s.host
                for s in service.host_secrets.find_all()
                if s.name in master_names
            )
        )
        total_jails = len(
            set(
                s.jail
                for s in service.jail_secrets.find_all()
                if s.name in master_names
            )
        )

    cli.console.print(
        f"──────────────────────────\n[dim]Total: {total_masters} master secrets | {total_hosts} hosts targets | {total_jails} jail targets[/dim]"
    )


def handle_show(args, cli: CLI, container: Container):
    ensure_indexes_consistency(cli, container)
    service = container.secrets_service
    record = service.master.find_by_name(args.name)
    if not record:
        cli.error(f"Secret '{args.name}' not found.")
        return

    from rich.panel import Panel
    from rich.console import Group
    from rich.text import Text
    import os

    def get_status(file_path):
        if container.fs.exists(file_path):
            stat = os.stat(container.fs.resolve(file_path))
            from datetime import datetime

            mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            return f"✅ Present (Modified: {mtime})"
        return "❌ Missing"

    content = []
    content.append(Text.from_markup(f"Path: {cli.path(record.file)}"))
    content.append(Text(f"Status: {get_status(record.file)}"))
    content.append(Text(f"Tags: {', '.join(record.tags) if record.tags else '-'}"))

    host_targets = [s for s in service.host_secrets.find_all() if s.name == record.name]
    jail_targets = [s for s in service.jail_secrets.find_all() if s.name == record.name]

    if not host_targets and not jail_targets:
        content.append(Text("\nTargets: None", style="dim"))
    else:
        content.append(Text("\nTargets:", style="bold"))
        for hs in sorted(host_targets, key=lambda s: s.host):
            content.append(Text(f"  [Host] {hs.host}: {get_status(hs.file)}"))
        for js in sorted(jail_targets, key=lambda s: s.jail):
            content.append(Text(f"  [Jail] {js.jail}: {get_status(js.file)}"))

    cli.console.print(
        Panel(
            Group(*content), title=f"Secret: [bold]{record.name}[/bold]", expand=False
        )
    )


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "secrets", help="Manage age-encrypted cluster secrets"
    )
    subs = parser.add_subparsers(
        title="commands", dest="subcommand", required=True, metavar="COMMAND"
    )

    cmd_set = subs.add_parser(
        "set", help="Encrypt and save a new master secret from stdin"
    )
    cmd_set.add_argument("secret", help="Name of the master secret to create")
    cmd_set.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Overwrite if exists. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_set.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add the resulting secret file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_set.set_defaults(func=handle_set)

    cmd_get = subs.add_parser(
        "get", help="Decrypt and output a master secret to stdout"
    )
    cmd_get.add_argument("secret", help="Name of the master secret to output")
    cmd_get.set_defaults(func=handle_get)

    cmd_edit = subs.add_parser("edit", help="Edit a master secret interactively")
    cmd_edit.add_argument("secret", help="Name of the master secret to edit")
    cmd_edit.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add the resulting secret file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_edit.set_defaults(func=handle_edit)

    cmd_rekey = subs.add_parser(
        "rekey", help="Rekey master secrets for hosts and jails"
    )
    cmd_rekey.add_argument(
        "secret", nargs="*", help="Specific master secrets to rekey (default: all)"
    )
    cmd_rekey.add_argument("--host", action="append", help="Filter by specific hosts")
    cmd_rekey.add_argument("--jail", action="append", help="Filter by specific jails")
    cmd_rekey.add_argument("--tag", action="append", help="Filter by specific tags")
    cmd_rekey.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Overwrite existing rekeyed secrets. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_rekey.add_argument(
        "-a",
        "--add-to-git",
        action="store_true",
        help="Add rekeyed secrets to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_rekey.set_defaults(func=handle_rekey)

    cmd_list = subs.add_parser("list", help="List all secrets")
    cmd_list.add_argument(
        "--host",
        action="append",
        help="Filter by specific hosts and switch to target view",
    )
    cmd_list.add_argument(
        "--jail",
        action="append",
        help="Filter by specific jails and switch to target view",
    )
    cmd_list.add_argument(
        "--tag", action="append", help="Filter master secrets by specific tags"
    )
    cmd_list.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show full paths, modified times, and tags",
    )
    cmd_list.add_argument(
        "--flat",
        action="store_true",
        help="Display secrets as a flat list instead of a hierarchy",
    )
    cmd_list.set_defaults(func=handle_list)

    show_parser = subs.add_parser("show", help="Show details of a secret")
    show_parser.add_argument("name", help="Name of the secret")
    show_parser.set_defaults(func=handle_show)
