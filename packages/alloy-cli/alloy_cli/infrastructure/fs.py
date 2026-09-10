from pathlib import Path

class FileSystemAdapter:
    def __init__(self, root: Path):
        self.root = root

    def write_text(self, rel_path: str, data: str):
        p = self.root / rel_path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)

    def write_bytes(self, rel_path: str, data: bytes):
        p = self.root / rel_path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def read_text(self, rel_path: str) -> str:
        return (self.root / rel_path).read_text()

    def read_bytes(self, rel_path: str) -> bytes:
        return (self.root / rel_path).read_bytes()

    def exists(self, rel_path: str) -> bool:
        return (self.root / rel_path).exists()
        
    def is_file(self, rel_path: str) -> bool:
        return (self.root / rel_path).is_file()
        
    def resolve(self, rel_path: str) -> Path:
        return self.root / rel_path
