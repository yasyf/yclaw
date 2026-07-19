"""``yclaw secret`` — read, write, and reconcile fleet secrets in the dedicated keychain.

``secret read`` writes the value to stdout and nothing else — no logging, no stderr — so it is safe to
capture in a shell. ``secret sops`` decrypts a host's bundle with that host's staged age key.
``secret reconcile`` (see ``reconcile.py``) converges the keychain and per-host sops bundles onto the
secrets manifest.
"""

import dataclasses
import os
import subprocess
from pathlib import Path

import click

from . import keychain, output
from .keychain import KeychainError
from .manifest import Manifest, load_manifest
from .reconcile import durables, reconcile


def _aliases(manifest: Manifest) -> dict[str, str]:
    aliases = {
        field.name.replace("_", "-"): getattr(manifest.host_paths.keychain, field.name)
        for field in dataclasses.fields(manifest.host_paths.keychain)
        if field.name != "login_unlock"  # unlock key lives in the LOGIN keychain — not CLI-readable
    }
    for machine in manifest.machines.values():
        if machine.admin_pass_keychain is not None:
            aliases[f"{machine.name}-admin-pass"] = machine.admin_pass_keychain
    for durable in durables(manifest):
        aliases[durable.alias] = durable.service
    return aliases


def _resolve(alias: str) -> str:
    aliases = _aliases(load_manifest())
    try:
        return aliases[alias]
    except KeyError:
        raise click.BadParameter(f"unknown alias {alias!r}; try `yclaw secret list`", param_hint="ALIAS") from None


@click.group("secret")
def secret() -> None:
    """Read keychain secrets and decrypt per-host sops bundles."""


@secret.command("list")
def list_() -> None:
    """List the known secret aliases and the keychain services they map to."""
    rows = [[alias, service] for alias, service in sorted(_aliases(load_manifest()).items())]
    click.echo(output.render_table(["ALIAS", "KEYCHAIN SERVICE"], rows))


@secret.command("read")
@click.argument("alias")
def read(alias: str) -> None:
    """Print the value of the secret named ALIAS to stdout."""
    service = _resolve(alias)
    try:
        click.echo(keychain.read(service))
    except KeychainError as exc:
        raise click.ClickException(str(exc)) from exc


@secret.command("has")
@click.argument("alias")
def has_(alias: str) -> None:
    """Exit 0 if the secret named ALIAS exists in the keychain, 1 if not."""
    service = _resolve(alias)
    try:
        present = keychain.has(service)
    except KeychainError as exc:
        raise click.ClickException(str(exc)) from exc
    raise SystemExit(output.EXIT_CLEAN if present else output.EXIT_FAIL)


@secret.command("set")
@click.argument("alias")
@click.option("--value", required=True, help="The secret value; '-' reads it from stdin.")
def set_(alias: str, value: str) -> None:
    """Write the secret named ALIAS into the dedicated keychain."""
    service = _resolve(alias)
    if value == "-":
        value = click.get_text_stream("stdin").read().rstrip("\n")
    if not value:
        raise click.BadParameter("empty secret value", param_hint="--value")
    try:
        keychain.write(service, value)
    except KeychainError as exc:
        raise click.ClickException(str(exc)) from exc


@secret.command("sops")
@click.argument("host")
def sops(host: str) -> None:
    """Decrypt HOST's sops bundle with HOST's staged age key."""
    manifest = load_manifest()
    host_dir = Path.home() / manifest.host_paths.state_dir_rel / "hosts" / host
    key = host_dir / "key.txt"
    bundle = host_dir / "secrets.sops.yaml"
    if not key.exists() or not bundle.exists():
        raise click.ClickException(f"no sops bundle for {host!r} at {bundle} — run `just bootstrap` first")
    env = {**os.environ, "SOPS_AGE_KEY_FILE": str(key)}
    raise SystemExit(subprocess.run(["sops", "-d", str(bundle)], env=env).returncode)


secret.add_command(reconcile)
