from functools import lru_cache
from .cli import CLI
from .data.state import (
    FactsRepository, MasterSecretsRepository, 
    HostSecretsRepository, JailSecretsRepository, 
    HostsRepository, JailsRepository, IndexesRepository,
    GeneratorsRepository
)
from .infrastructure.fs import FileSystemAdapter
from .infrastructure.git import GitAdapter
from .infrastructure.crypto import RageAdapter
from .infrastructure.editor import EditorAdapter
from .infrastructure.script_runner import ScriptRunnerAdapter
from .domain.facts import FactsService
from .domain.secrets import SecretsService
from .domain.indexes import IndexesService
from .domain.generators import GeneratorsService

class Container:
    def __init__(self, cli: CLI, db: dict):
        self.cli = cli
        self.db = db

    @property
    @lru_cache(maxsize=1)
    def editor(self) -> EditorAdapter:
        return EditorAdapter()

    @property
    @lru_cache(maxsize=1)
    def fs(self) -> FileSystemAdapter:
        return FileSystemAdapter(self.cli.root)

    @property
    @lru_cache(maxsize=1)
    def git(self) -> GitAdapter:
        return GitAdapter(self.cli.root)

    @property
    @lru_cache(maxsize=1)
    def rage(self) -> RageAdapter:
        return RageAdapter(self.cli.root)

    @property
    @lru_cache(maxsize=1)
    def facts_service(self) -> FactsService:
        return FactsService(FactsRepository(self.db), self.fs, self.git)

    @property
    @lru_cache(maxsize=1)
    def master_secrets_repo(self) -> MasterSecretsRepository:
        return MasterSecretsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def host_secrets_repo(self) -> HostSecretsRepository:
        return HostSecretsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def jail_secrets_repo(self) -> JailSecretsRepository:
        return JailSecretsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def hosts_repo(self) -> HostsRepository:
        return HostsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def jails_repo(self) -> JailsRepository:
        return JailsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def secrets_service(self) -> SecretsService:
        return SecretsService(
            master_repo=self.master_secrets_repo,
            host_secrets_repo=self.host_secrets_repo,
            jail_secrets_repo=self.jail_secrets_repo,
            hosts_repo=self.hosts_repo,
            jails_repo=self.jails_repo,
            fs=self.fs,
            git=self.git,
            rage=self.rage
        )

    @property
    @lru_cache(maxsize=1)
    def indexes_repo(self) -> IndexesRepository:
        return IndexesRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def indexes_service(self) -> IndexesService:
        return IndexesService(
            indexes_repo=self.indexes_repo,
            facts_service=self.facts_service
        )

    @property
    @lru_cache(maxsize=1)
    def generators_repo(self) -> GeneratorsRepository:
        return GeneratorsRepository(self.db)

    @property
    @lru_cache(maxsize=1)
    def script_runner(self) -> ScriptRunnerAdapter:
        return ScriptRunnerAdapter()

    @property
    @lru_cache(maxsize=1)
    def generators_service(self) -> GeneratorsService:
        return GeneratorsService(
            generators_repo=self.generators_repo,
            script_runner=self.script_runner
        )
