from .exceptions import (
    FactNotDefinedError,
    FactFileAlreadyExistsError,
    FactFileNotFoundError,
)
from ..data.state import FactsRepository
from ..infrastructure.fs import FileSystemAdapter
from ..infrastructure.git import GitAdapter


class FactsService:
    def __init__(self, repo: FactsRepository, fs: FileSystemAdapter, git: GitAdapter):
        self.repo = repo
        self.fs = fs
        self.git = git

    def set(
        self, name: str, data: str, force: bool = False, add_to_git: bool = False
    ) -> str:
        entry = self.repo.find_by_name(name)
        if not entry:
            raise FactNotDefinedError(name)

        rel_path = entry.file
        if self.fs.exists(rel_path) and not force:
            raise FactFileAlreadyExistsError(name, self.fs.resolve(rel_path))

        self.fs.write_text(rel_path, data)

        if add_to_git:
            self.git.add(rel_path)

        return rel_path

    def get_file_path(self, name: str) -> str:
        entry = self.repo.find_by_name(name)
        if not entry:
            raise FactNotDefinedError(name)
        return entry.file

    def get(self, name: str) -> str:
        entry = self.repo.find_by_name(name)
        if not entry:
            raise FactNotDefinedError(name)

        rel_path = entry.file
        if not self.fs.is_file(rel_path):
            raise FactFileNotFoundError(name, self.fs.resolve(rel_path))

        return self.fs.read_text(rel_path)
