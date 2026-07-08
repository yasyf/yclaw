import subprocess

import anyio
import pytest
from loguru import logger

from yclaw import keychain, remote
from yclaw.remote import CheckWallError, RemoteResult, RemoteTimeout

pytestmark = pytest.mark.anyio


def _completed(argv, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


async def test_run_builds_single_string_command(manifest, monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"hi\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = await remote.run(manifest.machines["hermes"], "echo a && echo b")
    assert seen == [["tailscale", "ssh", "root@hermes", "--", "echo a && echo b"]]
    assert result == RemoteResult(0, "hi\n", "")


async def test_run_preserves_stderr_no_devnull(manifest, monkeypatch):
    async def fake(argv, **kwargs):
        return _completed(argv, 3, b"", b"boom\n")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = await remote.run(manifest.machines["metal"], "false")
    assert result == RemoteResult(3, "", "boom\n")


async def test_run_extracts_check_wall_url(manifest, monkeypatch):
    url = "https://login.tailscale.com/a/1a2b3c4d5e6f"
    stderr = f"# Tailscale SSH requires an additional check.\n# To authenticate, visit:\n#\n#\t{url}\n"

    async def fake(argv, **kwargs):
        return _completed(argv, 1, b"", stderr.encode())

    monkeypatch.setattr(anyio, "run_process", fake)
    with pytest.raises(CheckWallError) as excinfo:
        await remote.run(manifest.machines["metal"], "whoami")
    assert excinfo.value.url == url


@pytest.mark.parametrize("capture", [True, False], ids=["capture", "no-capture"])
async def test_run_threads_input_to_stdin(manifest, monkeypatch, capture):
    seen = {}

    async def fake(argv, **kwargs):
        seen["argv"] = argv
        seen["input"] = kwargs["input"]
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    await remote.run(manifest.machines["metal"], "cat > /tmp/payload", capture=capture, input=b"s3cr3t\n")
    assert seen["argv"] == ["tailscale", "ssh", "root@metal", "--", "cat > /tmp/payload"]
    assert seen["input"] == b"s3cr3t\n"


async def test_run_defaults_input_to_none(manifest, monkeypatch):
    seen = {}

    async def fake(argv, **kwargs):
        seen["input"] = kwargs["input"]
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    await remote.run(manifest.machines["metal"], "true")
    assert seen["input"] is None


async def test_run_timeout_raises_remote_timeout(manifest, monkeypatch):
    async def slow(argv, **kwargs):
        await anyio.sleep(5)
        return _completed(argv)

    monkeypatch.setattr(anyio, "run_process", slow)
    with pytest.raises(RemoteTimeout) as excinfo:
        await remote.run(manifest.machines["metal"], "sleep 100", timeout=0.05)
    assert excinfo.value.command == "sleep 100"
    assert excinfo.value.timeout == 0.05


def test_interactive_uses_execvp(manifest, monkeypatch):
    recorded = {}

    def fake_execvp(file, args):
        recorded["file"] = file
        recorded["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(remote.os, "execvp", fake_execvp)
    with pytest.raises(SystemExit):
        remote.interactive(manifest.machines["hermes"])
    assert recorded["file"] == "tailscale"
    assert recorded["args"] == ["tailscale", "ssh", "root@hermes"]


async def test_pre_tailnet_run_argv_and_redaction(manifest, monkeypatch):
    monkeypatch.setattr(keychain, "read", lambda service: "s3cr3t-pw")
    ssh_calls = []

    async def fake(argv, **kwargs):
        if argv[0] == "tart":
            return _completed(argv, 0, b"192.168.64.9\n", b"")
        if argv[0] == "sshpass":
            ssh_calls.append(argv)
            return _completed(argv, 0, b"admin\n", b"")
        raise AssertionError(argv)

    monkeypatch.setattr(anyio, "run_process", fake)

    logged = []
    sink = logger.add(logged.append, level="DEBUG", format="{message}")
    try:
        result = await remote.pre_tailnet_run(manifest.machines["metal"], "whoami")
    finally:
        logger.remove(sink)

    assert ssh_calls == [
        [
            "sshpass",
            "-p",
            "s3cr3t-pw",
            "ssh",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "admin@192.168.64.9",
            "whoami",
        ]
    ]
    assert result == RemoteResult(0, "admin\n", "")
    pre_tailnet_logs = [m for m in logged if "pre-tailnet argv" in m]
    assert pre_tailnet_logs, "expected a redacted pre-tailnet argv debug log"
    assert all("s3cr3t-pw" not in m for m in pre_tailnet_logs)
    assert any("***" in m for m in pre_tailnet_logs)


def test_stream_uses_execvp(manifest, monkeypatch):
    recorded = {}

    def fake_execvp(file, args):
        recorded["file"] = file
        recorded["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(remote.os, "execvp", fake_execvp)
    with pytest.raises(SystemExit):
        remote.stream(manifest.machines["metal"], "tail -F /var/log/x")
    assert recorded["file"] == "tailscale"
    assert recorded["args"] == ["tailscale", "ssh", "root@metal", "--", "tail -F /var/log/x"]


def test_direct_argv_minimal(manifest):
    assert remote._direct_argv(manifest.machines["metal"], "echo a && echo b", user="admin") == [
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ExitOnForwardFailure=yes",
        "admin@metal",
        "echo a && echo b",
    ]


def test_direct_argv_tty_and_forwards(manifest):
    argv = remote._direct_argv(
        manifest.machines["metal"],
        "/nix/store/x/bin/cli-proxy-api --codex-login --no-browser",
        user="admin",
        forwards=(1455, 8085),
        tty=True,
    )
    assert argv == [
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ExitOnForwardFailure=yes",
        "-t",
        "-L",
        "1455:127.0.0.1:1455",
        "-L",
        "8085:127.0.0.1:8085",
        "admin@metal",
        "/nix/store/x/bin/cli-proxy-api --codex-login --no-browser",
    ]


def test_pre_tailnet_interactive_argv_and_redaction(manifest, monkeypatch):
    monkeypatch.setattr(keychain, "read", lambda service: "s3cr3t-pw")

    def fake_tart(argv, **kwargs):
        assert argv == ["tart", "ip", "metal"]
        return _completed(argv, 0, "192.168.64.9\n", "")

    monkeypatch.setattr(remote.subprocess, "run", fake_tart)
    recorded = {}

    def fake_execvp(file, args):
        recorded["file"] = file
        recorded["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(remote.os, "execvp", fake_execvp)
    logged = []
    sink = logger.add(logged.append, level="DEBUG", format="{message}")
    try:
        with pytest.raises(SystemExit):
            remote.pre_tailnet_interactive(manifest.machines["metal"])
    finally:
        logger.remove(sink)
    assert recorded["file"] == "sshpass"
    assert recorded["args"] == [
        "sshpass",
        "-p",
        "s3cr3t-pw",
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "admin@192.168.64.9",
    ]
    assert all("s3cr3t-pw" not in m for m in logged)
    assert any("***" in m for m in logged)
