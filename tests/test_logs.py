import os
import subprocess

import anyio
from click.testing import CliRunner

from yclaw import container, remote
from yclaw.cli import main

RAPID_MLX_LOGS = (
    "/Users/admin/Library/Logs/rapid-mlx/rapid-mlx.log "
    "/Users/admin/Library/Logs/rapid-mlx/rapid-mlx.error.log"
)


def _completed(argv, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


def test_logs_darwin_tail_default_lines(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"==> rapid-mlx.log <==\nline\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "metal", "rapid-mlx"])
    assert result.exit_code == 0
    assert seen[0] == ["tailscale", "ssh", "root@metal", "--", f"tail -n 50 {RAPID_MLX_LOGS}"]
    assert "==> rapid-mlx.log <==" in result.output


def test_logs_darwin_tail_custom_lines(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "metal", "rapid-mlx", "-n", "5"])
    assert result.exit_code == 0
    assert seen[0][-1] == f"tail -n 5 {RAPID_MLX_LOGS}"


def test_logs_darwin_follow_streams_with_F(monkeypatch):
    called = {}

    def fake_stream(machine, command):
        called["name"] = machine.name
        called["command"] = command
        raise SystemExit(0)

    monkeypatch.setattr(remote, "stream", fake_stream)
    result = CliRunner().invoke(main, ["logs", "metal", "rapid-mlx", "-f", "-n", "10"])
    assert result.exit_code == 0
    assert called == {"name": "metal", "command": f"tail -n 10 -F {RAPID_MLX_LOGS}"}


def test_logs_host_tail_expands_tilde_and_execs_local_shell(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"boot\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "host", "tart-metal", "-n", "8"])
    assert result.exit_code == 0
    expected_paths = " ".join(
        os.path.expanduser(p)
        for p in ("~/Library/Logs/Tart/metal.log", "~/Library/Logs/Tart/metal.error.log")
    )
    # ssh-less host: /bin/sh -c locally, with ~ resolved to $HOME (a quoted tilde never expands).
    assert seen[0] == ["/bin/sh", "-c", f"tail -n 8 {expected_paths}"]
    assert "~" not in seen[0][-1]


def test_logs_hermes_container_logs(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"log line\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["logs", "hermes", "hermes-agent"])
    assert result.exit_code == 0
    # The container node has no ssh: `container logs` runs host-locally via /bin/sh (no per-svc -n split).
    assert seen[0] == ["/bin/sh", "-c", f"{container.CONTAINER_BIN} logs hermes"]
    assert "log line\n" in result.output


def test_logs_hermes_container_logs_follow(monkeypatch):
    called = {}

    def fake_stream(machine, command):
        called["name"] = machine.name
        called["command"] = command
        raise SystemExit(0)

    monkeypatch.setattr(remote, "stream", fake_stream)
    result = CliRunner().invoke(main, ["logs", "hermes", "hermes-agent", "-f"])
    assert result.exit_code == 0
    assert called == {"name": "hermes", "command": f"{container.CONTAINER_BIN} logs -f hermes"}


def test_logs_bluebubbles_is_usage_error():
    result = CliRunner().invoke(main, ["logs", "bluebubbles", "bluebubbles"])
    assert result.exit_code == 2
    assert "app-internal" in result.output


def test_logs_no_service_lists_services():
    result = CliRunner().invoke(main, ["logs", "metal"])
    assert result.exit_code == 0
    assert "rapid-mlx" in result.output
    assert "/Users/admin/Library/Logs/rapid-mlx/rapid-mlx.log" in result.output
    assert "metal-boot-setup" in result.output


def test_logs_no_service_lists_hermes_container():
    result = CliRunner().invoke(main, ["logs", "hermes"])
    assert result.exit_code == 0
    assert "hermes-agent" in result.output
    assert f"{container.CONTAINER_BIN} logs hermes" in result.output


def test_logs_help():
    result = CliRunner().invoke(main, ["logs", "--help"])
    assert result.exit_code == 0
    assert "Tail SERVICE's logs on MACHINE" in result.output
