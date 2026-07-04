from click.testing import CliRunner

from yclaw import probes, remote
from yclaw.cli import main
from yclaw.probes import ProbeResult, Status
from yclaw.remote import RemoteResult

METAL_SHARES = "metalsecrets\nagentvault\nhfhub\nmlxaudio\ncliproxy\nrepo\n"


def _install_common_probes(monkeypatch, up_names):
    async def fake_tailnet(name, *, timeout=10):
        state = Status.PASS if name in up_names else Status.FAIL
        detail = "online, ping ok" if name in up_names else "registered but offline"
        return ProbeResult(name, state, detail)

    async def fake_pass(machine, service, *, timeout=30, client=None):
        return ProbeResult(service.name, Status.PASS, "ok")

    async def fake_share(machine, share, *, timeout=30):
        return ProbeResult(share, Status.PASS, "mounted")

    async def fake_tcp(host, port, *, timeout=5):
        return ProbeResult(f"{host}:{port}", Status.PASS, "open")

    monkeypatch.setattr(probes, "tailnet_node", fake_tailnet)
    monkeypatch.setattr(probes, "launchd_state", fake_pass)
    monkeypatch.setattr(probes, "systemd_state", fake_pass)
    monkeypatch.setattr(probes, "service_health", fake_pass)
    monkeypatch.setattr(probes, "share_mounted", fake_share)
    monkeypatch.setattr(probes, "tcp_open", fake_tcp)


def test_doctor_metal_runs_pf_gate_and_share_diff(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command == "ls -1 '/Volumes/My Shared Files/'"
        return RemoteResult(0, METAL_SHARES, "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "metal"])
    assert result.exit_code == 0
    assert "pf-gate host→metal:8000" in result.output
    assert "pf-gate host→metal:14322" in result.output
    assert "metal shares vs manifest" in result.output
    assert "6 shares match the manifest" in result.output


def test_doctor_share_diff_flags_missing(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(0, "metalsecrets\nrepo\n", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "metal"])
    assert result.exit_code == 1
    assert "missing=['agentvault', 'cliproxy', 'hfhub', 'mlxaudio']" in result.output


def test_doctor_live_hermes_down_marks_manual(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(0, METAL_SHARES, "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "--live"])
    assert result.exit_code == 1  # hermes + bluebubbles down
    assert "hermes down" in result.output
    assert "agent-vault injection round-trip" in result.output
    assert "gmail proxy round-trip" in result.output
    assert "bluebubbles send/receive" in result.output
    assert "MANUAL=4" in result.output


def test_doctor_live_hermes_up_checks_proxy_without_leaking_token(monkeypatch):
    _install_common_probes(monkeypatch, {"hermes"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        if command == "hermes doctor":
            return RemoteResult(0, "all checks passed\n", "")
        if command.startswith("curl -sf"):
            return RemoteResult(0, "", "")
        if "HTTPS_PROXY" in command:
            return RemoteResult(0, "HTTPS_PROXY=http://av_agt_SECRET123:hermes@metal:14322\n", "")
        raise AssertionError(command)

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "hermes", "--live"])
    assert result.exit_code == 0
    assert "agent-vault HTTPS_PROXY" in result.output
    assert "routes through av_agt_…@metal:14322" in result.output
    assert "SECRET123" not in result.output
    assert "hermes doctor" in result.output
    assert "hermes→metal:8000 (omlx)" in result.output


def test_doctor_help():
    result = CliRunner().invoke(main, ["doctor", "--help"])
    assert result.exit_code == 0
    assert "host-vantage" in result.output
