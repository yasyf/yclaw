"""Shared CLI plumbing: resolve a machine from the manifest and run a command's async body.

``run`` is the single place command bodies enter the event loop, so the two remote failures that
carry an exit-code policy — a Tailscale check-mode login wall and a remote timeout — are mapped to
their exit codes here instead of in every command.
"""

from collections.abc import Awaitable, Callable

import anyio
import click

from .manifest import Machine, Manifest, Service
from .output import EXIT_CHECK_WALL, EXIT_TIMEOUT, fail
from .remote import CheckWallError, RemoteTimeout


def resolve_machine(manifest: Manifest, name: str) -> Machine:
    try:
        machine = manifest.machines[name]
    except KeyError:
        known = ", ".join(n for n, m in manifest.machines.items() if m.ssh is not None)
        raise click.BadParameter(f"unknown machine {name!r}; known: {known}", param_hint="MACHINE") from None
    if machine.ssh is None:
        raise click.BadParameter(f"{name!r} is the host, not a tailnet node", param_hint="MACHINE")
    return machine


def resolve_service(machine: Machine, name: str) -> Service:
    try:
        return machine.services[name]
    except KeyError:
        known = ", ".join(machine.services)
        raise click.BadParameter(
            f"unknown service {name!r} on {machine.name}; known: {known}", param_hint="SERVICE"
        ) from None


def run[T](async_main: Callable[[], Awaitable[T]]) -> T:
    try:
        return anyio.run(async_main)
    except CheckWallError as exc:
        click.echo(fail(f"tailscale check-mode login required — approve at:\n  {exc.url}"), err=True)
        raise SystemExit(EXIT_CHECK_WALL) from None
    except RemoteTimeout as exc:
        click.echo(fail(str(exc)), err=True)
        raise SystemExit(EXIT_TIMEOUT) from None
