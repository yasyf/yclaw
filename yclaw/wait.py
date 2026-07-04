"""``yclaw wait`` — block until a fleet endpoint or service comes up, for scripting bring-up.

Every subcommand exits ``0`` the moment its probe passes and exits ``1`` (after a ``FATAL`` line) when
the deadline lapses, so a shell can gate on the exit code.
"""

from collections.abc import Awaitable, Callable
from typing import Any

import anyio
import click

from . import output, probes, remote
from .dispatch import resolve_machine, resolve_service, run
from .manifest import Machine, Service, load_manifest
from .probes import ProbeResult, Status
from .remote import RemoteTimeout


def _wait_options(command: Callable[..., Any]) -> Callable[..., Any]:
    command = click.option("--interval", type=float, default=2.0, show_default=True, help="Seconds between probes.")(
        command
    )
    return click.option("--timeout", type=float, default=120.0, show_default=True, help="Total seconds to wait.")(
        command
    )


async def _poll(
    name: str, make_probe: Callable[[], Awaitable[ProbeResult]], *, timeout: float, interval: float
) -> ProbeResult:
    start = anyio.current_time()
    while True:
        try:
            result = await make_probe()
        except RemoteTimeout as exc:
            result = ProbeResult(name, Status.FAIL, f"probe timed out after {exc.timeout}s")
        if result.status is Status.PASS or anyio.current_time() - start >= timeout:
            return result
        await anyio.sleep(interval)


def _finish(name: str, result: ProbeResult) -> None:
    if result.status is Status.PASS:
        click.echo(output.ok(f"ok  {name}  {result.detail}"))
        return
    click.echo(output.fail(f"FATAL: gave up waiting for {name}: {result.detail}"), err=True)
    raise SystemExit(output.EXIT_FAIL)


def _service_probe(machine: Machine, service: Service, interval: float) -> Callable[[], Awaitable[ProbeResult]]:
    if service.launchd is not None:
        return lambda: probes.launchd_state(machine, service, timeout=interval)
    if service.systemd is not None:
        return lambda: probes.systemd_state(machine, service, timeout=interval)
    raise click.UsageError(f"service {service.name!r} on {machine.name} has no launchd/systemd unit to wait on")


@click.group("wait")
def wait() -> None:
    """Block until an endpoint or service is up."""


@wait.command("http")
@click.argument("url")
@_wait_options
def http(url: str, timeout: float, interval: float) -> None:
    """Wait for URL to answer a successful GET."""
    result = run(lambda: _poll(url, lambda: probes.http_ok(url, timeout=interval), timeout=timeout, interval=interval))
    _finish(url, result)


@wait.command("port")
@click.argument("machine")
@click.argument("port", type=int)
@_wait_options
def port(machine: str, port: int, timeout: float, interval: float) -> None:
    """Wait for MACHINE:PORT to accept a TCP connection."""
    target = resolve_machine(load_manifest(), machine)
    name = f"{target.name}:{port}"
    result = run(
        lambda: _poll(
            name, lambda: probes.tcp_open(target.name, port, timeout=interval), timeout=timeout, interval=interval
        )
    )
    _finish(name, result)


@wait.command("ssh")
@click.argument("machine")
@_wait_options
def ssh(machine: str, timeout: float, interval: float) -> None:
    """Wait until MACHINE answers ``tailscale ssh``."""
    target = resolve_machine(load_manifest(), machine)

    async def probe() -> ProbeResult:
        result = await remote.run(target, "true", timeout=interval)
        status = Status.PASS if result.returncode == 0 else Status.FAIL
        return ProbeResult(target.name, status, f"ssh exit {result.returncode}")

    result = run(lambda: _poll(target.name, probe, timeout=timeout, interval=interval))
    _finish(target.name, result)


@wait.command("share")
@click.argument("machine")
@click.argument("share")
@_wait_options
def share(machine: str, share: str, timeout: float, interval: float) -> None:
    """Wait until SHARE is mounted on MACHINE."""
    target = resolve_machine(load_manifest(), machine)
    result = run(
        lambda: _poll(
            share, lambda: probes.share_mounted(target, share, timeout=interval), timeout=timeout, interval=interval
        )
    )
    _finish(share, result)


@wait.command("service")
@click.argument("machine")
@click.argument("service")
@_wait_options
def service(machine: str, service: str, timeout: float, interval: float) -> None:
    """Wait until SERVICE reports running on MACHINE."""
    target = resolve_machine(load_manifest(), machine)
    svc = resolve_service(target, service)
    probe = _service_probe(target, svc, interval)
    result = run(lambda: _poll(svc.name, probe, timeout=timeout, interval=interval))
    _finish(svc.name, result)
