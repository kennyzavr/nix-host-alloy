import os
import sys
from pathlib import Path
from typing import Union, Optional, NoReturn
from rich.console import Console


class CLI:
    def __init__(self):
        self._root: Optional[Path] = None
        self._console = Console()
        self._err_console = Console(stderr=True)
        self._depth = int(os.environ.get("ALLOY_CLI_DEPTH", "0"))
        self.init()

    @property
    def root(self) -> Path:
        assert self._root is not None
        return self._root

    def init(self):
        root_env = os.environ.get("ALLOY_CLI_ROOT")
        if root_env:
            self._root = Path(root_env).resolve()
        else:
            _current = Path.cwd().resolve()
            while True:
                if (_current / "flake.nix").exists() or (_current / ".git").exists():
                    self._root = _current
                    break
                if _current.parent == _current:
                    break
                _current = _current.parent
            if not self._root:
                self.abort("Could not determine workspace root. No flake.nix or .git repository found.")
        os.environ["ALLOY_CLI_ROOT"] = str(self.root)
        os.chdir(self.root)

    def _indent(self) -> str:
        return "  " * self._depth

    def step(self, msg: str):
        if self._depth == 0:
            self._console.print(f"[bold blue]◆[/bold blue] {msg}")
        else:
            self._console.print(f"{self._indent()}[dim]›[/dim] {msg}")

    def ok(self, msg: str):
        self._console.print(f"{self._indent()}[bold green]✓[/bold green] {msg}")

    def skip(self, msg: str):
        self._console.print(f"{self._indent()}[dim]○[/dim] {msg}")

    def info(self, msg: str):
        self._console.print(f"{self._indent()}[dim cyan]·[/dim cyan] {msg}")

    def error(self, msg: str):
        self._err_console.print(f"{self._indent()}[bold red]✗[/bold red] {msg}")

    def abort(self, msg: str, code: int = 1) -> NoReturn:
        self.error(msg)
        sys.exit(code)

    def id(self, name: str) -> str:
        return f"[bold cyan]{name}[/bold cyan]"

    def path(self, p: Union[Path, str]) -> str:
        p_obj = Path(p).resolve() if Path(p).is_absolute() else Path(p)
        try:
            p_obj = p_obj.relative_to(self.root)
        except ValueError:
            pass
        return f"[yellow]{p_obj.as_posix()}[/yellow]"
