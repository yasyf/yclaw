"""Read secrets from the dedicated ``yclaw.keychain-db``, mirroring ``scripts/lib/secrets.sh``.

The dedicated keychain is unlocked with a password stored in the LOGIN keychain under the service
named by ``host_paths.keychain.login_unlock`` in ``machines.json``, the requested item is read, and
the dedicated keychain is ALWAYS re-locked afterwards — even when the read fails. This module never
creates the keychain (``just bootstrap`` owns that) and never logs a secret value.
"""

import getpass
import subprocess
from pathlib import Path

from .manifest import load_manifest

KEYCHAIN_PATH = Path.home() / "Library" / "Keychains" / "yclaw.keychain-db"

_BOOTSTRAP_HINT = "run 'just bootstrap' first"


def _security(args: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["security", *args], capture_output=True, text=True, check=check)


def _login_unlock_service() -> str:
    return load_manifest().host_paths.keychain.login_unlock


class KeychainError(Exception):
    """The yclaw keychain or a requested item is missing/unreadable."""


def read(service: str) -> str:
    if not KEYCHAIN_PATH.exists():
        raise KeychainError(f"{KEYCHAIN_PATH} not found — {_BOOTSTRAP_HINT}")
    account = getpass.getuser()
    unlock_service = _login_unlock_service()
    unlock = _security(["find-generic-password", "-a", account, "-s", unlock_service, "-w"], check=False)
    if unlock.returncode != 0:
        raise KeychainError(f"login keychain item {unlock_service!r} not found — {_BOOTSTRAP_HINT}")
    _security(["unlock-keychain", "-p", unlock.stdout.strip(), str(KEYCHAIN_PATH)], check=True)
    try:
        found = _security(
            ["find-generic-password", "-a", account, "-s", service, "-w", str(KEYCHAIN_PATH)], check=False
        )
        if found.returncode != 0:
            raise KeychainError(f"keychain item {service!r} not found in {KEYCHAIN_PATH} — {_BOOTSTRAP_HINT}")
        return found.stdout.strip()
    finally:
        _security(["lock-keychain", str(KEYCHAIN_PATH)], check=True)
