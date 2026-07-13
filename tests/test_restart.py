from click.testing import CliRunner

from yclaw import probes, remote, restart
from yclaw.cli import main
from yclaw.probes import ProbeResult, Status
from yclaw.remote import RemoteResult


async def _health_pass(machine, service, *, timeout=30, client=None):
    return ProbeResult(service.name, Status.PASS, "HTTP 200")


def test_restart_launchd_kickstart(monkeypatch):
    seen = []

    async def fake_run(machine, command, *, timeout=30, capture=True):
        seen.append(command)
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    monkeypatch.setattr(probes, "service_health", _health_pass)
    result = CliRunner().invoke(main, ["restart", "metal", "rapid-mlx"])
    assert result.exit_code == 0
    assert seen == ["launchctl kickstart -k system/org.nixos.rapid-mlx"]
    assert "restarted rapid-mlx on metal" in result.output
    assert "healthy" in result.output


def test_restart_systemd(monkeypatch):
    seen = []

    async def fake_run(machine, command, *, timeout=30, capture=True):
        seen.append(command)
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["restart", "hermes", "hermes-agent"])
    assert result.exit_code == 0
    assert seen == ["systemctl restart hermes-agent.service"]
    assert "restarted hermes-agent on hermes" in result.output


def test_restart_kickstart_not_loaded_points_to_bounce(monkeypatch):
    async def fake_run(machine, command, *, timeout=30, capture=True):
        return RemoteResult(3, "", "Could not find service\n")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["restart", "metal", "rapid-mlx"])
    assert result.exit_code == 1
    assert "yclaw bounce metal rapid-mlx" in result.stderr


def test_bounce_order_bootout_poll_bootstrap(monkeypatch):
    seen = []

    async def fake_run(machine, command, *, timeout=30, capture=True):
        seen.append(command)
        if command.startswith("launchctl print"):
            return RemoteResult(1, "", "")  # label gone after bootout
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    monkeypatch.setattr(probes, "service_health", _health_pass)
    result = CliRunner().invoke(main, ["bounce", "metal", "rapid-mlx"])
    assert result.exit_code == 0
    assert seen == [
        "launchctl bootout system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
        "launchctl bootstrap system /Library/LaunchDaemons/org.nixos.rapid-mlx.plist",
    ]
    assert "bounced rapid-mlx on metal" in result.output


def test_bounce_retries_while_loaded_then_bootstraps_once_drained(monkeypatch):
    monkeypatch.setattr(restart, "HEALTH_INTERVAL", 0.001)
    seen = []
    prints = 0

    async def fake_run(machine, command, *, timeout=30, capture=True):
        nonlocal prints
        seen.append(command)
        if command.startswith("launchctl print"):
            prints += 1
            if prints == 1:
                assert not any(c.startswith("launchctl bootstrap") for c in seen)
                return RemoteResult(0, "", "")  # still loaded on the first poll
            return RemoteResult(1, "", "")  # drained by the second poll
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    monkeypatch.setattr(probes, "service_health", _health_pass)
    result = CliRunner().invoke(main, ["bounce", "metal", "rapid-mlx"])
    assert result.exit_code == 0
    assert seen == [
        "launchctl bootout system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
        "launchctl bootstrap system /Library/LaunchDaemons/org.nixos.rapid-mlx.plist",
    ]
    assert "bounced rapid-mlx on metal" in result.output


def test_bounce_fails_loudly_when_label_never_drains(monkeypatch):
    monkeypatch.setattr(restart, "HEALTH_INTERVAL", 0.0)
    monkeypatch.setattr(restart, "HEALTH_TIMEOUT", 3.0)
    clock = iter([0.0, 1.0, 2.0, 3.0])
    monkeypatch.setattr(restart.anyio, "current_time", lambda: next(clock))
    seen = []

    async def fake_run(machine, command, *, timeout=30, capture=True):
        seen.append(command)
        return RemoteResult(0, "", "")  # label stays loaded on every poll

    monkeypatch.setattr(remote, "run", fake_run)
    monkeypatch.setattr(probes, "service_health", _health_pass)
    result = CliRunner().invoke(main, ["bounce", "metal", "rapid-mlx"])
    assert result.exit_code == 1
    assert seen == [
        "launchctl bootout system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
        "launchctl print system/org.nixos.rapid-mlx",
    ]
    assert not any(c.startswith("launchctl bootstrap") for c in seen)
    assert "still loaded" in result.stderr
    assert "cannot bootstrap over a live label" in result.stderr


def test_bounce_rejects_non_launchd_service():
    result = CliRunner().invoke(main, ["bounce", "hermes", "hermes-agent"])
    assert result.exit_code == 2
    assert "launchd-only" in result.output


def test_restart_help():
    result = CliRunner().invoke(main, ["restart", "--help"])
    assert result.exit_code == 0
    assert "Kick SERVICE on MACHINE in place" in result.output


def test_bounce_help():
    result = CliRunner().invoke(main, ["bounce", "--help"])
    assert result.exit_code == 0
    assert "Fully unload and reload" in result.output
