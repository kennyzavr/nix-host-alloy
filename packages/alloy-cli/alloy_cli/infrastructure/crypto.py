import subprocess
from pathlib import Path
from typing import List
from ..domain.exceptions import RageEncryptionError, RageDecryptionError

class RageAdapter:
    def __init__(self, root: Path):
        self.root = root

    def encrypt(self, data: bytes, recipients: List[str], rel_out_path: str):
        out_p = self.root / rel_out_path
        out_p.parent.mkdir(parents=True, exist_ok=True)
        args = []
        for r in recipients:
            args.extend(["-R", r])
        res = subprocess.run(["rage", "-e"] + args + ["-o", str(out_p)], input=data, capture_output=True)
        if res.returncode != 0:
            err = res.stderr.decode().strip()
            if "\n" in err:
                err = "\n  " + err.replace("\n", "\n  ")
            raise RageEncryptionError(rel_out_path, err)

    def decrypt(self, rel_in_path: str, identities: List[str]) -> bytes:
        in_p = self.root / rel_in_path
        args = []
        for i in identities:
            args.extend(["-i", i])
        res = subprocess.run(["rage", "-d"] + args + [str(in_p)], capture_output=True)
        if res.returncode != 0:
            err = res.stderr.decode().strip()
            if "\n" in err:
                err = "\n  " + err.replace("\n", "\n  ")
            raise RageDecryptionError(rel_in_path, err)
        return res.stdout

    def rekey(self, rel_in_path: str, rel_out_path: str, identities: List[str], recipients: List[str]):
        in_p = self.root / rel_in_path
        out_p = self.root / rel_out_path
        out_p.parent.mkdir(parents=True, exist_ok=True)
        
        id_args = []
        for i in identities:
            id_args.extend(["-i", i])
            
        rec_args = []
        for r in recipients:
            rec_args.extend(["-R", r])
        
        dec_proc = subprocess.Popen(["rage", "-d"] + id_args + [str(in_p)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        enc_proc = subprocess.Popen(["rage", "-e"] + rec_args + ["-o", str(out_p)], stdin=dec_proc.stdout, stderr=subprocess.PIPE)

        if dec_proc.stdout:
            dec_proc.stdout.close()
            
        enc_stderr = enc_proc.communicate()[1]
        dec_stderr = dec_proc.communicate()[1]

        if dec_proc.returncode != 0:
            err = dec_stderr.decode().strip()
            if "\n" in err:
                err = "\n  " + err.replace("\n", "\n  ")
            raise RageDecryptionError(rel_in_path, err)
        if enc_proc.returncode != 0:
            err = enc_stderr.decode().strip()
            if "\n" in err:
                err = "\n  " + err.replace("\n", "\n  ")
            raise RageEncryptionError(rel_out_path, err)
