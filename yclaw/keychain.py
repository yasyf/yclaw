"""Read and write secrets in the dedicated ``yclaw.keychain-db``, mirroring ``scripts/lib/secrets.sh``.

The dedicated keychain is unlocked with a password stored in the LOGIN keychain under the service
named by ``host_paths.keychain.login_unlock`` in ``machines.json``, the requested item is accessed,
and the dedicated keychain is ALWAYS re-locked afterwards — even when the access fails. A run doing
many operations holds a single unlock via ``unlocked()`` instead of paying the unlock/lock envelope
per call. ``ensure`` creates the keychain on first run (``yclaw secret reconcile`` owns that path).
This module never logs a secret value.
"""

import getpass
import secrets
import string
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .manifest import load_manifest

KEYCHAIN_PATH = Path.home() / "Library" / "Keychains" / "yclaw.keychain-db"

BOOTSTRAP_HINT = "run 'just bootstrap' first"

# True while an ``unlocked()`` context holds the keychain open; read/has/write then skip their
# per-call unlock/lock envelope.
_unlock_held = False


class KeychainError(Exception):
    """The yclaw keychain or a requested item is missing/unreadable."""


def _security(args: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["security", *args], capture_output=True, text=True, check=check)


def _login_unlock_service() -> str:
    return load_manifest().host_paths.keychain.login_unlock


def _unlock() -> None:
    if not KEYCHAIN_PATH.exists():
        raise KeychainError(f"{KEYCHAIN_PATH} not found — {BOOTSTRAP_HINT}")
    unlock_service = _login_unlock_service()
    unlock = _security(["find-generic-password", "-a", getpass.getuser(), "-s", unlock_service, "-w"], check=False)
    if unlock.returncode != 0:
        raise KeychainError(f"login keychain item {unlock_service!r} not found — {BOOTSTRAP_HINT}")
    _security(["unlock-keychain", "-p", unlock.stdout.strip(), str(KEYCHAIN_PATH)], check=True)


def _lock() -> None:
    _security(["lock-keychain", str(KEYCHAIN_PATH)], check=True)


@contextmanager
def _session() -> Iterator[None]:
    if _unlock_held:
        yield
        return
    _unlock()
    try:
        yield
    finally:
        _lock()


def _find_item(service: str) -> subprocess.CompletedProcess[str]:
    return _security(
        ["find-generic-password", "-a", getpass.getuser(), "-s", service, "-w", str(KEYCHAIN_PATH)], check=False
    )


def mint_password() -> str:
    """A 32-char alphanumeric password — the sizing the retired
    ``openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32`` produced."""
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))


def require_aqua_session() -> None:
    """Fail fast in a session that cannot read the login keychain — before any secret work, not after.

    Agent/SSH/background processes run in a macOS Background security session where the login
    keychain is unsearchable, so the unlock-password read fails even though the item exists
    (mirrors the guard in ``scripts/imsg-extract-key.sh``). A missing dedicated keychain skips the
    probe: on a true first run the login item does not exist yet either, and ``ensure`` fails
    loudly on its own when the login keychain is unwritable.
    """
    if not KEYCHAIN_PATH.exists():
        return
    unlock_service = _login_unlock_service()
    probe = _security(["find-generic-password", "-a", getpass.getuser(), "-s", unlock_service, "-w"], check=False)
    if probe.returncode != 0:
        raise KeychainError(
            f"cannot read {unlock_service!r} from the login keychain — run this in Terminal.app on the host "
            "(Aqua session); if this IS Terminal.app, unlock first: "
            "security unlock-keychain ~/Library/Keychains/login.keychain-db"
        )


def ensure() -> None:
    """Create the dedicated keychain on first run, seeding its unlock password into the LOGIN keychain.

    The login write runs FIRST: a create failure then self-heals on the next run (re-mint + ``-U``
    overwrite), and in a background session the login write fails before anything is created.
    """
    if KEYCHAIN_PATH.exists():
        return
    password = mint_password()
    seeded = _security(
        [
            "add-generic-password",
            "-U",
            "-a",
            getpass.getuser(),
            "-s",
            _login_unlock_service(),
            "-l",
            "yclaw dedicated keychain unlock password",
            "-w",
            password,
        ],
        check=False,
    )
    if seeded.returncode != 0:
        raise KeychainError(
            f"cannot seed the unlock password into the login keychain (security exited {seeded.returncode}) — "
            "run this in Terminal.app on the host (Aqua session); if this IS Terminal.app, unlock first: "
            "security unlock-keychain ~/Library/Keychains/login.keychain-db"
        )
    _security(["create-keychain", "-p", password, str(KEYCHAIN_PATH)], check=True)
    _security(["set-keychain-settings", "-l", "-t", "300", str(KEYCHAIN_PATH)], check=True)


@contextmanager
def unlocked() -> Iterator[None]:
    """Hold one unlock across many read/has/write calls; ALWAYS re-locks on exit.

    Re-applies the auto-lock settings (lock on sleep + after 300s idle) on every unlock so
    pre-existing keychains pick them up, mirroring the retired ``_yclaw_keychain_unlock``.
    """
    global _unlock_held
    _unlock()
    _security(["set-keychain-settings", "-l", "-t", "300", str(KEYCHAIN_PATH)], check=True)
    _unlock_held = True
    try:
        yield
    finally:
        _unlock_held = False
        _lock()


def read(service: str) -> str:
    with _session():
        found = _find_item(service)
        if found.returncode != 0:
            raise KeychainError(f"keychain item {service!r} not found in {KEYCHAIN_PATH} — {BOOTSTRAP_HINT}")
        return found.stdout.strip()


def has(service: str) -> bool:
    with _session():
        return _find_item(service).returncode == 0


def write(service: str, value: str) -> None:
    with _session():
        _security(
            ["add-generic-password", "-U", "-a", getpass.getuser(), "-s", service, "-w", value, str(KEYCHAIN_PATH)],
            check=True,
        )
