import subprocess

import anyio
from click.testing import CliRunner

from yclaw import remote
from yclaw.cli import main

OMLX_LOGS = "/Users/admin/Library/Logs/omlx/omlx.log /Users/admin/Library/Logs/omlx/omlx.error.log"


def _completed(argv, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


def test_logs_darwin_tail_default_lines(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"==> omlx.log <==\nline\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "metal", "omlx"])
    assert result.exit_code == 0
    assert seen[0] == ["tailscale", "ssh", "root@metal", "--", f"tail -n 50 {OMLX_LOGS}"]
    assert "==> omlx.log <==" in result.output


def test_logs_darwin_tail_custom_lines(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "metal", "omlx", "-n", "5"])
    assert result.exit_code == 0
    assert seen[0][-1] == f"tail -n 5 {OMLX_LOGS}"


def test_logs_darwin_follow_streams_with_F(monkeypatch):
    called = {}

    def fake_stream(machine, command):
        called["name"] = machine.name
        called["command"] = command
        raise SystemExit(0)

    monkeypatch.setattr(remote, "stream", fake_stream)
    result = CliRunner().invoke(main, ["logs", "metal", "omlx", "-f", "-n", "10"])
    assert result.exit_code == 0
    assert called == {"name": "metal", "command": f"tail -n 10 -F {OMLX_LOGS}"}


def test_logs_hermes_journalctl(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"journal\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "hermes", "hermes-agent"])
    assert result.exit_code == 0
    assert seen[0][-1] == "journalctl -u hermes-agent.service -n 50"


def test_logs_hermes_journalctl_follow(monkeypatch):
    called = {}

    def fake_stream(machine, command):
        called["command"] = command
        raise SystemExit(0)

    monkeypatch.setattr(remote, "stream", fake_stream)
    result = CliRunner().invoke(main, ["logs", "hermes", "hermes-agent", "-f"])
    assert result.exit_code == 0
    assert called["command"] == "journalctl -u hermes-agent.service -n 50 -f"


def test_logs_bluebubbles_is_usage_error():
    result = CliRunner().invoke(main, ["logs", "bluebubbles", "bluebubbles"])
    assert result.exit_code == 2
    assert "app-internal" in result.output


def test_logs_no_service_lists_services():
    result = CliRunner().invoke(main, ["logs", "metal"])
    assert result.exit_code == 0
    assert "omlx" in result.output
    assert "/Users/admin/Library/Logs/omlx/omlx.log" in result.output
    assert "metal-boot-setup" in result.output


def test_logs_no_service_lists_hermes_units():
    result = CliRunner().invoke(main, ["logs", "hermes"])
    assert result.exit_code == 0
    assert "journalctl -u hermes-agent.service" in result.output


def test_logs_help():
    result = CliRunner().invoke(main, ["logs", "--help"])
    assert result.exit_code == 0
    assert "Tail SERVICE's logs on MACHINE" in result.output
