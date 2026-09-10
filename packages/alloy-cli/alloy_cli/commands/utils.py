import os


def resolve_force(args_force: bool) -> bool:
    """Resolve --force flag, with ALLOY_FORCE=1 env var as fallback."""
    return args_force or os.environ.get("ALLOY_FORCE", "") == "1"


def resolve_add_to_git(args_add_to_git: bool) -> bool:
    """Resolve --add-to-git flag, with ALLOY_ADD_TO_GIT=1 env var as fallback."""
    return args_add_to_git or os.environ.get("ALLOY_ADD_TO_GIT", "") == "1"
