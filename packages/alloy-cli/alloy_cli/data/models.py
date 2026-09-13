from dataclasses import dataclass


@dataclass
class FactRecord:
    name: str
    file: str
    tags: list[str]


@dataclass
class MasterSecretRecord:
    name: str
    file: str
    tags: list[str]


@dataclass
class HostSecretRecord:
    name: str
    host: str
    file: str


@dataclass
class JailSecretRecord:
    name: str
    jail: str
    file: str


@dataclass
class IdentityRecord:
    path: str


@dataclass
class RecipientRecord:
    key: str


@dataclass
class HostRecord:
    name: str
    recipients: list[RecipientRecord]


@dataclass
class JailRecord:
    name: str
    recipients: list[RecipientRecord]


@dataclass
class IndexRecord:
    name: str
    fact_name: str
    keys: list[str]
    min_value: int
    max_value: int


@dataclass
class GeneratorRecord:
    name: str
    script_path: str
    wants: list[str]
    wanted_by: list[str]
    before: list[str]
    after: list[str]
    tags: list[str]
    secrets: list[str]
    facts: list[str]
