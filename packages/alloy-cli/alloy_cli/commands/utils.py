import os


def resolve_force(args_force: bool) -> bool:
    """Resolve --force flag, with ALLOY_FORCE=1 env var as fallback."""
    return args_force or os.environ.get("ALLOY_FORCE", "") == "1"


def resolve_add_to_git(args_add_to_git: bool) -> bool:
    """Resolve --add-to-git flag, with ALLOY_ADD_TO_GIT=1 env var as fallback."""
    return args_add_to_git or os.environ.get("ALLOY_ADD_TO_GIT", "") == "1"


def ensure_indexes_consistency(cli, container):
    from ..domain.exceptions import (
        IndexStateCorruptedError,
        IndexNotDefinedError,
        IndexAllocationFailedError
    )
    try:
        container.indexes_service.check_all_consistency()
    except IndexStateCorruptedError as e:
        cli.abort(f"State for index '{cli.id(e.name)}' (fact '{cli.path(e.fact_name)}') is corrupted: {e.reason}\nPlease run 'alloy indexes allocate' to fix this.")
    except IndexNotDefinedError as e:
        cli.abort(f"Index '{cli.id(e.name)}' is not defined in the cluster state.\nPlease check your configuration.")
    except IndexAllocationFailedError as e:
        cli.abort(f"Allocation failed for '{cli.id(e.name)}': Need {e.needed} new slots, but not enough gaps in range [{e.min_val}, {e.max_val}].")
    except Exception as e:
        cli.abort(f"Unexpected error while checking indexes consistency: {getattr(e, 'error_msg', str(e))}")
