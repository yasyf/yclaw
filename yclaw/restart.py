"""``yclaw restart`` and ``yclaw bounce`` — kick a service, then wait for it to report healthy.

``restart`` is the in-place kick: ``launchctl kickstart -k`` on darwin, ``systemctl restart`` on hermes.
When a launchd label is not loaded, kickstart cannot help — it exits non-zero and the user is pointed
at ``bounce``, which fully unloads (``bootout``) and reloads (``bootstrap``) the plist from disk.
"""

import anyio
import click

from . import output, probes, remote
from .dispatch import resolve_machine, resolve_service, run
from .manifest import Machine, Service, load_manifest
from .probes import Status

HEALTH_TIMEOUT = 30.0
HEALTH_INTERVAL = 2.0


async def _health_wait(machine: Machine, service: Service) -> None:
    if service.health is None:
        return
    start = anyio.current_time()
    while True:
        result = await probes.service_health(machine, service, timeout=HEALTH_INTERVAL)
        if result.status is Status.PASS:
            click.echo(output.ok(f"healthy  {result.name}  {result.detail}"))
            return
        if anyio.current_time() - start >= HEALTH_TIMEOUT:
            click.echo(output.warn(f"not healthy after {HEALTH_TIMEOUT:g}s  {result.name}  {result.detail}"), err=True)
            return
        await anyio.sleep(HEALTH_INTERVAL)


def _fail(message: str, result: remote.RemoteResult) -> None:
    click.echo(output.fail(message), err=True)
    if result.stderr.strip():
        click.echo(result.stderr, nl=False, err=True)
    raise SystemExit(output.EXIT_FAIL)


async def _restart(machine: Machine, service: Service) -> None:
    if service.launchd is not None:
        target = service.launchd.target
        result = await remote.run(machine, f"launchctl kickstart -k {target}")
        if result.returncode != 0:
            _fail(
                f"kickstart {target} failed (exit {result.returncode}); the label may not be loaded — "
                f"try `yclaw bounce {machine.name} {service.name}`",
                result,
            )
    elif service.systemd is not None:
        result = await remote.run(machine, f"systemctl restart {service.systemd}")
        if result.returncode != 0:
            _fail(f"systemctl restart {service.systemd} failed (exit {result.returncode})", result)
    else:
        raise click.UsageError(f"service {service.name!r} on {machine.name} has no restartable unit")
    click.echo(output.ok(f"restarted {service.name} on {machine.name}"))
    await _health_wait(machine, service)


async def _bounce(machine: Machine, service: Service, *, interval: float, timeout: float) -> None:
    ref = service.launchd
    await remote.run(machine, f"launchctl bootout {ref.target}")
    start = anyio.current_time()
    while True:
        printed = await remote.run(machine, f"launchctl print {ref.target}")
        if printed.returncode != 0:
            break
        if anyio.current_time() - start >= timeout:
            _fail(f"{ref.target} still loaded {timeout:g}s after bootout — cannot bootstrap over a live label", printed)
        await anyio.sleep(interval)
    bootstrapped = await remote.run(machine, f"launchctl bootstrap {ref.domain} {ref.plist_path}")
    if bootstrapped.returncode != 0:
        _fail(f"bootstrap {ref.domain} {ref.plist_path} failed (exit {bootstrapped.returncode})", bootstrapped)
    click.echo(output.ok(f"bounced {service.name} on {machine.name}"))
    await _health_wait(machine, service)


@click.command("restart")
@click.argument("machine")
@click.argument("service")
def restart(machine: str, service: str) -> None:
    """Kick SERVICE on MACHINE in place, then wait for its health check."""
    target = resolve_machine(load_manifest(), machine)
    svc = resolve_service(target, service)
    run(lambda: _restart(target, svc))


@click.command("bounce")
@click.argument("machine")
@click.argument("service")
def bounce(machine: str, service: str) -> None:
    """Fully unload and reload SERVICE's launchd plist on MACHINE (darwin only)."""
    target = resolve_machine(load_manifest(), machine)
    svc = resolve_service(target, service)
    if svc.launchd is None:
        raise click.UsageError(f"bounce is launchd-only; {svc.name!r} on {target.name} has no launchd plist")
    run(lambda: _bounce(target, svc, interval=HEALTH_INTERVAL, timeout=HEALTH_TIMEOUT))
