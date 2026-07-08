"""The single chokepoint for reaching fleet nodes over ssh.

Every remote command is exactly ONE string, handed to ``tailscale ssh <user>@<host> -- <command>``
(or, for login sessions that need ``-t``/``-L``, to plain OpenSSH via ``_direct_argv`` — Tailscale
SSH intercepts it either way) so the remote login shell re-parses it as a unit; no other module
builds ssh argv. This module never appends ``2>/dev/null`` — stderr is preserved so a Tailscale
check-mode login wall can be detected and surfaced as ``CheckWallError`` carrying its approval URL.
Every argv is logged at DEBUG, but ``pre_tailnet_run`` redacts the sshpass password before logging.

Remote exit codes are garbage over Tailscale-intercepted ssh (always 0 on the macOS nodes), so
``login_capture`` decides outcomes from output sentinels and an out-of-band probe, never from rc.
"""

import enum
import os
import re
import signal
import subprocess
import sys
import termios
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import NoReturn

import anyio
from anyio.abc import Process
from loguru import logger

from . import keychain
from .manifest import Machine

CHECK_WALL_RE = re.compile(r"https://login\.tailscale\.com/a/[A-Za-z0-9]+")
ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_])")
FORWARD_FAILURE_MARKERS = (
    "Address already in use",
    "channel_setup_fwd_listener",
    "Could not request local forwarding",
)
LOGIN_POLL_INTERVAL = 2.0
LOGIN_SETTLE = 10.0
KILL_GRACE = 3.0
# ccp's exact terminal reset: leave the alt screen, show the cursor, disable the input modes a
# killed child may have enabled (bracketed paste, mouse, focus, kitty keyboard), then SGR reset.
TERMINAL_RESET = (
    "\x1b[?1049l\x1b[?25h"
    "\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[<u"
    "\x1b[0m"
)


class RemoteError(Exception):
    """Base class for remote-execution failures."""


class CheckWallError(RemoteError):
    """A command hit a Tailscale check-mode login wall; ``url`` is the approval link."""

    def __init__(self, url: str) -> None:
        super().__init__(f"tailscale check-mode login required: {url}")
        self.url = url


class RemoteTimeout(RemoteError):
    """A remote command exceeded its timeout."""

    def __init__(self, command: str, timeout: float) -> None:
        super().__init__(f"remote command timed out after {timeout}s: {command}")
        self.command = command
        self.timeout = timeout


@dataclass(frozen=True, slots=True)
class RemoteResult:
    returncode: int
    stdout: str
    stderr: str


class OutcomeKind(enum.Enum):
    TOKEN = enum.auto()
    EXITED_NO_TOKEN = enum.auto()
    TIMEOUT = enum.auto()
    FORWARD_FAILED = enum.auto()
    FATAL_MARKER = enum.auto()


@dataclass(frozen=True, slots=True)
class SessionOutcome:
    kind: OutcomeKind
    line: str | None = None


async def run(
    machine: Machine,
    command: str,
    *,
    timeout: float | None = 30,
    capture: bool = True,
    input: bytes | None = None,
) -> RemoteResult:
    argv = ["tailscale", "ssh", f"{machine.ssh.user}@{machine.name}", "--", command]
    logger.debug("remote argv: {}", argv)
    try:
        with anyio.fail_after(timeout):
            if capture:
                completed = await anyio.run_process(argv, check=False, input=input)
                result = RemoteResult(completed.returncode, completed.stdout.decode(), completed.stderr.decode())
            else:
                completed = await anyio.run_process(argv, check=False, input=input, stdout=None, stderr=None)
                result = RemoteResult(completed.returncode, "", "")
    except TimeoutError as exc:
        raise RemoteTimeout(command, timeout) from exc
    if result.returncode != 0:
        wall = CHECK_WALL_RE.search(result.stderr)
        if wall is not None:
            raise CheckWallError(wall.group(0))
    return result


def interactive(machine: Machine) -> NoReturn:
    argv = ["tailscale", "ssh", f"{machine.ssh.user}@{machine.name}"]
    logger.debug("interactive argv: {}", argv)
    os.execvp("tailscale", argv)


def stream(machine: Machine, command: str) -> NoReturn:
    argv = ["tailscale", "ssh", f"{machine.ssh.user}@{machine.name}", "--", command]
    logger.debug("stream argv: {}", argv)
    os.execvp("tailscale", argv)


def pre_tailnet_interactive(machine: Machine) -> NoReturn:
    ip = subprocess.run(["tart", "ip", machine.tart_vm], capture_output=True, text=True, check=True).stdout.strip()
    password = keychain.read(machine.admin_pass_keychain)
    argv = ["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=accept-new", f"admin@{ip}"]
    logger.debug("pre-tailnet interactive argv: {}", [*argv[:2], "***", *argv[3:]])
    os.execvp("sshpass", argv)


async def pre_tailnet_run(
    machine: Machine, command: str, *, timeout: float | None = 30, capture: bool = True
) -> RemoteResult:
    ip = (await anyio.run_process(["tart", "ip", machine.tart_vm], check=True)).stdout.decode().strip()
    password = keychain.read(machine.admin_pass_keychain)
    argv = ["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=accept-new", f"admin@{ip}", command]
    logger.debug("pre-tailnet argv: {}", [*argv[:2], "***", *argv[3:]])
    try:
        with anyio.fail_after(timeout):
            if capture:
                completed = await anyio.run_process(argv, check=False)
                return RemoteResult(completed.returncode, completed.stdout.decode(), completed.stderr.decode())
            completed = await anyio.run_process(argv, check=False, stdout=None, stderr=None)
            return RemoteResult(completed.returncode, "", "")
    except TimeoutError as exc:
        raise RemoteTimeout(command, timeout) from exc


def _direct_argv(
    machine: Machine,
    command: str,
    *,
    user: str,
    forwards: Sequence[int] = (),
    tty: bool = False,
) -> list[str]:
    argv = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ExitOnForwardFailure=yes",
    ]
    if tty:
        argv.append("-t")
    for port in forwards:
        # No explicit local bind address: pinning 127.0.0.1 would drop the ::1 listener
        # macOS browsers try first when resolving localhost.
        argv.extend(["-L", f"{port}:127.0.0.1:{port}"])
    argv.extend([f"{user}@{machine.name}", command])
    return argv


async def _terminate(process: Process, grace: float) -> None:
    if process.returncode is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        with anyio.move_on_after(grace):
            await process.wait()
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await process.wait()
    await process.aclose()


async def login_capture(
    machine: Machine,
    command: str,
    *,
    user: str,
    forwards: Sequence[int] = (),
    stdin_payload: bytes | None = None,
    on_line: Callable[[str], None],
    probe: Callable[[], Awaitable[bool]],
    fatal_markers: Sequence[str] = (),
    ceiling: float,
    poll_interval: float = LOGIN_POLL_INTERVAL,
    settle: float = LOGIN_SETTLE,
    grace: float = KILL_GRACE,
) -> SessionOutcome:
    argv = _direct_argv(machine, command, user=user, forwards=forwards)
    logger.debug("login argv: {}", argv)
    outcome: SessionOutcome | None = None
    wall: CheckWallError | None = None
    process = await anyio.open_process(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        with anyio.move_on_after(ceiling):
            async with anyio.create_task_group() as tg:

                def decide(result: SessionOutcome) -> None:
                    nonlocal outcome
                    if outcome is None and wall is None:
                        outcome = result
                    tg.cancel_scope.cancel()

                def abort(error: CheckWallError) -> None:
                    nonlocal wall
                    if outcome is None and wall is None:
                        wall = error
                    tg.cancel_scope.cancel()

                def handle_line(raw: str) -> None:
                    line = ANSI_RE.sub("", raw).rstrip("\r")
                    on_line(line)
                    matched = CHECK_WALL_RE.search(line)
                    if matched is not None:
                        abort(CheckWallError(matched.group(0)))
                        return
                    if any(marker in line for marker in FORWARD_FAILURE_MARKERS):
                        decide(SessionOutcome(OutcomeKind.FORWARD_FAILED, line))
                        return
                    for marker in fatal_markers:
                        if marker in line:
                            decide(SessionOutcome(OutcomeKind.FATAL_MARKER, line))
                            return

                async def scan() -> None:
                    # A match never stops the drain: a chatty child fills the 64KB pipe and
                    # deadlocks if anyone stops reading before the session is decided.
                    carry = b""
                    async for chunk in process.stdout:
                        carry += chunk
                        while (cut := carry.find(b"\n")) >= 0:
                            handle_line(carry[:cut].decode(errors="replace"))
                            carry = carry[cut + 1 :]
                    if carry:
                        handle_line(carry.decode(errors="replace"))

                async def poll() -> None:
                    while True:
                        if await probe():
                            decide(SessionOutcome(OutcomeKind.TOKEN))
                            return
                        await anyio.sleep(poll_interval)

                async def wait_exit() -> None:
                    # Child exit is an event, not a failure: rc is garbage over the Tailscale
                    # intercept, and the token file lands with fs latency — settle re-probe.
                    await process.wait()
                    with anyio.move_on_after(settle):
                        while True:
                            if await probe():
                                decide(SessionOutcome(OutcomeKind.TOKEN))
                                return
                            await anyio.sleep(settle / 3)
                    decide(SessionOutcome(OutcomeKind.EXITED_NO_TOKEN))

                tg.start_soon(scan)
                tg.start_soon(poll)
                tg.start_soon(wait_exit)
                # stdin stays open for the whole session: Codex's 15s paste fallback reads it,
                # and an instant EOF can abort the login.
                if stdin_payload is not None:
                    try:
                        await process.stdin.send(stdin_payload)
                    except anyio.BrokenResourceError:
                        # The child died before reading stdin; the exit waiter decides.
                        pass
    except BaseExceptionGroup as group:
        # A lone task exception (e.g. CheckWallError out of the probe) surfaces bare.
        if len(group.exceptions) == 1:
            raise group.exceptions[0] from group
        raise
    finally:
        with anyio.CancelScope(shield=True):
            await _terminate(process, grace)
    if wall is not None:
        raise wall
    if outcome is None:
        return SessionOutcome(OutcomeKind.TIMEOUT)
    return outcome


def _absorb_sigint(signum: int, frame: object) -> None:
    # Not SIG_IGN: an ignored disposition survives exec, so the child would ignore
    # ctrl-c too. A caught handler resets to SIG_DFL in the child — the child dies
    # on ctrl-c while the parent absorbs it and interprets the outcome.
    pass


def run_attached(argv: Sequence[str]) -> int:
    logger.debug("attached argv: {}", list(argv))
    if not sys.stdin.isatty():
        return subprocess.run(argv, check=False).returncode
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    previous = signal.signal(signal.SIGINT, _absorb_sigint)
    try:
        # Same process group, no setsid: a background pgrp touching the tty stops on SIGTTOU.
        returncode = subprocess.run(argv, check=False).returncode
    finally:
        signal.signal(signal.SIGINT, previous)
        termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
        sys.stdout.write(TERMINAL_RESET)
        sys.stdout.flush()
    return returncode


def attached(machine: Machine, command: str, *, user: str, forwards: Sequence[int] = ()) -> int:
    """Hand a login child the real terminal over plain ssh — the Gemini project-picker fallback."""
    return run_attached(_direct_argv(machine, command, user=user, forwards=forwards, tty=True))
