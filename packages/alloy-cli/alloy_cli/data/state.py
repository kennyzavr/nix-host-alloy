from typing import Dict, List, Optional
from .models import (
    FactRecord,
    MasterSecretRecord,
    HostSecretRecord,
    JailSecretRecord,
    IdentityRecord,
    RecipientRecord,
    HostRecord,
    JailRecord,
    IndexRecord,
    GeneratorRecord,
)


class FactsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_by_name(self, name: str) -> Optional[FactRecord]:
        for item in self._db.get("facts", []):
            if item.get("name") == name:
                return FactRecord(name=name, file=item.get("file", ""))
        return None


class MasterSecretsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_by_name(self, name: str) -> Optional[MasterSecretRecord]:
        for item in self._db.get("masterSecrets", []):
            if item.get("name") == name:
                return MasterSecretRecord(name=name, file=item.get("file", ""))
        return None

    def get_identities(self) -> List[IdentityRecord]:
        return [
            IdentityRecord(path=i) for i in self._db.get("masterSecretIdentities", [])
        ]

    def get_recipients(self) -> List[RecipientRecord]:
        return [
            RecipientRecord(key=r) for r in self._db.get("masterSecretRecipients", [])
        ]


class HostSecretsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[HostSecretRecord]:
        return [
            HostSecretRecord(
                name=item.get("name", ""),
                host=item.get("host", ""),
                master=item.get("master", ""),
                file=item.get("file", ""),
            )
            for item in self._db.get("hostSecrets", [])
        ]

    def find_by_host_and_name(
        self, host_name: str, secret_name: str
    ) -> Optional[HostSecretRecord]:
        for s in self.find_all():
            if s.host == host_name and s.name == secret_name:
                return s
        return None


class JailSecretsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[JailSecretRecord]:
        return [
            JailSecretRecord(
                name=item.get("name", ""),
                jail=item.get("jail", ""),
                master=item.get("master", ""),
                file=item.get("file", ""),
            )
            for item in self._db.get("jailSecrets", [])
        ]

    def find_by_jail_and_name(
        self, jail_name: str, secret_name: str
    ) -> Optional[JailSecretRecord]:
        for s in self.find_all():
            if s.jail == jail_name and s.name == secret_name:
                return s
        return None


class HostsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_by_name(self, name: str) -> Optional[HostRecord]:
        for item in self._db.get("hosts", []):
            if item.get("name") == name:
                recipients = [
                    RecipientRecord(key=r.get("value", ""))
                    for r in self._db.get("hostSecretRecipients", [])
                    if r.get("host") == name
                ]
                return HostRecord(name=name, recipients=recipients)
        return None


class JailsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_by_name(self, name: str) -> Optional[JailRecord]:
        for item in self._db.get("jails", []):
            if item.get("name") == name:
                recipients = [
                    RecipientRecord(key=r.get("value", ""))
                    for r in self._db.get("jailSecretRecipients", [])
                    if r.get("jail") == name
                ]
                return JailRecord(name=name, recipients=recipients)
        return None


class IndexesRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[IndexRecord]:
        return [
            IndexRecord(
                name=item.get("name", ""),
                fact_name=item.get("factName", ""),
                keys=item.get("keys", []),
                min_value=item.get("minValue", 1),
                max_value=item.get("maxValue", 999),
            )
            for item in self._db.get("indexes", [])
        ]

    def find_by_name(self, name: str) -> Optional[IndexRecord]:
        for idx in self.find_all():
            if idx.name == name:
                return idx
        return None


class GeneratorsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[GeneratorRecord]:
        return [
            GeneratorRecord(
                name=item.get("name", ""),
                script_path=item.get("bin", ""),
                wants=item.get("wants", []),
                wanted_by=item.get("wantedBy", []),
                before=item.get("before", []),
                after=item.get("after", []),
                tags=item.get("tags", []),
            )
            for item in self._db.get("generators", [])
        ]

    def find_by_name(self, name: str) -> Optional[GeneratorRecord]:
        for g in self.find_all():
            if g.name == name:
                return g
        return None
