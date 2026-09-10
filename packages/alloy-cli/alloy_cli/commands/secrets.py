import sys

from ..cli import CLI
from ..di import Container
from ..domain.exceptions import *
from .utils import resolve_force, resolve_add_to_git


def handle_set(args, cli: CLI, container: Container):
    service = container.secrets_service
    force = resolve_force(args.force)
    add_to_git = resolve_add_to_git(args.add_to_git)

    new_data = sys.stdin.buffer.read()
    try:
        cli.step(f"Encrypting and saving secret '{cli.id(args.secret)}'...")
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
        f"Secret '{cli.id(args.secret)}' successfully encrypted to {cli.path(cli.root / secret_file)}"
    )


def handle_view(args, cli: CLI, container: Container):
    service = container.secrets_service
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

    try:
        host_plan, jail_plan = service.get_rekey_plan(
            masters=args.secret, hosts=args.host, jails=args.jail
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


def register_parser(subparsers):
    parser = subparsers.add_parser("secrets", help="Manage age-encrypted cluster secrets")
    subs = parser.add_subparsers(title="commands", dest="subcommand", required=True, metavar="COMMAND")

    cmd_set = subs.add_parser("set", help="Encrypt and save a new master secret from stdin")
    cmd_set.add_argument("secret", help="Name of the master secret to create")
    cmd_set.add_argument(
        "-f", "--force",
        action="store_true",
        help="Overwrite if exists. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_set.add_argument(
        "-a", "--add-to-git",
        action="store_true",
        help="Add the resulting secret file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_set.set_defaults(func=handle_set)

    cmd_view = subs.add_parser("view", help="Decrypt and display a master secret")
    cmd_view.add_argument("secret", help="Name of the master secret to view")
    cmd_view.set_defaults(func=handle_view)

    cmd_edit = subs.add_parser("edit", help="Edit a master secret interactively")
    cmd_edit.add_argument("secret", help="Name of the master secret to edit")
    cmd_edit.add_argument(
        "-a", "--add-to-git",
        action="store_true",
        help="Add the resulting secret file to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_edit.set_defaults(func=handle_edit)

    cmd_rekey = subs.add_parser("rekey", help="Rekey master secrets for hosts and jails")
    cmd_rekey.add_argument("secret", nargs="*", help="Specific master secrets to rekey (default: all)")
    cmd_rekey.add_argument("--host", action="append", help="Filter by specific hosts")
    cmd_rekey.add_argument("--jail", action="append", help="Filter by specific jails")
    cmd_rekey.add_argument(
        "-f", "--force",
        action="store_true",
        help="Overwrite existing rekeyed secrets. Can also be enabled via ALLOY_FORCE=1 env var.",
    )
    cmd_rekey.add_argument(
        "-a", "--add-to-git",
        action="store_true",
        help="Add rekeyed secrets to git. Can also be enabled via ALLOY_ADD_TO_GIT=1 env var.",
    )
    cmd_rekey.set_defaults(func=handle_rekey)
