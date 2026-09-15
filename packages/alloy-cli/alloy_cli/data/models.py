from dataclasses import dataclass
from typing import Optional


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
    tags: list[str]
    recipients: list[RecipientRecord]


@dataclass
class JailRecord:
    name: str
    host: str
    tags: list[str]
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


@dataclass
class OverlayLinkRecord:
    host_a: str
    host_b: str


@dataclass
class OverlayRecord:
    name: str
    ipv6Prefix: str
    tags: list[str]
    links: list[OverlayLinkRecord]


@dataclass
class HostOverlayRecord:
    name: str
    host: str
    ipv6: str


@dataclass
class JailOverlayRecord:
    name: str
    jail: str
    ipv6: str


@dataclass(frozen=True)
class QemuNetRecord:
    name: str
    idx: int


@dataclass
class QemuQuestNetRecord:
    net: str
    iface: str
    mac: str


@dataclass
class QemuPortForwardRecord:
    name: str
    proto: str
    host: int
    guest: int


@dataclass
class QemuQuestRecord:
    name: str
    tags: list[str]
    path: str
    nets: list[QemuQuestNetRecord]
    forward_ports: list[QemuPortForwardRecord]
    variant: Optional[str]
    variants: dict[str, str]
