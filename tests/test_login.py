import os
import signal
import subprocess
import sys
import termios
import time

import pytest

from yclaw import remote
from yclaw.remote import CheckWallError, OutcomeKind, SessionOutcome

pytestmark = pytest.mark.anyio

SLEEP_FOREVER = "import time; time.sleep(60)"


def _assert_dead(pid: int) -> None:
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


async def _never() -> bool:
    return False


@pytest.fixture
def capture(monkeypatch, manifest):
    def factory(code: str, **kwargs):
        monkeypatch.setattr(remote, "_direct_argv", lambda *args, **kw: [sys.executable, "-u", "-c", code])
        kwargs.setdefault("user", "admin")
        kwargs.setdefault("on_line", lambda line: None)
        kwargs.setdefault("ceiling", 30.0)
        kwargs.setdefault("poll_interval", 0.05)
        kwargs.setdefault("settle", 0.5)
        kwargs.setdefault("grace", 3.0)
        return remote.login_capture(manifest.machines["metal"], "login", **kwargs)

    return factory


async def test_probe_fires_kills_child_returns_token(capture, tmp_path):
    pid_file = tmp_path / "pid"
    code = f"import os, pathlib; pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); {SLEEP_FOREVER}"

    async def probe() -> bool:
        return pid_file.exists()

    start = time.monotonic()
    outcome = await capture(code, probe=probe)
    assert outcome == SessionOutcome(OutcomeKind.TOKEN, None)
    assert time.monotonic() - start < 10
    _assert_dead(int(pid_file.read_text()))


async def test_chatty_child_is_drained_without_deadlock(capture):
    lines: list[str] = []
    code = f"[print('line-%06d-' % i + 'x' * 90) for i in range(2000)]; {SLEEP_FOREVER}"

    async def probe() -> bool:
        return len(lines) >= 2000

    outcome = await capture(code, probe=probe, on_line=lines.append)
    assert outcome.kind is OutcomeKind.TOKEN
    assert lines[0] == "line-000000-" + "x" * 90
    assert "line-001999-" + "x" * 90 in lines


async def test_token_landing_during_settle_window_wins(capture):
    token_at = time.monotonic() + 0.4

    async def probe() -> bool:
        return time.monotonic() >= token_at

    outcome = await capture("pass", probe=probe, poll_interval=30.0, settle=2.0)
    assert outcome == SessionOutcome(OutcomeKind.TOKEN, None)


async def test_exited_no_token_only_after_settle(capture):
    times: dict[str, float] = {}
    outcome = await capture(
        "print('exiting')",
        probe=_never,
        on_line=lambda line: times.setdefault("exit", time.monotonic()),
        poll_interval=30.0,
        settle=0.6,
    )
    done = time.monotonic()
    assert outcome == SessionOutcome(OutcomeKind.EXITED_NO_TOKEN, None)
    assert done - times["exit"] >= 0.5


async def test_ceiling_times_out_and_kills_child(capture, tmp_path):
    pid_file = tmp_path / "pid"
    code = f"import os, pathlib; pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); {SLEEP_FOREVER}"
    outcome = await capture(code, probe=_never, ceiling=1.5)
    assert outcome == SessionOutcome(OutcomeKind.TIMEOUT, None)
    _assert_dead(int(pid_file.read_text()))


async def test_fatal_marker_matched_after_ansi_strip(capture):
    lines: list[str] = []
    plain = "Google One auto-discovery failed: gemini cli: project selection required"
    code = f"print('\\x1b[1m{plain}\\x1b[0m'); {SLEEP_FOREVER}"
    outcome = await capture(
        code,
        probe=_never,
        on_line=lines.append,
        fatal_markers=("project selection required",),
    )
    assert outcome == SessionOutcome(OutcomeKind.FATAL_MARKER, plain)
    assert plain in lines


@pytest.mark.parametrize(
    ("code", "expected_line"),
    [
        pytest.param(
            f"print('bind [127.0.0.1]:1455: Address already in use'); {SLEEP_FOREVER}",
            "bind [127.0.0.1]:1455: Address already in use",
            id="bind-in-use-stdout",
        ),
        pytest.param(
            "import sys, time; "
            "print('channel_setup_fwd_listener: cannot listen to port: 1455', file=sys.stderr); "
            "time.sleep(60)",
            "channel_setup_fwd_listener: cannot listen to port: 1455",
            id="fwd-listener-stderr-merged",
        ),
    ],
)
async def test_forward_failure_detected(capture, code, expected_line):
    outcome = await capture(code, probe=_never)
    assert outcome == SessionOutcome(OutcomeKind.FORWARD_FAILED, expected_line)


async def test_check_wall_aborts_with_url(capture):
    url = "https://login.tailscale.com/a/abc123def"
    code = f"print('# To authenticate, visit: {url}'); {SLEEP_FOREVER}"
    with pytest.raises(CheckWallError) as excinfo:
        await capture(code, probe=_never)
    assert excinfo.value.url == url


async def test_stdin_payload_delivered_and_pipe_held_open(capture):
    lines: list[str] = []
    code = (
        "import select, sys, time\n"
        "time.sleep(1.0)\n"
        "line = sys.stdin.readline().strip()\n"
        "ready, _, _ = select.select([sys.stdin], [], [], 0.5)\n"
        "eof = bool(ready) and sys.stdin.buffer.read(1) == b''\n"
        "print(f'GOT:{line} EOF:{eof}')\n"
        "time.sleep(60)\n"
    )

    async def probe() -> bool:
        return any(line.startswith("GOT:") for line in lines)

    outcome = await capture(code, probe=probe, on_line=lines.append, stdin_payload=b"2\n")
    assert outcome.kind is OutcomeKind.TOKEN
    assert "GOT:2 EOF:False" in lines


async def test_sigterm_ignoring_child_is_sigkilled_within_grace(capture, tmp_path):
    pid_file = tmp_path / "pid"
    code = (
        "import os, pathlib, signal, time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
        "time.sleep(60)\n"
    )

    async def probe() -> bool:
        return pid_file.exists()

    grace = 0.5
    start = time.monotonic()
    outcome = await capture(code, probe=probe, grace=grace)
    elapsed = time.monotonic() - start
    assert outcome.kind is OutcomeKind.TOKEN
    assert elapsed >= grace
    assert elapsed < grace + 5
    _assert_dead(int(pid_file.read_text()))


def test_terminal_reset_constant_pinned():
    assert remote.TERMINAL_RESET == (
        "\x1b[?1049l\x1b[?25h"
        "\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[<u"
        "\x1b[0m"
    )


class _FakeStdin:
    def __init__(self, tty: bool) -> None:
        self._tty = tty

    def isatty(self) -> bool:
        return self._tty

    def fileno(self) -> int:
        return 0


def test_attached_builds_tty_forwarded_argv_and_hands_off(monkeypatch, manifest):
    seen: dict[str, object] = {}

    def fake_direct_argv(machine, command, *, user, forwards=(), tty=False):
        seen.update(machine=machine, command=command, user=user, forwards=tuple(forwards), tty=tty)
        return ["ssh", "-t", "the-argv"]

    forwarded: list = []

    def fake_run_attached(argv):
        forwarded.append(argv)
        return 4

    monkeypatch.setattr(remote, "_direct_argv", fake_direct_argv)
    monkeypatch.setattr(remote, "run_attached", fake_run_attached)

    metal = manifest.machines["metal"]
    rc = remote.attached(metal, "login", user="admin", forwards=[8085])

    assert rc == 4  # the child's exit code passes straight through
    assert seen == {"machine": metal, "command": "login", "user": "admin", "forwards": (8085,), "tty": True}
    assert forwarded == [["ssh", "-t", "the-argv"]]


def test_run_attached_non_tty_plain_run(monkeypatch, capfd):
    monkeypatch.setattr(remote.sys, "stdin", _FakeStdin(False))
    signal_calls: list[tuple] = []
    monkeypatch.setattr(remote.signal, "signal", lambda *args: signal_calls.append(args))
    remote.run_attached([sys.executable, "-c", "print('attached-child')"])
    out, _err = capfd.readouterr()
    assert "attached-child" in out
    assert "\x1b" not in out
    assert signal_calls == []


def test_run_attached_non_tty_returns_child_returncode(monkeypatch):
    monkeypatch.setattr(remote.sys, "stdin", _FakeStdin(False))
    rc = remote.run_attached([sys.executable, "-c", "import sys; sys.exit(3)"])
    assert rc == 3


def test_run_attached_tty_absorbs_sigint_and_restores_terminal(monkeypatch, capsys):
    monkeypatch.setattr(remote.sys, "stdin", _FakeStdin(True))
    saved_state = ["fake-termios-state"]
    tcset_calls: list[tuple] = []
    monkeypatch.setattr(remote.termios, "tcgetattr", lambda fd: saved_state)
    monkeypatch.setattr(remote.termios, "tcsetattr", lambda fd, when, attrs: tcset_calls.append((fd, when, attrs)))
    during: dict[str, object] = {}

    def fake_run(argv, check=False):
        during["handler"] = signal.getsignal(signal.SIGINT)
        return subprocess.CompletedProcess(argv, 5)

    monkeypatch.setattr(remote.subprocess, "run", fake_run)

    def custom_handler(signum, frame):
        raise AssertionError("never invoked")

    previous = signal.signal(signal.SIGINT, custom_handler)
    try:
        rc = remote.run_attached(["dummy-child"])
        assert rc == 5  # captured inside the try, returned after the finally restores the terminal
        assert during["handler"] is remote._absorb_sigint
        assert signal.getsignal(signal.SIGINT) is custom_handler
    finally:
        signal.signal(signal.SIGINT, previous)
    assert tcset_calls == [(0, termios.TCSAFLUSH, saved_state)]
    assert capsys.readouterr().out == remote.TERMINAL_RESET
