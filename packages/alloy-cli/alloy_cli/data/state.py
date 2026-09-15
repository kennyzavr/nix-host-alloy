from typing import Dict, List, Optional
from .models import (
    FactRecord,
    MasterSecretRecord,
    HostSecretRecord,
    JailSecretRecord,
    IdentityRecord,
    QemuNetRecord,
    RecipientRecord,
    HostRecord,
    JailRecord,
    IndexRecord,
    GeneratorRecord,
    OverlayRecord,
    HostOverlayRecord,
    JailOverlayRecord,
    QemuQuestRecord,
    QemuPortForwardRecord,
)


class FactsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[FactRecord]:
        return [
            FactRecord(
                name=item.get("name", ""),
                file=item.get("file", ""),
                tags=item.get("tags", []),
            )
            for item in self._db.get("facts", [])
        ]

    def find_by_name(self, name: str) -> Optional[FactRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
        return None


class MasterSecretsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[MasterSecretRecord]:
        return [
            MasterSecretRecord(
                name=item.get("name", ""),
                file=item.get("file", ""),
                tags=item.get("tags", []),
            )
            for item in self._db.get("masterSecrets", [])
        ]

    def find_by_name(self, name: str) -> Optional[MasterSecretRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
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

    def find_all(self) -> List[HostRecord]:
        res = []
        for item in self._db.get("hosts", []):
            name = item.get("name")
            recipients = [
                RecipientRecord(key=r.get("value", ""))
                for r in self._db.get("hostSecretRecipients", [])
                if r.get("host") == name
            ]
            res.append(
                HostRecord(
                    name=name,
                    tags=item.get("tags", []),
                    recipients=recipients,
                )
            )
        return res

    def find_by_name(self, name: str) -> Optional[HostRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
        return None


class JailsRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[JailRecord]:
        res = []
        for item in self._db.get("jails", []):
            name = item.get("name")
            recipients = [
                RecipientRecord(key=r.get("value", ""))
                for r in self._db.get("jailSecretRecipients", [])
                if r.get("jail") == name
            ]
            res.append(
                JailRecord(
                    name=name,
                    host=item.get("host", ""),
                    tags=item.get("tags", []),
                    recipients=recipients,
                )
            )
        return res

    def find_by_name(self, name: str) -> Optional[JailRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
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
                secrets=item.get("secrets", []),
                facts=item.get("facts", []),
            )
            for item in self._db.get("generators", [])
        ]

    def find_by_name(self, name: str) -> Optional[GeneratorRecord]:
        for g in self.find_all():
            if g.name == name:
                return g
        return None


class OverlaysRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[OverlayRecord]:
        from .models import OverlayLinkRecord

        res = []
        for item in self._db.get("overlays", []):
            links = []
            for l in item.get("links", []):
                ha = l.get("a", {}).get("host")
                hb = l.get("b", {}).get("host")
                if ha and hb:
                    links.append(OverlayLinkRecord(host_a=ha, host_b=hb))
            res.append(
                OverlayRecord(
                    name=item.get("name", ""),
                    ipv6Prefix=item.get("ipv6Prefix", ""),
                    tags=item.get("tags", []),
                    links=links,
                )
            )
        return res

    def find_by_name(self, name: str) -> Optional[OverlayRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
        return None


class HostOverlaysRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[HostOverlayRecord]:
        res = []
        for overlay_list in self._db.get("hostOverlays", []):
            for item in overlay_list:
                res.append(
                    HostOverlayRecord(
                        name=item.get("name", ""),
                        host=item.get("host", ""),
                        ipv6=item.get("ipv6", ""),
                    )
                )
        return res


class JailOverlaysRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[JailOverlayRecord]:
        res = []
        for overlay_list in self._db.get("jailOverlays", []):
            for item in overlay_list:
                res.append(
                    JailOverlayRecord(
                        name=item.get("name", ""),
                        jail=item.get("jail", ""),
                        ipv6=item.get("ipv6", ""),
                    )
                )
        return res


class QemuNetRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> list[QemuNetRecord]:
        return [
            QemuNetRecord(net.get("name"), net.get("idx"))
            for net in self._db.get("qemuNets", [])
        ]


class QemuQuestRepository:
    def __init__(self, db: dict):
        self._db = db

    def find_all(self) -> List[QemuQuestRecord]:
        from .models import QemuQuestNetRecord, QemuNetRecord, QemuPortForwardRecord

        res = []
        hosts_tags = {
            h.get("name"): h.get("tags", []) for h in self._db.get("hosts", [])
        }
        for item in self._db.get("qemuQuests", []):
            name = item.get("host", "")
            path = item.get("path", "")
            variant = item.get("variant")
            variants = {}
            if variant and path:
                variants[variant] = path

            nets = [
                QemuQuestNetRecord(
                    net=n.get("name", ""),
                    iface=n.get("iface", ""),
                    mac=n.get("mac", ""),
                )
                for n in item.get("nets", [])
            ]

            forward_ports = [
                QemuPortForwardRecord(
                    name=pf.get("name", ""),
                    proto=pf.get("proto", "tcp"),
                    host=pf.get("hostPort", 0),
                    guest=pf.get("guestPort", 0),
                )
                for pf in item.get("forwardPorts", [])
            ]

            res.append(
                QemuQuestRecord(
                    name=name,
                    tags=hosts_tags.get(name, []),
                    path=path,
                    nets=nets,
                    forward_ports=forward_ports,
                    variant=variant,
                    variants=variants,
                )
            )
        return res

    def find_by_name(self, name: str) -> Optional[QemuQuestRecord]:
        for item in self.find_all():
            if item.name == name:
                return item
        return None
