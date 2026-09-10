from dataclasses import dataclass
from typing import List


@dataclass
class FactRecord:
    name: str
    file: str


@dataclass
class MasterSecretRecord:
    name: str
    file: str


@dataclass
class HostSecretRecord:
    name: str
    host: str
    master: str
    file: str


@dataclass
class JailSecretRecord:
    name: str
    jail: str
    master: str
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
    recipients: List[RecipientRecord]


@dataclass
class JailRecord:
    name: str
    recipients: List[RecipientRecord]


@dataclass
class IndexRecord:
    name: str
    fact_name: str
    keys: List[str]
    min_value: int
    max_value: int


@dataclass
class GeneratorRecord:
    name: str
    script_path: str
    wants: List[str]
    wanted_by: List[str]
    before: List[str]
    after: List[str]
    tags: List[str]
