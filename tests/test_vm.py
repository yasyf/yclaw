import subprocess

import anyio
from click.testing import CliRunner

from yclaw import keychain, remote, vm
from yclaw.cli import main


def _completed(argv, returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


def test_vm_list(monkeypatch):
    seen = []

    def fake_run(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0)

    monkeypatch.setattr(vm.subprocess, "run", fake_run)
    result = CliRunner().invoke(main, ["vm", "list"])
    assert result.exit_code == 0
    assert seen == [["tart", "list"]]


def test_vm_ip(monkeypatch):
    def fake_run(argv, **kwargs):
        assert argv == ["tart", "ip", "metal"]
        return _completed(argv, 0, "192.168.64.5\n", "")

    monkeypatch.setattr(vm.subprocess, "run", fake_run)
    result = CliRunner().invoke(main, ["vm", "ip", "metal"])
    assert result.exit_code == 0
    assert result.output == "192.168.64.5\n"


def test_vm_ssh_runs_pre_tailnet_over_sshpass(monkeypatch):
    monkeypatch.setattr(keychain, "read", lambda service: "adminpw")
    calls = []

    async def fake_process(argv, **kwargs):
        calls.append(argv)
        if argv[0] == "tart":
            return _completed(argv, 0, b"192.168.64.7\n", b"")
        return _completed(argv, 0, b"root\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake_process)
    result = CliRunner().invoke(main, ["vm", "ssh", "metal", "whoami"])
    assert result.exit_code == 0
    assert calls[0] == ["tart", "ip", "metal"]
    assert calls[1] == [
        "sshpass",
        "-p",
        "adminpw",
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "admin@192.168.64.7",
        "whoami",
    ]
    assert "root\n" in result.output


def test_vm_ssh_no_cmd_runs_interactive(monkeypatch):
    called = {}

    def fake_interactive(machine):
        called["name"] = machine.name
        raise SystemExit(0)

    monkeypatch.setattr(remote, "pre_tailnet_interactive", fake_interactive)
    result = CliRunner().invoke(main, ["vm", "ssh", "metal"])
    assert result.exit_code == 0
    assert called == {"name": "metal"}


def test_vm_ssh_without_admin_password_is_usage_error():
    result = CliRunner().invoke(main, ["vm", "ssh", "hermes", "whoami"])
    assert result.exit_code == 2
    assert "no admin password" in result.output


def test_vm_console_opens_vnc(monkeypatch):
    seen = []

    def fake_run(argv, **kwargs):
        seen.append(argv)
        if argv[0] == "tart":
            return _completed(argv, 0, "10.0.0.4\n", "")
        return _completed(argv, 0)

    monkeypatch.setattr(vm.subprocess, "run", fake_run)
    result = CliRunner().invoke(main, ["vm", "console", "bluebubbles"])
    assert result.exit_code == 0
    assert seen == [["tart", "ip", "bluebubbles"], ["open", "vnc://10.0.0.4"]]


def test_vm_help():
    result = CliRunner().invoke(main, ["vm", "--help"])
    assert result.exit_code == 0
    assert "Manage the Tart guest VMs" in result.output
