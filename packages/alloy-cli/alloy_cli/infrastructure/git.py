import subprocess
from pathlib import Path
from ..domain.exceptions import GitAddError

class GitAdapter:
    def __init__(self, root: Path):
        self.root = root

    def add(self, rel_path: str):
        p = self.root / rel_path
        res = subprocess.run(["git", "add", str(p)], capture_output=True, cwd=self.root)
        if res.returncode != 0:
            err = res.stderr.decode().strip()
            if "\n" in err:
                err = "\n  " + err.replace("\n", "\n  ")
            raise GitAddError(str(p), err)
