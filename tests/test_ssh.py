import subprocess

import anyio
from click.testing import CliRunner

from yclaw import remote
from yclaw.cli import main
from yclaw.remote import RemoteResult


def _completed(argv, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


def test_ssh_single_arg_passed_verbatim(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"hello\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["ssh", "metal", "echo a && echo b"])
    assert result.exit_code == 0
    assert seen == [["tailscale", "ssh", "root@metal", "--", "echo a && echo b"]]
    assert "hello\n" in result.output


def test_ssh_multiple_args_shlex_joined(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["ssh", "metal", "launchctl", "print", "system/org.nixos.omlx"])
    assert result.exit_code == 0
    assert seen[0][-1] == "launchctl print system/org.nixos.omlx"


def test_ssh_user_override(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["ssh", "--user", "admin", "metal", "whoami"])
    assert result.exit_code == 0
    assert seen[0][2] == "admin@metal"


def test_ssh_exits_with_remote_returncode(monkeypatch):
    async def fake(argv, **kwargs):
        return _completed(argv, 42, b"", b"boom\n")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["ssh", "metal", "false"])
    assert result.exit_code == 42
    assert "boom\n" in result.stderr


def test_ssh_check_wall_exits_4(monkeypatch):
    url = "https://login.tailscale.com/a/deadbeef1234"

    async def fake(argv, **kwargs):
        return _completed(argv, 1, b"", f"# To authenticate, visit:\n#\t{url}\n".encode())

    monkeypatch.setattr(anyio, "run_process", fake)
    result = CliRunner().invoke(main, ["ssh", "metal", "whoami"])
    assert result.exit_code == 4
    assert url in result.stderr


def test_ssh_no_cmd_runs_interactive(monkeypatch):
    called = {}

    def fake_interactive(machine):
        called["name"] = machine.name
        called["user"] = machine.ssh.user
        raise SystemExit(0)

    monkeypatch.setattr(remote, "interactive", fake_interactive)
    result = CliRunner().invoke(main, ["ssh", "--user", "ops", "hermes"])
    assert result.exit_code == 0
    assert called == {"name": "hermes", "user": "ops"}


def test_ssh_timeout_zero_disables_timeout(monkeypatch):
    captured = {}

    async def fake_run(machine, command, *, timeout=30, capture=True):
        captured["timeout"] = timeout
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = CliRunner().invoke(main, ["ssh", "--timeout", "0", "metal", "whoami"])
    assert result.exit_code == 0
    assert captured["timeout"] is None


def test_ssh_unknown_machine_is_usage_error():
    result = CliRunner().invoke(main, ["ssh", "nope", "whoami"])
    assert result.exit_code == 2
    assert "unknown machine 'nope'" in result.output


def test_ssh_host_is_rejected():
    result = CliRunner().invoke(main, ["ssh", "host", "whoami"])
    assert result.exit_code == 2
    assert "not a tailnet node" in result.output


def test_ssh_help():
    result = CliRunner().invoke(main, ["ssh", "--help"])
    assert result.exit_code == 0
    assert "Open a shell on MACHINE" in result.output
