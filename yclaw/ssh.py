"""``yclaw ssh`` — a tailscale-ssh shell or one-shot command on a fleet node."""

import dataclasses
import shlex

import click

from . import remote
from .dispatch import resolve_machine, run
from .manifest import load_manifest


@click.command("ssh")
@click.argument("machine")
@click.argument("cmd", nargs=-1)
@click.option("--user", help="Override the ssh user from the manifest.")
@click.option("--timeout", type=float, default=30, show_default=True, help="Per-command timeout in seconds (0 = none).")
def ssh(machine: str, cmd: tuple[str, ...], user: str | None, timeout: float) -> None:
    """Open a shell on MACHINE, or run CMD there and exit with its status."""
    target = resolve_machine(load_manifest(), machine)
    if target.ssh is None:
        raise click.UsageError(f"{machine!r} is the host, not a tailnet node — run its commands locally")
    if user is not None:
        target = dataclasses.replace(target, ssh=dataclasses.replace(target.ssh, user=user))
    if not cmd:
        remote.interactive(target)
    command = cmd[0] if len(cmd) == 1 else shlex.join(cmd)
    result = run(lambda: remote.run(target, command, timeout=None if timeout == 0 else timeout))
    click.echo(result.stdout, nl=False)
    click.echo(result.stderr, nl=False, err=True)
    raise SystemExit(result.returncode)
