from click.testing import CliRunner

from yclaw import output, probes, status
from yclaw.cli import main
from yclaw.probes import ProbeResult, Status

DASH = "—"


def _install_metal_probes(monkeypatch, *, hermes_up=False, bluebubbles_up=False):
    up_names = {"metal"}
    if hermes_up:
        up_names.add("hermes")
    if bluebubbles_up:
        up_names.add("bluebubbles")

    async def fake_tailnet(name, *, timeout=10):
        if name in up_names:
            return ProbeResult(name, Status.PASS, "online, ping ok")
        return ProbeResult(name, Status.FAIL, "registered but offline")

    async def fake_launchd(machine, service, *, timeout=30):
        state = Status.FAIL if service.name == "cliproxy" else Status.PASS
        return ProbeResult(service.name, state, f"st-{service.name}")

    async def fake_systemd(machine, service, *, timeout=30):
        return ProbeResult(service.name, Status.PASS, f"sd-{service.name}")

    async def fake_health(machine, service, *, timeout=10, client=None):
        state = Status.FAIL if service.name == "mlx-audio" else Status.PASS
        return ProbeResult(service.name, state, f"hp-{service.name}")

    async def fake_share(machine, share, *, timeout=30):
        return ProbeResult(share, Status.PASS, f"sh-{share}")

    monkeypatch.setattr(probes, "tailnet_node", fake_tailnet)
    monkeypatch.setattr(probes, "launchd_state", fake_launchd)
    monkeypatch.setattr(probes, "systemd_state", fake_systemd)
    monkeypatch.setattr(probes, "service_health", fake_health)
    monkeypatch.setattr(probes, "share_mounted", fake_share)


def test_status_metal_renders_exact_table(monkeypatch):
    _install_metal_probes(monkeypatch)
    result = CliRunner().invoke(main, ["status", "metal"])

    expected_rows = [
        ["metal", "(node)", "up", DASH, "online, ping ok"],
        ["metal", "omlx", "ok", "ok", "st-omlx; hp-omlx"],
        ["metal", "mlx-audio", "ok", "fail", "st-mlx-audio; hp-mlx-audio"],
        ["metal", "cliproxy", "fail", "ok", "st-cliproxy; hp-cliproxy"],
        ["metal", "agent-vault", "ok", "ok", "st-agent-vault; hp-agent-vault"],
        ["metal", "agent-vault-provision", "ok", DASH, "st-agent-vault-provision"],
        ["metal", "metal-boot-setup", "ok", DASH, "st-metal-boot-setup"],
        ["metal", "metal-pf-refresh", "ok", DASH, "st-metal-pf-refresh"],
        ["metal", "share:metalsecrets", "ok", DASH, "sh-metalsecrets"],
        ["metal", "share:agentvault", "ok", DASH, "sh-agentvault"],
        ["metal", "share:hfhub", "ok", DASH, "sh-hfhub"],
        ["metal", "share:mlxaudio", "ok", DASH, "sh-mlxaudio"],
        ["metal", "share:cliproxy", "ok", DASH, "sh-cliproxy"],
        ["metal", "share:repo", "ok", DASH, "sh-repo"],
    ]
    assert result.output.rstrip("\n") == output.render_table(status.HEADERS, expected_rows)
    assert result.exit_code == 1  # cliproxy state + mlx-audio health both FAIL


def test_status_node_online_ping_failed_still_probes_services(monkeypatch):
    _install_metal_probes(monkeypatch)

    async def degraded_tailnet(name, *, timeout=10):
        if name == "metal":
            return ProbeResult(name, Status.PASS, "online, ping failed (derp-only or stale disco)")
        return ProbeResult(name, Status.FAIL, "registered but offline")

    monkeypatch.setattr(probes, "tailnet_node", degraded_tailnet)
    result = CliRunner().invoke(main, ["status", "metal"])
    lines = result.output.splitlines()

    node_row = next(line for line in lines if "(node)" in line)
    assert "up" in node_row
    assert "ping failed (derp-only or stale disco)" in node_row
    assert any(line.startswith("metal") and "omlx" in line for line in lines)
    assert any(line.startswith("metal") and "share:metalsecrets" in line for line in lines)


def test_status_metal_all_healthy_exits_clean(monkeypatch):
    async def fake_tailnet(name, *, timeout=10):
        return ProbeResult(name, Status.PASS, "online, ping ok")

    async def fake_pass(machine, service, *, timeout=30, client=None):
        return ProbeResult(service.name, Status.PASS, "ok")

    async def fake_share(machine, share, *, timeout=30):
        return ProbeResult(share, Status.PASS, "mounted")

    monkeypatch.setattr(probes, "tailnet_node", fake_tailnet)
    monkeypatch.setattr(probes, "launchd_state", fake_pass)
    monkeypatch.setattr(probes, "service_health", fake_pass)
    monkeypatch.setattr(probes, "share_mounted", fake_share)
    result = CliRunner().invoke(main, ["status", "metal"])
    assert result.exit_code == 0
    assert "fail" not in result.output


def test_status_all_machines_down_nodes_render_as_down(monkeypatch):
    _install_metal_probes(monkeypatch)
    result = CliRunner().invoke(main, ["status"])
    lines = result.output.splitlines()

    hermes_rows = [line for line in lines if line.split()[:1] == ["hermes"]]
    bluebubbles_rows = [line for line in lines if line.split()[:1] == ["bluebubbles"]]
    assert len(hermes_rows) == 1
    assert len(bluebubbles_rows) == 1
    assert "down" in hermes_rows[0]
    assert "registered but offline" in hermes_rows[0]
    assert "down" in bluebubbles_rows[0]
    assert any(line.startswith("metal") and "(node)" in line and "up" in line for line in lines)
    assert result.exit_code == 1  # hermes + bluebubbles down


def test_status_share_probes_skip_non_macos_machines(monkeypatch):
    probed_machines: list[str] = []

    async def recording_share(machine, share, *, timeout=30):
        probed_machines.append(machine.name)
        return ProbeResult(share, Status.PASS, f"sh-{share}")

    _install_metal_probes(monkeypatch, hermes_up=True)
    monkeypatch.setattr(probes, "share_mounted", recording_share)

    result = CliRunner().invoke(main, ["status"])
    lines = result.output.splitlines()

    assert "hermes" not in probed_machines  # NixOS shares are virtiofs tags, not /Volumes/My Shared Files
    assert "metal" in probed_machines  # macOS guest still probed
    assert not any(line.startswith("hermes") and "share:" in line for line in lines)
    assert any(line.startswith("metal") and "share:metalsecrets" in line for line in lines)


def test_status_unknown_machine_is_usage_error():
    result = CliRunner().invoke(main, ["status", "nope"])
    assert result.exit_code == 2


def test_status_help():
    result = CliRunner().invoke(main, ["status", "--help"])
    assert result.exit_code == 0
    assert "Show tailnet, service, health, and share state" in result.output
