"""``yclaw status`` — one concurrent sweep of the fleet, rendered as a single table.

Every probe (tailnet reachability, each launchd/systemd unit, each health endpoint, each metal share)
runs inside one task group under an 8-second per-probe timeout. A node that is absent or offline is
reported as ``down`` and its per-service probes are skipped rather than left to time out.
"""

from collections.abc import Awaitable, Callable
from functools import partial

import anyio
import click

from . import output, probes
from .dispatch import resolve_machine, run
from .manifest import Machine, Service, load_manifest
from .output import exit_code_for, status_label
from .probes import ProbeResult, Status
from .remote import RemoteTimeout

PROBE_TIMEOUT = 8.0
SSH_PROBE_CONCURRENCY = 4
HEADERS = ["MACHINE", "SERVICE", "STATE", "HEALTH", "DETAIL"]

type Probe = Callable[..., Awaitable[ProbeResult]]


def _limited(limiter: anyio.CapacityLimiter, probe: Probe) -> Probe:
    async def bounded() -> ProbeResult:
        async with limiter:
            return await probe()

    return bounded


def _key_name[K](key: K) -> str:
    return str(key[-1]) if isinstance(key, tuple) else str(key)


async def _gather[K](labeled: list[tuple[K, Probe]]) -> dict[K, ProbeResult]:
    out: dict[K, ProbeResult] = {}
    async with anyio.create_task_group() as tg:
        for key, probe in labeled:

            async def worker(key: K = key, probe: Probe = probe) -> None:
                try:
                    out[key] = await probe()
                except RemoteTimeout as exc:
                    out[key] = ProbeResult(_key_name(key), Status.FAIL, f"timed out after {exc.timeout}s")

            tg.start_soon(worker)
    return out


def _state_probe(machine: Machine, service: Service) -> Probe | None:
    if service.launchd is not None:
        return partial(probes.launchd_state, machine, service, timeout=PROBE_TIMEOUT)
    if service.systemd is not None:
        return partial(probes.systemd_state, machine, service, timeout=PROBE_TIMEOUT)
    return None


async def collect(machines: list[Machine]) -> tuple[list[list[str]], list[ProbeResult], dict[str, ProbeResult]]:
    tailnet = await _gather([(m.name, partial(probes.tailnet_node, m.name, timeout=PROBE_TIMEOUT)) for m in machines])

    # Bound the ssh-based probes per host: an unbounded fan-out opens one tailscale-ssh session per
    # probe, and a dozen simultaneous handshakes to one sshd make healthy probes exceed their timeout.
    limiters = {m.name: anyio.CapacityLimiter(SSH_PROBE_CONCURRENCY) for m in machines}
    tasks: list[tuple[tuple[str, str, str], Probe]] = []
    for machine in machines:
        if tailnet[machine.name].status is not Status.PASS:
            continue
        limiter = limiters[machine.name]
        for service in machine.services.values():
            state = _state_probe(machine, service)
            if state is not None:
                tasks.append((("state", machine.name, service.name), _limited(limiter, state)))
            if service.health is not None:
                tasks.append(
                    (
                        ("health", machine.name, service.name),
                        partial(probes.service_health, machine, service, timeout=PROBE_TIMEOUT),
                    )
                )
        if machine.os == "macos":
            for share in machine.shares or ():
                probe = partial(probes.share_mounted, machine, share, timeout=PROBE_TIMEOUT)
                tasks.append((("share", machine.name, share), _limited(limiter, probe)))
    probed = await _gather(tasks)

    rows: list[list[str]] = []
    results: list[ProbeResult] = []
    for machine in machines:
        node = tailnet[machine.name]
        results.append(node)
        rows.append([machine.name, "(node)", "up" if node.status is Status.PASS else "down", "—", node.detail])
        if node.status is not Status.PASS:
            continue
        for service in machine.services.values():
            state_key = ("state", machine.name, service.name)
            health_key = ("health", machine.name, service.name)
            if state_key not in probed and health_key not in probed:
                continue
            details = []
            state_cell = "—"
            if state_key in probed:
                result = probed[state_key]
                results.append(result)
                state_cell = status_label(result.status)
                details.append(result.detail)
            health_cell = "—"
            if health_key in probed:
                result = probed[health_key]
                results.append(result)
                health_cell = status_label(result.status)
                details.append(result.detail)
            rows.append([machine.name, service.name, state_cell, health_cell, "; ".join(details)])
        if machine.os == "macos":
            for share in machine.shares or ():
                result = probed[("share", machine.name, share)]
                results.append(result)
                rows.append([machine.name, f"share:{share}", status_label(result.status), "—", result.detail])
    return rows, results, tailnet


def _fleet(machine: str | None) -> list[Machine]:
    manifest = load_manifest()
    if machine is not None:
        return [resolve_machine(manifest, machine)]
    return [m for m in manifest.machines.values() if m.ssh is not None]


@click.command("status")
@click.argument("machine", required=False)
def status(machine: str | None) -> None:
    """Show tailnet, service, health, and share state for the fleet (or one MACHINE)."""
    machines = _fleet(machine)
    rows, results, _ = run(lambda: collect(machines))
    click.echo(output.render_table(HEADERS, rows))
    raise SystemExit(exit_code_for(results))
