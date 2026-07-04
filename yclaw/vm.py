"""``yclaw vm`` — Tart lifecycle helpers that work before a guest joins the tailnet.

``vm ssh`` reaches the guest over its Tart IP with the admin password pulled from the keychain (never
hardcoded), so it works during first boot before ``tailscale ssh`` is available.
"""

import shlex
import subprocess

import click

from . import remote
from .dispatch import resolve_machine, run
from .keychain import KeychainError
from .manifest import load_manifest


def _tart_ip(name: str) -> str:
    result = subprocess.run(["tart", "ip", name], capture_output=True, text=True)
    if result.returncode != 0:
        click.echo(result.stderr, nl=False, err=True)
        raise SystemExit(result.returncode)
    return result.stdout.strip()


@click.group("vm")
def vm() -> None:
    """Manage the Tart guest VMs on this host."""


@vm.command("list")
def list_() -> None:
    """List the Tart VMs (``tart list``)."""
    raise SystemExit(subprocess.run(["tart", "list"]).returncode)


@vm.command("ip")
@click.argument("name")
def ip(name: str) -> None:
    """Print NAME's Tart IP address."""
    click.echo(_tart_ip(name))


@vm.command("ssh")
@click.argument("name")
@click.argument("cmd", nargs=-1)
def ssh(name: str, cmd: tuple[str, ...]) -> None:
    """Pre-tailnet ssh into NAME over its Tart IP, or run CMD there."""
    machine = resolve_machine(load_manifest(), name)
    if machine.admin_pass_keychain is None:
        raise click.UsageError(f"{machine.name} has no admin password in the keychain for a pre-tailnet ssh")
    try:
        if not cmd:
            remote.pre_tailnet_interactive(machine)
        command = cmd[0] if len(cmd) == 1 else shlex.join(cmd)
        result = run(lambda: remote.pre_tailnet_run(machine, command))
    except KeychainError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(result.stdout, nl=False)
    click.echo(result.stderr, nl=False, err=True)
    raise SystemExit(result.returncode)


@vm.command("console")
@click.argument("name")
def console(name: str) -> None:
    """Open NAME's screen-sharing console (``open vnc://<ip>``)."""
    raise SystemExit(subprocess.run(["open", f"vnc://{_tart_ip(name)}"]).returncode)
