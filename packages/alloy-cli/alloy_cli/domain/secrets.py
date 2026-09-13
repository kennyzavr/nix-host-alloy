from typing import Tuple, List, Optional
from .exceptions import *
from ..data.state import (
    MasterSecretsRepository,
    HostSecretsRepository,
    JailSecretsRepository,
    HostsRepository,
    JailsRepository,
)
from ..data.models import HostSecretRecord, JailSecretRecord
from ..infrastructure.fs import FileSystemAdapter
from ..infrastructure.git import GitAdapter
from ..infrastructure.crypto import RageAdapter


class SecretsService:
    def __init__(
        self,
        master_repo: MasterSecretsRepository,
        host_secrets_repo: HostSecretsRepository,
        jail_secrets_repo: JailSecretsRepository,
        hosts_repo: HostsRepository,
        jails_repo: JailsRepository,
        fs: FileSystemAdapter,
        git: GitAdapter,
        rage: RageAdapter,
    ):
        self.master = master_repo
        self.host_secrets = host_secrets_repo
        self.jail_secrets = jail_secrets_repo
        self.hosts = hosts_repo
        self.jails = jails_repo
        self.fs = fs
        self.git = git
        self.rage = rage

    def set(
        self, name: str, data: bytes, force: bool = False, add_to_git: bool = False
    ) -> str:
        recipients = self.master.get_recipients()
        if not recipients:
            raise NoMasterRecipientsDefinedError()

        rel_path = self.get_file_path(name)
        if self.fs.exists(rel_path) and not force:
            raise MasterSecretFileAlreadyExistsError(name, self.fs.resolve(rel_path))

        recipient_keys = [r.key for r in recipients]
        self.rage.encrypt(data, recipient_keys, rel_path)

        if add_to_git:
            self.git.add(rel_path)

        return rel_path

    def get_file_path(self, name: str) -> str:
        data = self.master.find_by_name(name)
        if not data:
            raise MasterSecretNotDefinedError(name)
        return data.file

    def get(self, name: str) -> bytes:
        identities = self.master.get_identities()
        if not identities:
            raise NoMasterIdentitiesDefinedError()

        rel_path = self.get_file_path(name)
        if not self.fs.is_file(rel_path):
            raise MasterSecretFileNotFoundError(name, self.fs.resolve(rel_path))

        identity_paths = [i.path for i in identities]
        return self.rage.decrypt(rel_path, identity_paths)

    def get_rekey_plan(
        self,
        masters: Optional[List[str]] = None,
        hosts: Optional[List[str]] = None,
        jails: Optional[List[str]] = None,
        tags: Optional[List[str]] = None,
    ) -> Tuple[List[HostSecretRecord], List[JailSecretRecord]]:
        if hosts:
            for h in hosts:
                if not self.hosts.find_by_name(h):
                    raise HostNotDefinedError(h)

        if jails:
            for j in jails:
                if not self.jails.find_by_name(j):
                    raise JailNotDefinedError(j)

        host_plan = []
        jail_plan = []

        process_hosts = True
        process_jails = True

        if hosts and not jails:
            process_jails = False
        elif jails and not hosts:
            process_hosts = False

        if process_hosts:
            for h_sec in self.host_secrets.find_all():
                if masters and h_sec.name not in masters:
                    continue
                if hosts and h_sec.host not in hosts:
                    continue

                master = self.master.find_by_name(h_sec.name)
                if master and tags and all(tag not in tags for tag in master.tags):
                    continue

                host_plan.append(h_sec)

        if process_jails:
            for j_sec in self.jail_secrets.find_all():
                if masters and j_sec.name not in masters:
                    continue
                if jails and j_sec.jail not in jails:
                    continue

                master = self.master.find_by_name(j_sec.name)
                if master and tags and all(tag not in tags for tag in master.tags):
                    continue

                jail_plan.append(j_sec)

        return host_plan, jail_plan

    def rekey_host_secret(
        self,
        host_name: str,
        host_secret_name: str,
        force: bool = False,
        add_to_git: bool = False,
    ):
        host_record = self.hosts.find_by_name(host_name)
        if not host_record:
            raise HostNotDefinedError(host_name)

        host_secret = self.host_secrets.find_by_host_and_name(
            host_name, host_secret_name
        )
        if not host_secret:
            raise HostSecretNotDefinedError(host_secret_name)

        rel_out_path = host_secret.file
        master_secret = self.master.find_by_name(host_secret.name)
        master_identities = self.master.get_identities()
        host_recipients = host_record.recipients

        if not master_identities:
            raise NoMasterIdentitiesDefinedError()

        if not host_recipients:
            raise NoHostRecipientsDefinedError(host_name)

        if not master_secret:
            raise MasterSecretNotDefinedError(host_secret.name)

        master_secret_name = host_secret.name
        rel_in_path = master_secret.file

        if not self.fs.exists(rel_in_path):
            raise MasterSecretFileNotFoundError(
                master_secret_name, self.fs.resolve(rel_in_path)
            )

        if self.fs.exists(rel_out_path) and not force:
            raise HostSecretFileAlreadyExistsError(
                host_secret_name, self.fs.resolve(rel_out_path), host_name
            )

        identity_paths = [i.path for i in master_identities]
        recipient_keys = [r.key for r in host_recipients]
        self.rage.rekey(rel_in_path, rel_out_path, identity_paths, recipient_keys)

        if add_to_git:
            self.git.add(rel_out_path)

    def rekey_jail_secret(
        self,
        jail_name: str,
        jail_secret_name: str,
        force: bool = False,
        add_to_git: bool = False,
    ):
        jail_record = self.jails.find_by_name(jail_name)
        if not jail_record:
            raise JailNotDefinedError(jail_name)

        jail_secret = self.jail_secrets.find_by_jail_and_name(
            jail_name, jail_secret_name
        )
        if not jail_secret:
            raise JailSecretNotDefinedError(jail_secret_name)

        rel_out_path = jail_secret.file
        master_secret = self.master.find_by_name(jail_secret.name)
        master_identities = self.master.get_identities()
        jail_recipients = jail_record.recipients

        if not master_identities:
            raise NoMasterIdentitiesDefinedError()

        if not jail_recipients:
            raise NoJailRecipientsDefinedError(jail_name)

        if not master_secret:
            raise MasterSecretNotDefinedError(jail_secret.name)

        master_secret_name = master_secret.name
        rel_in_path = master_secret.file

        if not self.fs.exists(rel_in_path):
            raise MasterSecretFileNotFoundError(
                master_secret_name, self.fs.resolve(rel_in_path)
            )

        if self.fs.exists(rel_out_path) and not force:
            raise JailSecretFileAlreadyExistsError(
                jail_secret_name, self.fs.resolve(rel_out_path), jail_name
            )

        identity_paths = [i.path for i in master_identities]
        recipient_keys = [r.key for r in jail_recipients]
        self.rage.rekey(rel_in_path, rel_out_path, identity_paths, recipient_keys)

        if add_to_git:
            self.git.add(rel_out_path)
