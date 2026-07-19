import subprocess

import anyio
from click.testing import CliRunner

from yclaw import container, remote, ssh
from yclaw.cli import main
from yclaw.container import ContainerResult
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
    result = CliRunner().invoke(main, ["ssh", "metal", "launchctl", "print", "system/org.nixos.rapid-mlx"])
    assert result.exit_code == 0
    assert seen[0][-1] == "launchctl print system/org.nixos.rapid-mlx"


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
    result = CliRunner().invoke(main, ["ssh", "--user", "ops", "metal"])
    assert result.exit_code == 0
    assert called == {"name": "metal", "user": "ops"}


def test_ssh_container_node_no_cmd_execs_into_container(monkeypatch):
    # A container node has no ssh: `yclaw ssh hermes` execs `container exec -it hermes sh`, never
    # tailscale ssh and never the host-node UsageError (ssh is None but container is set).
    recorded = {}

    def fake_execvp(file, args):
        recorded["file"] = file
        recorded["args"] = args
        raise SystemExit(0)

    monkeypatch.setattr(ssh.os, "execvp", fake_execvp)
    result = CliRunner().invoke(main, ["ssh", "hermes"])
    assert result.exit_code == 0
    assert recorded["file"] == container.CONTAINER_BIN
    assert recorded["args"] == [container.CONTAINER_BIN, "exec", "-it", "hermes", "sh"]


def test_ssh_container_node_one_shot_execs_and_exits_with_rc(monkeypatch):
    seen = {}

    async def fake_exec(name, command, *, timeout=30, uid=None):
        seen["name"] = name
        seen["command"] = command
        seen["timeout"] = timeout
        return ContainerResult(3, "out\n", "err\n")

    monkeypatch.setattr(container, "exec_run", fake_exec)
    result = CliRunner().invoke(main, ["ssh", "hermes", "launchctl", "print", "x"])
    assert result.exit_code == 3
    assert seen["name"] == "hermes"
    assert seen["command"] == "launchctl print x"  # multi-arg is shlex-joined into one string
    assert seen["timeout"] == 30
    assert "out\n" in result.output
    assert "err\n" in result.stderr


def test_ssh_container_node_timeout_zero_disables_timeout(monkeypatch):
    captured = {}

    async def fake_exec(name, command, *, timeout=30, uid=None):
        captured["timeout"] = timeout
        return ContainerResult(0, "", "")

    monkeypatch.setattr(container, "exec_run", fake_exec)
    result = CliRunner().invoke(main, ["ssh", "--timeout", "0", "hermes", "whoami"])
    assert result.exit_code == 0
    assert captured["timeout"] is None


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
