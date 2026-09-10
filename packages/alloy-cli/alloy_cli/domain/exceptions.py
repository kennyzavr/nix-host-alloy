from pathlib import Path

class AlloyError(Exception):
    pass

class GitAddError(AlloyError):
    def __init__(self, target: str, error_msg: str):
        self.target = target
        self.error_msg = error_msg
        super().__init__(f"target={target} error={error_msg}")

class FactNotDefinedError(AlloyError):
    def __init__(self, name: str):
        self.name = name
        self.error_msg = f"Fact '{name}' is not defined in the cluster state."
        super().__init__(self.error_msg)

class IndexNotDefinedError(AlloyError):
    def __init__(self, name: str):
        self.name = name
        self.error_msg = f"Index '{name}' is not defined in the cluster state."
        super().__init__(self.error_msg)

class IndexAllocationFailedError(AlloyError):
    def __init__(self, name: str, needed: int, min_val: int, max_val: int):
        self.name = name
        self.needed = needed
        self.min_val = min_val
        self.max_val = max_val
        self.error_msg = f"Index allocation failed for '{name}'. Need {needed} new slots, but not enough gaps available in range [{min_val}, {max_val}]."
        super().__init__(self.error_msg)

class IndexStateCorruptedError(AlloyError):
    def __init__(self, name: str, fact_name: str, reason: str = "cannot be parsed as valid JSON"):
        self.name = name
        self.fact_name = fact_name
        self.reason = reason
        self.error_msg = f"State for index '{name}' (fact '{fact_name}') is corrupted: {reason}."
        super().__init__(self.error_msg)

class GeneratorNotDefinedError(AlloyError):
    def __init__(self, name: str):
        self.name = name
        self.error_msg = f"Generator '{name}' is not defined in the cluster state."
        super().__init__(self.error_msg)

class GeneratorCycleError(AlloyError):
    def __init__(self):
        self.error_msg = "A dependency cycle was detected in the generators graph."
        super().__init__(self.error_msg)

class GeneratorExecutionError(AlloyError):
    def __init__(self, name: str, return_code: int):
        self.name = name
        self.return_code = return_code
        self.error_msg = f"Generator '{name}' failed with exit code {return_code}."
        super().__init__(self.error_msg)

class FactFileAlreadyExistsError(AlloyError):
    def __init__(self, fact_name: str, fact_file: Path):
        self.fact_name = fact_name
        self.fact_file = fact_file
        super().__init__(f"fact={fact_name} file={fact_file}")

class FactFileNotFoundError(AlloyError):
    def __init__(self, fact_name: str, fact_file: Path):
        self.fact_name = fact_name
        self.fact_file = fact_file
        super().__init__(f"fact={fact_name} file={fact_file}")

class MasterSecretNotDefinedError(AlloyError):
    def __init__(self, master_secret_name: str):
        self.master_secret_name = master_secret_name
        super().__init__(f"master_secret={master_secret_name}")

class HostSecretNotDefinedError(AlloyError):
    def __init__(self, host_secret_name: str):
        self.host_secret_name = host_secret_name
        super().__init__(f"host_secret={host_secret_name}")

class JailSecretNotDefinedError(AlloyError):
    def __init__(self, jail_secret_name: str):
        self.jail_secret_name = jail_secret_name
        super().__init__(f"jail_secret={jail_secret_name}")

class MasterSecretFileAlreadyExistsError(AlloyError):
    def __init__(self, master_secret_name: str, master_secret_file: Path):
        self.master_secret_name = master_secret_name
        self.master_secret_file = master_secret_file
        super().__init__(f"master_secret={master_secret_name} file={master_secret_file}")

class MasterSecretFileNotFoundError(AlloyError):
    def __init__(self, master_secret_name: str, master_secret_file: Path):
        self.master_secret_name = master_secret_name
        self.master_secret_file = master_secret_file
        super().__init__(f"master_secret={master_secret_name} file={master_secret_file}")

class HostSecretFileAlreadyExistsError(AlloyError):
    def __init__(self, host_secret_name: str, host_secret_file: Path, host_name: str):
        self.host_secret_name = host_secret_name
        self.host_secret_file = host_secret_file
        self.host_name = host_name
        super().__init__(f"host={host_name} host_secret={host_secret_name} file={host_secret_file}")

class JailSecretFileAlreadyExistsError(AlloyError):
    def __init__(self, jail_secret_name: str, jail_secret_file: Path, jail_name: str):
        self.jail_secret_name = jail_secret_name
        self.jail_secret_file = jail_secret_file
        self.jail_name = jail_name
        super().__init__(f"jail={jail_name} jail_secret={jail_secret_name} file={jail_secret_file}")

class NoMasterIdentitiesDefinedError(AlloyError):
    pass

class NoMasterRecipientsDefinedError(AlloyError):
    pass

class NoHostRecipientsDefinedError(AlloyError):
    def __init__(self, host_name: str):
        self.host_name = host_name
        super().__init__(f"host={host_name}")

class NoJailRecipientsDefinedError(AlloyError):
    def __init__(self, jail_name: str):
        self.jail_name = jail_name
        super().__init__(f"jail={jail_name}")

class HostNotDefinedError(AlloyError):
    def __init__(self, host_name: str):
        self.host_name = host_name
        super().__init__(f"host={host_name}")

class JailNotDefinedError(AlloyError):
    def __init__(self, jail_name: str):
        self.jail_name = jail_name
        super().__init__(f"jail={jail_name}")

class RageEncryptionError(AlloyError):
    def __init__(self, target: str, error_msg: str):
        self.target = target
        self.error_msg = error_msg
        super().__init__(f"target={target} error={error_msg}")

class RageDecryptionError(AlloyError):
    def __init__(self, target: str, error_msg: str):
        self.target = target
        self.error_msg = error_msg
        super().__init__(f"target={target} error={error_msg}")
