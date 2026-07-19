"""``yclaw restart`` and ``yclaw bounce`` — kick a service, then wait for it to report healthy.

``restart`` is the in-place kick: ``launchctl kickstart -k`` on darwin, and for the hermes container a
force-recreate (``container rm -f`` — apple/container has no ``restart`` verb) that the host supervisor
turns back into a running guest. When a launchd label is not loaded, kickstart cannot help — it exits
non-zero and the user is pointed at ``bounce``, which fully unloads and reloads the plist from disk.
"""

import anyio
import click

from . import container, output, probes, remote
from .dispatch import resolve_machine, resolve_service, run
from .manifest import Machine, Service, load_manifest
from .probes import Status

# Must cover rapid-mlx's model load: ~101 s measured cold-start to LISTEN on metal.
HEALTH_TIMEOUT = 150.0
HEALTH_INTERVAL = 2.0
# rm -f drops the guest; the com.yclaw.container-<name> supervisor recreates it within a tick.
CONTAINER_RECREATE_TIMEOUT = 90.0
CONTAINER_RECREATE_POLL = 3.0


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


async def _restart_container(machine: Machine, service: Service) -> None:
    rm = await remote.run(machine, f"{container.CONTAINER_BIN} rm -f {machine.container}")
    if rm.returncode != 0:
        _fail(f"container rm -f {machine.container} failed (exit {rm.returncode})", rm)
    click.echo(output.ok(f"removed {machine.container}; waiting for the supervisor to recreate it"))
    start = anyio.current_time()
    while True:
        try:
            state = await probes.container_proc_state(machine, service, timeout=CONTAINER_RECREATE_POLL)
        except container.ContainerTimeout:
            state = None
        if state is not None and state.status is Status.PASS:
            click.echo(output.ok(f"recreated {service.name} on {machine.name}  {state.detail}"))
            await _health_wait(machine, service)
            return
        if anyio.current_time() - start >= CONTAINER_RECREATE_TIMEOUT:
            detail = state.detail if state is not None else "container exec timed out"
            click.echo(
                output.fail(f"{machine.container} not back after {CONTAINER_RECREATE_TIMEOUT:g}s  {detail}"), err=True
            )
            raise SystemExit(output.EXIT_FAIL)
        await anyio.sleep(CONTAINER_RECREATE_POLL)


async def _restart(machine: Machine, service: Service) -> None:
    if service.container_proc is not None:
        await _restart_container(machine, service)
        return
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
    bootstrapped = await remote.run(machine, f"launchctl bootstrap {ref.bootstrap_domain} {ref.plist_path}")
    if bootstrapped.returncode != 0:
        _fail(
            f"bootstrap {ref.bootstrap_domain} {ref.plist_path} failed (exit {bootstrapped.returncode})",
            bootstrapped,
        )
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
