import json
import socket

import httpx
import pytest

from yclaw import keychain, probes
from yclaw.container import ContainerResult
from yclaw.manifest import _parse_service
from yclaw.probes import ProbeResult, Status
from yclaw.remote import RemoteResult

pytestmark = pytest.mark.anyio


def test_parse_launchctl_top_level_only(fixtures_dir):
    text = (fixtures_dir / "launchctl-print-rapid-mlx.txt").read_text()
    fields = probes._parse_launchctl(text)
    assert fields["state"] == "running"
    assert fields["pid"] == "12056"
    assert fields["last exit code"] == "1"
    assert fields["job state"] == "running"
    assert fields["runs"] == "2"


async def test_launchd_state_running_passes(manifest, fixtures_dir, monkeypatch):
    text = (fixtures_dir / "launchctl-print-rapid-mlx.txt").read_text()

    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command == "launchctl print system/org.nixos.rapid-mlx"
        return RemoteResult(0, text, "")

    monkeypatch.setattr(probes.remote, "run", fake_run)
    metal = manifest.machines["metal"]
    result = await probes.launchd_state(metal, metal.services["rapid-mlx"])
    assert result == ProbeResult("rapid-mlx", Status.PASS, "state=running pid=12056 last-exit=1")


async def test_launchd_state_missing_service_fails(manifest, monkeypatch):
    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(113, "", "Could not find service\n")

    monkeypatch.setattr(probes.remote, "run", fake_run)
    metal = manifest.machines["metal"]
    result = await probes.launchd_state(metal, metal.services["rapid-mlx"])
    assert result.status is Status.FAIL
    assert "exited 113" in result.detail


@pytest.mark.parametrize(
    ("show_output", "expected_status", "expected_detail"),
    [
        (
            "ActiveState=active\nSubState=running\nMainPID=4210\nExecMainStatus=0\n",
            Status.PASS,
            "active=active sub=running pid=4210 exit=0",
        ),
        (
            "ActiveState=failed\nSubState=failed\nMainPID=0\nExecMainStatus=1\n",
            Status.FAIL,
            "active=failed sub=failed pid=0 exit=1",
        ),
    ],
    ids=["active", "failed"],
)
async def test_systemd_state(manifest, monkeypatch, show_output, expected_status, expected_detail):
    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command == "systemctl show hermes-agent.service --property=ActiveState,SubState,MainPID,ExecMainStatus"
        return RemoteResult(0, show_output, "")

    monkeypatch.setattr(probes.remote, "run", fake_run)
    # systemd_state is transport-generic; no fleet node runs systemd now, so synthesize the unit.
    service = _parse_service("hermes-agent", {"systemd": "hermes-agent.service"})
    result = await probes.systemd_state(manifest.machines["metal"], service)
    assert result == ProbeResult("hermes-agent", expected_status, expected_detail)


@pytest.mark.parametrize(
    ("share", "returncode", "expected_status"),
    [("repo", 0, Status.PASS), ("agentvault", 1, Status.FAIL)],
    ids=["mounted", "absent"],
)
async def test_share_mounted(manifest, monkeypatch, share, returncode, expected_status):
    captured = {}

    async def fake_run(machine, command, *, timeout=30, capture=True):
        captured["command"] = command
        return RemoteResult(returncode, "", "")

    monkeypatch.setattr(probes.remote, "run", fake_run)
    result = await probes.share_mounted(manifest.machines["metal"], share)
    assert captured["command"] == f"ls -d '/Volumes/My Shared Files/{share}'"
    assert result.status is expected_status


def test_find_node_online_offline_missing(fixtures_dir):
    status = json.loads((fixtures_dir / "tailscale-status.json").read_text())
    assert probes._find_node(status, "metal")["Online"] is True
    assert probes._find_node(status, "hermes")["Online"] is False
    assert probes._find_node(status, "not-a-node") is None


@pytest.mark.parametrize(
    ("name", "ping_ok", "expected_status", "detail_needle"),
    [
        ("metal", True, Status.PASS, "online, ping ok"),
        ("metal", False, Status.PASS, "online, ping failed (derp-only or stale disco)"),
        ("hermes", True, Status.FAIL, "offline"),
        ("not-a-node", True, Status.FAIL, "not in tailnet"),
    ],
    ids=["online-ping-ok", "online-ping-fail-degraded", "registered-offline", "absent"],
)
async def test_tailnet_node(fixtures_dir, monkeypatch, name, ping_ok, expected_status, detail_needle):
    status = json.loads((fixtures_dir / "tailscale-status.json").read_text())

    async def fake_status(timeout):
        return status

    async def fake_ping(node, timeout):
        return ping_ok

    monkeypatch.setattr(probes, "_tailscale_status", fake_status)
    monkeypatch.setattr(probes, "_tailscale_ping", fake_ping)
    result = await probes.tailnet_node(name)
    assert result.status is expected_status
    assert detail_needle in result.detail


async def test_tailnet_node_self_skips_ping(fixtures_dir, monkeypatch):
    # The Self node is this host — pinging our own tailnet IP always succeeds and says nothing about
    # reachability, so it is skipped and the row reports "online (self)".
    status = json.loads((fixtures_dir / "tailscale-status.json").read_text())

    async def fake_status(timeout):
        return status

    pinged = False

    async def fake_ping(node, timeout):
        nonlocal pinged
        pinged = True
        return True

    monkeypatch.setattr(probes, "_tailscale_status", fake_status)
    monkeypatch.setattr(probes, "_tailscale_ping", fake_ping)
    result = await probes.tailnet_node("yclaw-host")
    assert result == ProbeResult("yclaw-host", Status.PASS, "online (self)")
    assert pinged is False


@pytest.mark.parametrize(
    ("code", "expected_status"),
    [(200, Status.PASS), (204, Status.PASS), (503, Status.FAIL), (404, Status.FAIL)],
    ids=["200", "204", "503", "404"],
)
async def test_http_ok(code, expected_status):
    def handler(request):
        return httpx.Response(code)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.http_ok("http://metal:8000/v1/models", client=client)
    assert result == ProbeResult("http://metal:8000/v1/models", expected_status, f"HTTP {code}")


async def test_http_ok_connection_error_is_fail():
    def handler(request):
        raise httpx.ConnectError("refused")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.http_ok("http://down:1/x", client=client)
    assert result.status is Status.FAIL
    assert "ConnectError" in result.detail


@pytest.mark.parametrize(
    ("helper_connected", "expected_status"),
    [(True, Status.PASS), (False, Status.FAIL)],
    ids=["connected", "disconnected"],
)
async def test_bluebubbles_health(manifest, monkeypatch, helper_connected, expected_status):
    monkeypatch.setattr(keychain, "read", lambda service: "bb-pw")

    async def fake_status(timeout):
        return {"MagicDNSSuffix": "tail1234.ts.net"}

    monkeypatch.setattr(probes, "_tailscale_status", fake_status)
    seen_paths = []

    def handler(request):
        seen_paths.append(request.url.path)
        assert request.url.params["password"] == "bb-pw"
        if request.url.path.endswith("/ping"):
            return httpx.Response(200, json={"status": 200})
        if request.url.path.endswith("/server/info"):
            return httpx.Response(200, json={"data": {"helper_connected": helper_connected}})
        raise AssertionError(request.url)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.bluebubbles_health(manifest.machines["bluebubbles"], client=client)
    assert result.status is expected_status
    assert seen_paths == ["/api/v1/ping", "/api/v1/server/info"]


async def test_bluebubbles_health_ping_failure_short_circuits(manifest, monkeypatch):
    monkeypatch.setattr(keychain, "read", lambda service: "bb-pw")

    async def fake_status(timeout):
        return {"MagicDNSSuffix": "tail1234.ts.net"}

    monkeypatch.setattr(probes, "_tailscale_status", fake_status)
    seen_paths = []

    def handler(request):
        seen_paths.append(request.url.path)
        return httpx.Response(500)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.bluebubbles_health(manifest.machines["bluebubbles"], client=client)
    assert result.status is Status.FAIL
    assert seen_paths == ["/api/v1/ping"]


async def test_bluebubbles_health_upgrades_bare_host_to_fqdn(manifest, monkeypatch):
    monkeypatch.setattr(keychain, "read", lambda service: "bb-pw")

    async def fake_status(timeout):
        return {"MagicDNSSuffix": "tail1234.ts.net"}

    monkeypatch.setattr(probes, "_tailscale_status", fake_status)
    seen_urls = []

    def handler(request):
        seen_urls.append(request.url)
        if request.url.path.endswith("/ping"):
            return httpx.Response(200, json={"status": 200})
        return httpx.Response(200, json={"data": {"helper_connected": True}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.bluebubbles_health(manifest.machines["bluebubbles"], client=client)
    assert result.status is Status.PASS
    assert {url.host for url in seen_urls} == {"bluebubbles.tail1234.ts.net"}
    assert [str(url) for url in seen_urls] == [
        "https://bluebubbles.tail1234.ts.net/api/v1/ping?password=bb-pw",
        "https://bluebubbles.tail1234.ts.net/api/v1/server/info?password=bb-pw",
    ]


async def test_bluebubbles_health_keychain_error_is_fail(manifest, monkeypatch):
    def boom(service):
        raise keychain.KeychainError(f"keychain item {service!r} not found — run 'just bootstrap' first")

    monkeypatch.setattr(keychain, "read", boom)
    result = await probes.bluebubbles_health(manifest.machines["bluebubbles"])
    assert result.name == "bluebubbles"
    assert result.status is Status.FAIL
    assert "keychain" in result.detail


async def test_tcp_open_reachable_then_closed():
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    try:
        opened = await probes.tcp_open("127.0.0.1", port)
        assert opened == ProbeResult(f"127.0.0.1:{port}", Status.PASS, "open")
    finally:
        listener.close()

    closed = await probes.tcp_open("127.0.0.1", port)
    assert closed.status is Status.FAIL


@pytest.mark.parametrize(
    ("last_exit", "expected_status"),
    [("0", Status.PASS), ("1", Status.FAIL)],
    ids=["oneshot-clean-exit", "oneshot-failed-exit"],
)
async def test_launchd_state_oneshot_uses_last_exit(manifest, monkeypatch, last_exit, expected_status):
    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command == "launchctl print system/org.nixos.metal-boot-setup"
        return RemoteResult(0, f"\tstate = not running\n\tlast exit code = {last_exit}\n", "")

    monkeypatch.setattr(probes.remote, "run", fake_run)
    metal = manifest.machines["metal"]
    result = await probes.launchd_state(metal, metal.services["metal-boot-setup"])
    assert result.status is expected_status
    assert f"last-exit={last_exit}" in result.detail


async def test_service_health_http_dispatches(manifest):
    def handler(request):
        assert request.url.path == "/v1/models"
        return httpx.Response(200)

    metal = manifest.machines["metal"]
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probes.service_health(metal, metal.services["rapid-mlx"], client=client)
    assert result == ProbeResult("http://metal:8000/v1/models", Status.PASS, "HTTP 200")


async def test_service_health_tcp_dispatches(manifest, monkeypatch):
    seen = {}

    async def fake_tcp(host, port, *, timeout=5):
        seen["host"] = host
        seen["port"] = port
        return ProbeResult(f"{host}:{port}", Status.PASS, "open")

    monkeypatch.setattr(probes, "tcp_open", fake_tcp)
    metal = manifest.machines["metal"]
    result = await probes.service_health(metal, metal.services["mlx-audio"])
    assert seen == {"host": "metal", "port": 8765}
    assert result.status is Status.PASS


async def test_service_health_bluebubbles_dispatches(manifest, monkeypatch):
    async def fake_bb(machine, *, timeout=10, client=None):
        return ProbeResult("bluebubbles", Status.PASS, "ping ok, helper_connected=True")

    monkeypatch.setattr(probes, "bluebubbles_health", fake_bb)
    bb = manifest.machines["bluebubbles"]
    result = await probes.service_health(bb, bb.services["bluebubbles"])
    assert result == ProbeResult("bluebubbles", Status.PASS, "ping ok, helper_connected=True")


@pytest.mark.parametrize(
    ("rc", "expected_status", "expected_detail"),
    [(0, Status.PASS, "process alive"), (1, Status.FAIL, "no process matching 'hermes gateway run'")],
    ids=["alive", "dead"],
)
async def test_container_proc_state(monkeypatch, container_machine, rc, expected_status, expected_detail):
    seen = {}

    async def fake_exec(name, command, *, timeout=30, uid=None):
        seen["name"] = name
        seen["command"] = command
        return ContainerResult(rc, "", "")

    monkeypatch.setattr(probes.container, "exec_run", fake_exec)
    result = await probes.container_proc_state(container_machine, container_machine.services["hermes-agent"])
    assert seen["name"] == "hermes"
    # A pure-sh /proc scan that skips its own shell — grep/pgrep are absent from the image, and an
    # un-skipped scan matches its own cmdline (which carries the needle) and never sees a dead agent.
    assert 'case "$f" in "/proc/$$/cmdline") continue;;' in seen["command"]
    assert '*"hermes gateway run"*' in seen["command"]
    assert "grep" not in seen["command"]
    assert "pgrep" not in seen["command"]
    assert result == ProbeResult("hermes-agent", expected_status, expected_detail)


@pytest.mark.parametrize(
    ("age_s", "expected_status", "expected_detail"),
    [(30, Status.PASS, "fresh (30s old)"), (600, Status.FAIL, "stale (600s old)")],
    ids=["fresh", "stale"],
)
async def test_container_marker_fresh(
    tmp_path, monkeypatch, container_machine, age_s, expected_status, expected_detail
):
    now = 1_000_000.0
    marker = tmp_path / "container-hermes.last-ok"
    marker.write_text(f"{now - age_s}\n")
    monkeypatch.setattr(probes, "_now", lambda: now)
    result = await probes.container_marker_fresh(container_machine, path=marker, max_age_s=180)
    assert result == ProbeResult("hermes supervisor", expected_status, expected_detail)


async def test_container_marker_fresh_absent_is_fail(tmp_path, monkeypatch, container_machine):
    marker = tmp_path / "container-hermes.last-ok"  # never written
    monkeypatch.setattr(probes, "_now", lambda: 1_000_000.0)
    result = await probes.container_marker_fresh(container_machine, path=marker, max_age_s=180)
    assert result.name == "hermes supervisor"
    assert result.status is Status.FAIL
    assert result.detail == f"absent: {marker}"


def test_container_marker_path_matches_supervisor_convention(container_machine):
    path = probes.container_marker_path(container_machine)
    assert str(path).endswith("Library/Logs/yclaw/container-hermes.last-ok")
