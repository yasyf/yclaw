import anyio
import pytest
from click.testing import CliRunner

from yclaw import probes, remote, wait
from yclaw.cli import main
from yclaw.manifest import _parse_service
from yclaw.probes import ProbeResult, Status
from yclaw.remote import RemoteResult


def _probe(status, detail="detail"):
    async def fake(*args, **kwargs):
        return ProbeResult("x", status, detail)

    return fake


def test_wait_http_success_exits_clean(monkeypatch):
    monkeypatch.setattr(probes, "http_ok", _probe(Status.PASS, "HTTP 200"))
    result = CliRunner().invoke(main, ["wait", "http", "http://metal:8000/v1/models"])
    assert result.exit_code == 0
    assert "ok" in result.output
    assert "HTTP 200" in result.output


def test_wait_http_exhaustion_is_fatal_exit_1(monkeypatch):
    monkeypatch.setattr(probes, "http_ok", _probe(Status.FAIL, "HTTP 503"))
    result = CliRunner().invoke(
        main, ["wait", "http", "http://metal:8000/v1/models", "--timeout", "0", "--interval", "0"]
    )
    assert result.exit_code == 1
    assert "FATAL" in result.stderr
    assert "HTTP 503" in result.stderr


def test_wait_port_probes_machine_and_port(monkeypatch):
    seen = {}

    async def fake_tcp(host, port, *, timeout=5):
        seen["host"] = host
        seen["port"] = port
        seen["timeout"] = timeout
        return ProbeResult(f"{host}:{port}", Status.PASS, "open")

    monkeypatch.setattr(probes, "tcp_open", fake_tcp)
    result = CliRunner().invoke(main, ["wait", "port", "metal", "8000", "--interval", "1"])
    assert result.exit_code == 0
    assert seen == {"host": "metal", "port": 8000, "timeout": 5}


@pytest.mark.parametrize(
    ("interval", "expected_timeout"),
    [("2", 10.0), ("20", 20.0)],
    ids=["floor-applies", "interval-above-floor"],
)
def test_wait_ssh_probe_timeout_decoupled_from_interval(monkeypatch, interval, expected_timeout):
    seen = {}

    async def fake_run(machine, command, *, timeout=30, capture=True):
        seen["command"] = command
        seen["timeout"] = timeout
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["wait", "ssh", "metal", "--interval", interval])
    assert result.exit_code == 0
    assert seen == {"command": "true", "timeout": expected_timeout}


def test_wait_port_host_resolves_tailnet_name(monkeypatch):
    # The host's manifest key `host` is not resolvable — the TCP probe must target its tailnet name.
    seen = {}

    async def fake_tcp(host, port, *, timeout=5):
        seen["host"] = host
        seen["port"] = port
        return ProbeResult(f"{host}:{port}", Status.PASS, "open")

    monkeypatch.setattr(probes, "tcp_open", fake_tcp)
    result = CliRunner().invoke(main, ["wait", "port", "host", "8000"])
    assert result.exit_code == 0
    assert seen == {"host": "yasyf-home", "port": 8000}


def test_wait_ssh_host_is_usage_error():
    # The host runs its own commands locally — there is no tailscale-ssh session to wait for.
    result = CliRunner().invoke(main, ["wait", "ssh", "host"])
    assert result.exit_code == 2
    assert "there is no ssh to wait for" in result.output


def test_wait_ssh_success(monkeypatch):
    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command == "true"
        assert machine.name == "metal"
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["wait", "ssh", "metal"])
    assert result.exit_code == 0


def test_wait_share_success(monkeypatch):
    seen = {}

    async def fake_share(machine, share, *, timeout=30):
        seen["share"] = share
        return ProbeResult(share, Status.PASS, "/Volumes/My Shared Files/repo")

    monkeypatch.setattr(probes, "share_mounted", fake_share)
    result = CliRunner().invoke(main, ["wait", "share", "metal", "repo"])
    assert result.exit_code == 0
    assert seen == {"share": "repo"}


def test_wait_service_polls_launchd_state(monkeypatch):
    seen = {}

    async def fake_launchd(machine, service, *, timeout=30):
        seen["service"] = service.name
        return ProbeResult(service.name, Status.PASS, "state=running")

    monkeypatch.setattr(probes, "launchd_state", fake_launchd)
    result = CliRunner().invoke(main, ["wait", "service", "metal", "rapid-mlx"])
    assert result.exit_code == 0
    assert seen == {"service": "rapid-mlx"}


def test_wait_service_polls_container_proc(monkeypatch):
    seen = {}

    async def fake_proc(machine, service, *, timeout=30):
        seen["machine"] = machine.name
        seen["service"] = service.name
        return ProbeResult(service.name, Status.PASS, "process alive")

    monkeypatch.setattr(probes, "container_proc_state", fake_proc)
    result = CliRunner().invoke(main, ["wait", "service", "hermes", "hermes-agent"])
    assert result.exit_code == 0
    assert seen == {"machine": "hermes", "service": "hermes-agent"}


@pytest.mark.parametrize(
    "probe_name",
    ["systemd_state", "container_proc_state"],
    ids=["systemd", "container"],
)
def test_wait_service_probe_selects_by_unit_kind(manifest, monkeypatch, probe_name):
    # _service_probe picks the probe by unit kind; the systemd branch is no longer manifest-reachable
    # (no node runs systemd), so exercise the selector directly with a synthesized unit.
    if probe_name == "systemd_state":
        service_def = {"systemd": "x.service"}
    else:
        service_def = {"container_proc": "hermes gateway run"}
    called = {}

    async def fake(machine, service, *, timeout=30):
        called["probe"] = probe_name
        called["service"] = service.name
        return ProbeResult(service.name, Status.PASS, "up")

    monkeypatch.setattr(probes, probe_name, fake)
    svc = _parse_service("hermes-agent", service_def)
    result = anyio.run(wait._service_probe(manifest.machines["metal"], svc, interval=2.0))
    assert result.status is Status.PASS
    assert called == {"probe": probe_name, "service": "hermes-agent"}


def test_wait_service_without_unit_is_usage_error():
    result = CliRunner().invoke(main, ["wait", "service", "bluebubbles", "bluebubbles"])
    assert result.exit_code == 2
    assert "no launchd/systemd" in result.output


def test_wait_unknown_service_is_usage_error():
    result = CliRunner().invoke(main, ["wait", "service", "metal", "nope"])
    assert result.exit_code == 2
    assert "unknown service 'nope'" in result.output


def test_wait_help():
    result = CliRunner().invoke(main, ["wait", "--help"])
    assert result.exit_code == 0
    assert "Block until an endpoint or service is up" in result.output
