"""``yclaw doctor`` — ``status`` plus host-vantage checks that a single node cannot self-report.

The extra checks mirror ``scripts/validate-hardening.sh``: the pf gate (host → metal service ports),
metal's share set against the manifest, the hermes container's agent-process + supervisor-marker
health, and a hermes → metal cross-container reachability probe (``python3 urllib`` from inside the
container — the image ships no ``curl``). ``--live`` adds the agent-vault credential-plane checks; the
parts that need a human or a quota-consuming call from hermes are reported ``manual``. Exit is ``1`` if
any hard check fails.
"""

import re

import click

from . import container, output, probes, remote, status
from .dispatch import resolve_machine, run
from .manifest import Machine, load_manifest
from .output import status_label
from .probes import ProbeResult, Status

PROXY_RE = re.compile(r"^HTTPS_PROXY=http://av_agt_[^:]+:hermes@metal:14322")
CHECK_HEADERS = ["CHECK", "STATE", "DETAIL"]
SHARES_ROOT = "/Volumes/My Shared Files"
# root:root 600, ACL-readable by the agent uid — read as the container's default exec user (root).
HERMES_ENV_PATH = "/var/lib/hermes/.hermes/.env"
# The image ships python3 but no curl; urllib raises (nonzero exit) on any non-2xx or transport error.
CROSS_PROBE = 'python3 -c \'import urllib.request; urllib.request.urlopen("http://metal:8000/v1/models",timeout=8)\''


def _metal_ports(metal: Machine) -> list[int]:
    ports = {p for svc in metal.services.values() for p in (svc.port, svc.mitm_port) if p is not None}
    return sorted(ports)


async def _pf_gate(metal: Machine) -> list[ProbeResult]:
    checks = []
    for port in _metal_ports(metal):
        result = await probes.tcp_open("metal", port, timeout=status.PROBE_TIMEOUT)
        checks.append(ProbeResult(f"pf-gate host→metal:{port}", result.status, result.detail))
    return checks


async def _share_diff(metal: Machine) -> ProbeResult:
    # A parent-dir readdir never fires the AppleVirtIOFS automount on Tahoe, so stat each share path
    # directly — that per-path stat is what triggers the mount (mirrors probes.share_mounted). The
    # trailing readdir still catches a share mounted beyond the manifest.
    expected = set(metal.shares or ())
    command = (
        f'for s in {" ".join(sorted(expected))}; do '
        f'[ -e "{SHARES_ROOT}/$s" ] && echo "present $s" || echo "absent $s"; '
        f'done; echo ===; ls -1 "{SHARES_ROOT}"'
    )
    result = await remote.run(metal, command, timeout=status.PROBE_TIMEOUT)
    if result.returncode != 0:
        return ProbeResult("metal shares vs manifest", Status.FAIL, f"share probe exited {result.returncode}")
    lines = result.stdout.splitlines()
    sep = lines.index("===")
    missing = sorted(m.removeprefix("absent ") for m in lines[:sep] if m.startswith("absent "))
    extra = sorted(set(lines[sep + 1 :]) - expected)
    if missing or extra:
        return ProbeResult("metal shares vs manifest", Status.FAIL, f"missing={missing} extra={extra}")
    return ProbeResult("metal shares vs manifest", Status.PASS, f"{len(expected)} shares match the manifest")


async def _hermes_doctor(hermes: Machine) -> list[ProbeResult]:
    # No `hermes doctor` binary in the image: agent-process liveness + the host supervisor marker.
    service = hermes.services["hermes-agent"]
    proc = await probes.container_proc_state(hermes, service, timeout=status.PROBE_TIMEOUT)
    marker = await probes.container_marker_fresh(
        hermes,
        path=probes.container_marker_path(hermes),
        max_age_s=probes.CONTAINER_MARKER_MAX_AGE_S,
        timeout=status.PROBE_TIMEOUT,
    )
    return [
        ProbeResult("hermes agent (container)", proc.status, proc.detail),
        ProbeResult("hermes supervisor marker", marker.status, marker.detail),
    ]


async def _cross_vm_curl(hermes: Machine) -> ProbeResult:
    result = await container.exec_run(hermes.container, CROSS_PROBE, timeout=15)
    passed = result.returncode == 0
    return ProbeResult(
        "hermes→metal:8000 (rapid-mlx)", Status.PASS if passed else Status.FAIL, f"urllib exit {result.returncode}"
    )


async def _proxy_config(hermes: Machine) -> ProbeResult:
    result = await container.exec_run(hermes.container, f"cat {HERMES_ENV_PATH}", timeout=15)
    if any(PROXY_RE.match(line) for line in result.stdout.splitlines()):
        return ProbeResult("agent-vault HTTPS_PROXY", Status.PASS, "routes through av_agt_…@metal:14322")
    return ProbeResult("agent-vault HTTPS_PROXY", Status.FAIL, "not the agent-vault proxy (av_agt_…@metal:14322)")


async def _checks(machines: list[Machine], tailnet: dict[str, ProbeResult], live: bool) -> list[ProbeResult]:
    by_name = {m.name: m for m in machines}
    up = {name for name, node in tailnet.items() if node.status is Status.PASS}
    checks: list[ProbeResult] = []

    if "metal" in by_name:
        checks.extend(await _pf_gate(by_name["metal"]))
        if "metal" in up:
            checks.append(await _share_diff(by_name["metal"]))
    # Container liveness is tailnet_node + a running container: the guest's own tailscaled is what puts
    # it on the tailnet, so `up` (never ssh) gates the host-local `container exec` health checks.
    if "hermes" in by_name and "hermes" in up:
        checks.extend(await _hermes_doctor(by_name["hermes"]))
        checks.append(await _cross_vm_curl(by_name["hermes"]))

    if not live:
        return checks

    if "hermes" in by_name:
        if "hermes" in up:
            checks.append(await _proxy_config(by_name["hermes"]))
        else:
            checks.append(
                ProbeResult(
                    "agent-vault HTTPS_PROXY",
                    Status.MANUAL,
                    "hermes down; verify it routes through av_agt_…@metal:14322",
                )
            )
        checks.append(
            ProbeResult(
                "agent-vault injection round-trip",
                Status.MANUAL,
                "run an Exa/OpenAI call from hermes; expect 200 (bearer injected via metal:14322), not 407",
            )
        )
        checks.append(
            ProbeResult(
                "gmail proxy round-trip",
                Status.MANUAL,
                "`gws` with a dummy token round-trips through agent-vault; the real token never enters hermes",
            )
        )
    if "bluebubbles" in by_name:
        checks.append(
            ProbeResult(
                "bluebubbles send/receive",
                Status.MANUAL,
                "send AND receive an iMessage from an authorized handle (DM + group)",
            )
        )
    return checks


def _fleet(machine: str | None) -> list[Machine]:
    manifest = load_manifest()
    if machine is not None:
        return [resolve_machine(manifest, machine)]
    return list(manifest.machines.values())


@click.command("doctor")
@click.argument("machine", required=False)
@click.option("--live", is_flag=True, help="Also run the agent-vault credential-plane checks.")
def doctor(machine: str | None, live: bool) -> None:
    """Run status plus host-vantage hardening checks for the fleet (or one MACHINE)."""
    machines = _fleet(machine)

    async def diagnose() -> tuple[list[list[str]], list[ProbeResult], list[ProbeResult]]:
        rows, results, tailnet = await status.collect(machines)
        checks = await _checks(machines, tailnet, live)
        return rows, results, checks

    rows, results, checks = run(diagnose)
    click.echo(output.render_table(status.HEADERS, rows))
    click.echo()
    check_rows = [[c.name, status_label(c.status), c.detail] for c in checks]
    click.echo(output.render_table(CHECK_HEADERS, check_rows))

    every = [*results, *checks]
    passes = sum(c.status is Status.PASS for c in every)
    fails = sum(c.status is Status.FAIL for c in every)
    manuals = sum(c.status is Status.MANUAL for c in every)
    click.echo()
    click.echo(f"{output.ok(f'PASS={passes}')}  {output.fail(f'FAIL={fails}')}  {output.manual(f'MANUAL={manuals}')}")
    raise SystemExit(output.exit_code_for(every))
