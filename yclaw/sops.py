"""Thin subprocess wrappers around ``sops`` and ``age-keygen``, ported from ``scripts/lib/secrets.sh``.

``--config /dev/null`` ignores any ambient ``.sops.yaml`` — the explicit ``--age`` recipient and
``SOPS_AGE_KEY_FILE`` are authoritative. ``--input-type/--output-type yaml`` are REQUIRED because
plaintext travels through extension-less temp files; without them sops wraps the document in a
``data:`` blob sops-nix cannot navigate. ``extract`` returns a string leaf verbatim (sops does not
re-encode it). Secret values never appear in argv or in an error message — only file paths do.
"""

import os
import subprocess
import tempfile
from pathlib import Path

YAML_ARGS = ("--config", "/dev/null", "--input-type", "yaml", "--output-type", "yaml")


class SopsError(Exception):
    """A sops/age subprocess failed; carries stderr, never a secret value."""


def _run(argv: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(argv, capture_output=True, text=True, env=env)
    if completed.returncode != 0:
        raise SopsError(f"{' '.join(argv[:2])} exited {completed.returncode}: {completed.stderr.strip()}")
    return completed.stdout


def _age_env(key_file: Path) -> dict[str, str]:
    return {**os.environ, "SOPS_AGE_KEY_FILE": str(key_file)}


def keygen(path: Path) -> None:
    old_umask = os.umask(0o077)
    try:
        _run(["age-keygen", "-o", str(path)])
    finally:
        os.umask(old_umask)


def pubkey(path: Path) -> str:
    pub = _run(["age-keygen", "-y", str(path)]).strip()
    if not pub.startswith("age1"):
        raise SopsError(f"could not derive an age public key from {path}")
    return pub


def decrypt(bundle: Path, key_file: Path) -> str:
    return _run(["sops", "--decrypt", *YAML_ARGS, str(bundle)], env=_age_env(key_file))


def extract(bundle: Path, key_file: Path, sops_path: str) -> str:
    return _run(["sops", "--decrypt", *YAML_ARGS, "--extract", sops_path, str(bundle)], env=_age_env(key_file))


def encrypt(plaintext: str, pubkey: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete_on_close=False) as tmp:
        tmp.write(plaintext)
        tmp.close()
        return _run(["sops", "--encrypt", *YAML_ARGS, "--age", pubkey, tmp.name])
