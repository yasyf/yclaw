"""Async health probes over the fleet, each returning a uniform ``ProbeResult``.

A probe never raises for an *expected* negative — an unreachable endpoint, an offline node, or a
stopped service is a ``FAIL`` result, not an exception. ``tailnet_node`` runs the local
``tailscale`` CLI; the launchd/systemd/share probes go through the ``remote`` chokepoint; the HTTP
probes take an optional injected ``httpx.AsyncClient`` so tests can drive them with a
``MockTransport``. Secrets read for a probe (the BlueBubbles password) travel as query params and
are never logged.
"""

import json
import shlex
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from enum import Enum
from typing import Any

import anyio
import httpx

from . import keychain, remote
from .manifest import HttpHealth, Machine, Service


class Status(Enum):
    PASS = "pass"
    FAIL = "fail"
    MANUAL = "manual"


@dataclass(frozen=True, slots=True)
class ProbeResult:
    name: str
    status: Status
    detail: str


@asynccontextmanager
async def _http_client(client: httpx.AsyncClient | None, timeout: float) -> AsyncIterator[httpx.AsyncClient]:
    if client is not None:
        yield client
    else:
        async with httpx.AsyncClient(timeout=timeout) as owned:
            yield owned


def _parse_launchctl(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if not line.startswith("\t") or line.startswith("\t\t") or " = " not in line:
            continue
        key, _, value = line.strip().partition(" = ")
        fields.setdefault(key, value)
    return fields


def _parse_key_value(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            fields[key] = value
    return fields


def _find_node(status: dict[str, Any], name: str) -> dict[str, Any] | None:
    peers = (status.get("Peer") or {}).values()
    for node in (status.get("Self"), *peers):
        if node is None:
            continue
        dns_label = (node.get("DNSName") or "").split(".", 1)[0]
        if node.get("HostName") == name or dns_label == name:
            return node
    return None


async def _tailscale_status(timeout: float) -> dict[str, Any]:
    with anyio.fail_after(timeout):
        completed = await anyio.run_process(["tailscale", "status", "--json"], check=True)
    return json.loads(completed.stdout)


async def _tailscale_ping(name: str, timeout: float) -> bool:
    try:
        with anyio.fail_after(timeout):
            completed = await anyio.run_process(["tailscale", "ping", "-c", "1", name], check=False)
    except TimeoutError:
        return False
    return completed.returncode == 0


async def http_ok(url: str, *, timeout: float = 10, client: httpx.AsyncClient | None = None) -> ProbeResult:
    try:
        async with _http_client(client, timeout) as c:
            resp = await c.get(url)
    except httpx.RequestError as exc:
        return ProbeResult(url, Status.FAIL, f"{type(exc).__name__}: {exc}")
    return ProbeResult(url, Status.PASS if resp.is_success else Status.FAIL, f"HTTP {resp.status_code}")


async def tcp_open(host: str, port: int, *, timeout: float = 5) -> ProbeResult:
    target = f"{host}:{port}"
    try:
        with anyio.fail_after(timeout):
            stream = await anyio.connect_tcp(host, port)
        await stream.aclose()
    except (OSError, TimeoutError) as exc:
        return ProbeResult(target, Status.FAIL, f"{type(exc).__name__}: {exc}")
    return ProbeResult(target, Status.PASS, "open")


async def tailnet_node(name: str, *, timeout: float = 10) -> ProbeResult:
    node = _find_node(await _tailscale_status(timeout), name)
    if node is None:
        return ProbeResult(name, Status.FAIL, "not in tailnet")
    if not node.get("Online"):
        return ProbeResult(name, Status.FAIL, "registered but offline")
    reachable = await _tailscale_ping(name, timeout)
    detail = "online, ping ok" if reachable else "online, ping failed"
    return ProbeResult(name, Status.PASS if reachable else Status.FAIL, detail)


async def launchd_state(machine: Machine, service: Service, *, timeout: float = 30) -> ProbeResult:
    target = service.launchd.target
    result = await remote.run(machine, f"launchctl print {target}", timeout=timeout)
    if result.returncode != 0:
        return ProbeResult(service.name, Status.FAIL, f"launchctl print {target} exited {result.returncode}")
    fields = _parse_launchctl(result.stdout)
    state = fields.get("state")
    last_exit = fields.get("last exit code")
    detail = f"state={state} pid={fields.get('pid')} last-exit={last_exit}"
    healthy = last_exit == "0" if service.oneshot else state == "running"
    return ProbeResult(service.name, Status.PASS if healthy else Status.FAIL, detail)


async def systemd_state(machine: Machine, service: Service, *, timeout: float = 30) -> ProbeResult:
    unit = service.systemd
    cmd = f"systemctl show {unit} --property=ActiveState,SubState,MainPID,ExecMainStatus"
    result = await remote.run(machine, cmd, timeout=timeout)
    if result.returncode != 0:
        return ProbeResult(service.name, Status.FAIL, f"systemctl show {unit} exited {result.returncode}")
    fields = _parse_key_value(result.stdout)
    active = fields.get("ActiveState")
    detail = (
        f"active={active} sub={fields.get('SubState')} pid={fields.get('MainPID')} exit={fields.get('ExecMainStatus')}"
    )
    return ProbeResult(service.name, Status.PASS if active == "active" else Status.FAIL, detail)


async def share_mounted(machine: Machine, share: str, *, timeout: float = 30) -> ProbeResult:
    """macOS-guest only: shares mount at /Volumes/My Shared Files/<name> (Linux guests use fstab virtiofs paths)."""
    path = f"/Volumes/My Shared Files/{share}"
    result = await remote.run(machine, f"ls -d {shlex.quote(path)}", timeout=timeout)
    mounted = result.returncode == 0
    return ProbeResult(share, Status.PASS if mounted else Status.FAIL, path if mounted else f"not mounted: {path}")


async def bluebubbles_health(
    machine: Machine, *, timeout: float = 10, client: httpx.AsyncClient | None = None
) -> ProbeResult:
    service = machine.services["bluebubbles"]
    try:
        password = keychain.read(service.password_keychain)
    except keychain.KeychainError as exc:
        return ProbeResult("bluebubbles", Status.FAIL, f"keychain read failed: {exc}")
    params = {service.password_query_param: password}
    ping_url = service.health.url
    info_url = f"{ping_url.rsplit('/', 1)[0]}/server/info"
    try:
        async with _http_client(client, timeout) as c:
            ping = await c.get(ping_url, params=params)
            if not ping.is_success:
                return ProbeResult("bluebubbles", Status.FAIL, f"ping HTTP {ping.status_code}")
            info = await c.get(info_url, params=params)
    except httpx.RequestError as exc:
        return ProbeResult("bluebubbles", Status.FAIL, f"{type(exc).__name__}: {exc}")
    if not info.is_success:
        return ProbeResult("bluebubbles", Status.FAIL, f"server/info HTTP {info.status_code}")
    connected = info.json().get("data", {}).get("helper_connected")
    if connected is None:
        return ProbeResult("bluebubbles", Status.MANUAL, "helper_connected absent from server/info")
    status = Status.PASS if connected else Status.FAIL
    return ProbeResult("bluebubbles", status, f"ping ok, helper_connected={connected}")


async def service_health(
    machine: Machine, service: Service, *, timeout: float = 10, client: httpx.AsyncClient | None = None
) -> ProbeResult:
    health = service.health
    if machine.name == "bluebubbles":
        return await bluebubbles_health(machine, timeout=timeout, client=client)
    if isinstance(health, HttpHealth):
        return await http_ok(health.url, timeout=timeout, client=client)
    return await tcp_open(health.host, health.port, timeout=timeout)
