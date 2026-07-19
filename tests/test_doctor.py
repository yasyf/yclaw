import pytest
from click.testing import CliRunner

from yclaw import container, doctor, probes, remote
from yclaw.cli import main
from yclaw.container import ContainerResult
from yclaw.probes import ProbeResult, Status
from yclaw.remote import RemoteResult

pytestmark = pytest.mark.anyio

# metal's manifest shares, in the sorted order `_share_diff` emits into its `for s in …` probe loop.
METAL_SHARE_NAMES = ("agentvault", "cliproxy", "metalsecrets", "repo")


def _share_probe_stdout(present: tuple[str, ...], listing: tuple[str, ...]) -> str:
    """Reproduce the per-path stat markers + `===` + parent readdir that `_share_diff`'s probe emits."""
    markers = [f"{'present' if s in present else 'absent'} {s}" for s in METAL_SHARE_NAMES]
    return "\n".join([*markers, "===", *listing]) + "\n"


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

    async def fake_proc(machine, service, *, timeout=30):
        state = Status.PASS if machine.name in up_names else Status.FAIL
        return ProbeResult(service.name, state, "proc")

    async def fake_marker(machine, *, path, max_age_s, timeout=30):
        state = Status.PASS if machine.name in up_names else Status.FAIL
        return ProbeResult(f"{machine.name} supervisor", state, "marker")

    monkeypatch.setattr(probes, "tailnet_node", fake_tailnet)
    monkeypatch.setattr(probes, "launchd_state", fake_pass)
    monkeypatch.setattr(probes, "systemd_state", fake_pass)
    monkeypatch.setattr(probes, "service_health", fake_pass)
    monkeypatch.setattr(probes, "share_mounted", fake_share)
    monkeypatch.setattr(probes, "tcp_open", fake_tcp)
    monkeypatch.setattr(probes, "container_proc_state", fake_proc)
    monkeypatch.setattr(probes, "container_marker_fresh", fake_marker)


def test_doctor_metal_runs_pf_gate_and_share_diff(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        assert command.startswith("for s in agentvault cliproxy metalsecrets repo;")
        assert '[ -e "/Volumes/My Shared Files/$s" ]' in command
        return RemoteResult(0, _share_probe_stdout(METAL_SHARE_NAMES, METAL_SHARE_NAMES), "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "metal"])
    assert result.exit_code == 0
    assert "pf-gate host→metal:8000" in result.output
    assert "pf-gate host→metal:14322" in result.output
    assert "metal shares vs manifest" in result.output
    assert "4 shares match the manifest" in result.output


def test_doctor_share_diff_flags_missing(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(0, _share_probe_stdout(("metalsecrets", "repo"), ("metalsecrets", "repo")), "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "metal"])
    assert result.exit_code == 1
    assert "missing=['agentvault', 'cliproxy']" in result.output


@pytest.mark.parametrize(
    ("present", "listing", "expected_status", "expected_detail"),
    [
        (METAL_SHARE_NAMES, METAL_SHARE_NAMES, Status.PASS, "4 shares match the manifest"),
        (METAL_SHARE_NAMES, (), Status.PASS, "4 shares match the manifest"),
        (
            ("metalsecrets", "repo"),
            ("metalsecrets", "repo"),
            Status.FAIL,
            "missing=['agentvault', 'cliproxy'] extra=[]",
        ),
        (
            METAL_SHARE_NAMES,
            (*METAL_SHARE_NAMES, "hermes"),
            Status.FAIL,
            "missing=[] extra=['hermes']",
        ),
    ],
    ids=["all-mounted", "readdir-empty-stat-finds-all", "two-absent", "forbidden-share-in-readdir"],
)
async def test_share_diff_probes_each_path(manifest, monkeypatch, present, listing, expected_status, expected_detail):
    captured = {}

    async def fake_run(machine, command, *, timeout=30, capture=True):
        captured["command"] = command
        return RemoteResult(0, _share_probe_stdout(present, listing), "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = await doctor._share_diff(manifest.machines["metal"])
    # The probe stats each share by its own path (the automount trigger), never a bare parent readdir.
    assert "for s in agentvault cliproxy metalsecrets repo;" in captured["command"]
    assert '[ -e "/Volumes/My Shared Files/$s" ]' in captured["command"]
    assert captured["command"] != "ls -1 '/Volumes/My Shared Files/'"
    assert result.status is expected_status
    assert result.detail == expected_detail


def test_doctor_live_hermes_down_marks_manual(monkeypatch):
    _install_common_probes(monkeypatch, {"metal"})

    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(0, _share_probe_stdout(METAL_SHARE_NAMES, METAL_SHARE_NAMES), "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["doctor", "--live"])
    assert result.exit_code == 1  # hermes + bluebubbles down
    assert "hermes down" in result.output
    assert "agent-vault injection round-trip" in result.output
    assert "gmail proxy round-trip" in result.output
    assert "bluebubbles send/receive" in result.output
    assert "MANUAL=4" in result.output


def test_doctor_live_hermes_up_checks_container_proxy_without_leaking_token(monkeypatch):
    _install_common_probes(monkeypatch, {"hermes"})

    async def fake_exec(name, command, *, timeout=30, uid=None):
        assert name == "hermes"  # container name, never an ssh host
        if "urllib.request" in command:  # cross-container reachability probe (no curl in the image)
            return ContainerResult(0, "", "")
        if command == "cat /var/lib/hermes/.hermes/.env":
            return ContainerResult(0, "FOO=1\nHTTPS_PROXY=http://av_agt_SECRET123:hermes@metal:14322\nBAR=2\n", "")
        raise AssertionError(command)

    monkeypatch.setattr(container, "exec_run", fake_exec)
    result = CliRunner().invoke(main, ["doctor", "hermes", "--live"])
    assert result.exit_code == 0
    assert "agent-vault HTTPS_PROXY" in result.output
    assert "routes through av_agt_…@metal:14322" in result.output
    assert "SECRET123" not in result.output  # only the matched-not-matched verdict prints, never the line
    assert "hermes agent (container)" in result.output  # _hermes_doctor's proc-liveness check
    assert "hermes→metal:8000 (rapid-mlx)" in result.output


def test_doctor_sweeps_host_in_fleet(monkeypatch):
    _install_common_probes(monkeypatch, set())  # every node down
    result = CliRunner().invoke(main, ["doctor"])
    lines = result.output.splitlines()
    # The host joins the status sweep; doctor's host-vantage checks still target metal/hermes only.
    assert any(line.split()[:2] == ["host", "(node)"] for line in lines)


def test_doctor_help():
    result = CliRunner().invoke(main, ["doctor", "--help"])
    assert result.exit_code == 0
    assert "host-vantage" in result.output
