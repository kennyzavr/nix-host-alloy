import os
import shlex
import hashlib
import tempfile
import atexit
import subprocess
from pathlib import Path
from typing import Optional

class EditorAdapter:
    def edit(self, data: Optional[str] = None) -> Optional[str]:
        def get_hash(p: Path) -> str:
            return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ""

        tmp_dir = "/dev/shm" if Path("/dev/shm").is_dir() else None
        fd, tmp_file_path = tempfile.mkstemp(dir=tmp_dir, text=True)
        os.close(fd)
        
        tmp_file = Path(tmp_file_path)
        atexit.register(lambda: tmp_file.unlink(missing_ok=True))
        
        if data is not None:
            tmp_file.write_bytes(data.encode("utf-8"))
            
        before_hash = get_hash(tmp_file)
        
        editor_env = os.environ.get("EDITOR", "nano")
        editor_cmd = shlex.split(editor_env)
        editor_name = Path(editor_cmd[0]).name
        
        if editor_name in ["vim", "nvim", "vi"]:
            editor_cmd.extend(["-n", "-c", "set nobackup noundofile"])
            
        editor_cmd.append(str(tmp_file))
        
        subprocess.run(editor_cmd, check=True)
        
        after_hash = get_hash(tmp_file)
        
        if before_hash == after_hash:
            return None
            
        if not tmp_file.exists() or tmp_file.stat().st_size == 0:
            raise ValueError("The file was left empty.")
            
        return tmp_file.read_text(encoding="utf-8")
