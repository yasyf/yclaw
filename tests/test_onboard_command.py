import os
import socket
import subprocess
import sys

import click
import pytest
from click.testing import CliRunner

from yclaw.cli import main
from yclaw.onboard import command, gates


def _fixed_gates(*specs):
    """Build a stand-in ``build_gates`` whose bodies return canned GateResults, no seams touched."""

    def build(manifest):
        return tuple(
            gates.Gate(key, title, (lambda s=status, d=detail, r=retry: gates.GateResult(s, d, r)))
            for key, title, status, detail, retry in specs
        )

    return build


def _dead_pid() -> int:
    proc = subprocess.Popen([sys.executable, "-c", "pass"])
    proc.wait()
    return proc.pid  # reaped: os.kill(pid, 0) now raises ProcessLookupError


@pytest.fixture
def stub_env(monkeypatch, tmp_path):
    """Make preflight pass and isolate the lockfile under a tmp home."""
    monkeypatch.setattr(command.shutil, "which", lambda tool: f"/usr/bin/{tool}")
    keychain_db = tmp_path / "yclaw.keychain-db"
    keychain_db.write_text("")
    monkeypatch.setattr(command.keychain, "KEYCHAIN_PATH", keychain_db)
    monkeypatch.setattr(command, "CALLBACK_PORTS", ())
    monkeypatch.setattr(command.Path, "home", lambda: tmp_path)
    return tmp_path


# --- preflight ------------------------------------------------------------------------------------


def test_preflight_flags_a_bound_callback_port(monkeypatch, tmp_path):
    monkeypatch.setattr(command.shutil, "which", lambda tool: f"/usr/bin/{tool}")
    keychain_db = tmp_path / "kc"
    keychain_db.write_text("")
    monkeypatch.setattr(command.keychain, "KEYCHAIN_PATH", keychain_db)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    port = sock.getsockname()[1]
    try:
        with pytest.raises(command.PreflightError) as excinfo:
            command._preflight(ports=(port,))
    finally:
        sock.close()
    assert str(port) in str(excinfo.value)
    assert f"lsof -iTCP:{port}" in str(excinfo.value)


def test_preflight_missing_tool_names_it(monkeypatch, tmp_path):
    keychain_db = tmp_path / "kc"
    keychain_db.write_text("")
    monkeypatch.setattr(command.keychain, "KEYCHAIN_PATH", keychain_db)
    monkeypatch.setattr(command.shutil, "which", lambda tool: None if tool == "just" else f"/usr/bin/{tool}")
    with pytest.raises(command.PreflightError) as excinfo:
        command._preflight(ports=())
    assert "just" in str(excinfo.value)


def test_preflight_missing_keychain_says_bootstrap(monkeypatch, tmp_path):
    monkeypatch.setattr(command.shutil, "which", lambda tool: f"/usr/bin/{tool}")
    monkeypatch.setattr(command.keychain, "KEYCHAIN_PATH", tmp_path / "absent.keychain-db")
    with pytest.raises(command.PreflightError) as excinfo:
        command._preflight(ports=())
    assert "just bootstrap" in str(excinfo.value)


def test_port_in_use_true_when_bound(monkeypatch):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    port = sock.getsockname()[1]
    try:
        assert command._port_in_use(port) is True
    finally:
        sock.close()
    assert command._first_busy_port(()) is None


def test_onboard_preflight_failure_exits_fail(monkeypatch):
    def boom(*args, **kwargs):
        raise command.PreflightError("preflight boom")

    monkeypatch.setattr(command, "_preflight", boom)
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 1
    assert "preflight boom" in result.output


# --- confirm_retry --------------------------------------------------------------------------------


def test_confirm_retry_returns_click_confirm(monkeypatch):
    monkeypatch.setattr(command.click, "confirm", lambda *a, **k: True)
    assert command._confirm_retry("Gate X") is True


def test_confirm_retry_ctrl_c_becomes_keyboardinterrupt(monkeypatch):
    def abort(*args, **kwargs):
        raise click.Abort()

    monkeypatch.setattr(command.click, "confirm", abort)
    with pytest.raises(KeyboardInterrupt):
        command._confirm_retry("Gate X")


# --- full driver + summary ------------------------------------------------------------------------


def test_full_run_all_done_exits_clean_without_escapes(stub_env, monkeypatch):
    monkeypatch.setattr(
        gates,
        "build_gates",
        _fixed_gates(
            ("codex", "Codex login", gates.GateStatus.DONE, "logged in", ""),
            ("gemini", "Gemini login", gates.GateStatus.DONE, "logged in", ""),
        ),
    )
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 0
    assert "Codex login" in result.output
    assert "Gemini login" in result.output
    assert "\x1b" not in result.output


def test_full_run_any_failed_exits_fail_and_shows_retry(stub_env, monkeypatch):
    monkeypatch.setattr(
        gates,
        "build_gates",
        _fixed_gates(
            ("codex", "Codex login", gates.GateStatus.DONE, "logged in", ""),
            ("gemini", "Gemini login", gates.GateStatus.FAILED, "no token", "uv run yclaw onboard --gate gemini"),
        ),
    )
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 1
    assert "no token" in result.output
    assert "uv run yclaw onboard --gate gemini" in result.output


def test_manual_gate_does_not_fail_the_run_and_shows_recheck(stub_env, monkeypatch):
    monkeypatch.setattr(
        gates,
        "build_gates",
        _fixed_gates(
            ("codex", "Codex login", gates.GateStatus.DONE, "logged in", ""),
            (
                "hermes-identity",
                "hermes identity",
                gates.GateStatus.MANUAL,
                "seed USER.md into the container state dir",
                "uv run yclaw onboard --gate hermes-identity",
            ),
        ),
    )
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 0  # a MANUAL gate needs a human but is not a run failure
    assert "hermes identity (manual): seed USER.md into the container state dir" in result.output
    assert "re-check: uv run yclaw onboard --gate hermes-identity" in result.output


def test_skipped_gate_does_not_fail_the_run(stub_env, monkeypatch):
    monkeypatch.setattr(
        gates,
        "build_gates",
        _fixed_gates(
            ("codex", "Codex login", gates.GateStatus.DONE, "logged in", ""),
            ("bluebubbles", "BlueBubbles", gates.GateStatus.SKIPPED, "skipped by user (ctrl-c)", ""),
        ),
    )
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 0
    assert "BlueBubbles" in result.output


def test_single_gate_selection_runs_only_that_gate(stub_env, monkeypatch):
    monkeypatch.setattr(
        gates,
        "build_gates",
        _fixed_gates(
            ("codex", "Codex login", gates.GateStatus.DONE, "done-codex", ""),
            ("gemini", "Gemini login", gates.GateStatus.FAILED, "done-gemini", "uv run yclaw onboard --gate gemini"),
        ),
    )
    result = CliRunner().invoke(main, ["onboard", "--gate", "codex"])
    assert result.exit_code == 0
    assert "Codex login" in result.output
    assert "Gemini login" not in result.output


def test_unknown_gate_is_usage_error(stub_env, monkeypatch):
    monkeypatch.setattr(gates, "build_gates", _fixed_gates(("codex", "Codex login", gates.GateStatus.DONE, "done", "")))
    result = CliRunner().invoke(main, ["onboard", "--gate", "nope"])
    assert result.exit_code == 2
    assert "unknown gate 'nope'" in result.output


# --- lockfile -------------------------------------------------------------------------------------


def test_second_instance_refuses_when_lock_pid_is_alive(stub_env, monkeypatch):
    lock = stub_env / ".yclaw" / "state" / "onboard" / "lock"
    lock.parent.mkdir(parents=True)
    lock.write_text(str(os.getpid()))  # our own pid — alive
    monkeypatch.setattr(gates, "build_gates", _fixed_gates(("codex", "Codex login", gates.GateStatus.DONE, "done", "")))
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 1
    assert "already running" in result.output
    assert lock.read_text() == str(os.getpid())  # the live lock is left untouched


def test_stale_lock_is_replaced_and_run_proceeds(stub_env, monkeypatch):
    lock = stub_env / ".yclaw" / "state" / "onboard" / "lock"
    lock.parent.mkdir(parents=True)
    lock.write_text(str(_dead_pid()))
    monkeypatch.setattr(gates, "build_gates", _fixed_gates(("codex", "Codex login", gates.GateStatus.DONE, "done", "")))
    result = CliRunner().invoke(main, ["onboard"])
    assert result.exit_code == 0
    assert "replacing a stale onboard lock" in result.output
    assert not lock.exists()  # released on exit
