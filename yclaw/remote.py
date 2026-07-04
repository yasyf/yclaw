"""The single chokepoint for reaching fleet nodes over ``tailscale ssh``.

Every remote command is exactly ONE string, handed to ``tailscale ssh <user>@<host> -- <command>``
so the remote login shell re-parses it as a unit; no other module builds tailscale-ssh argv. This
module never appends ``2>/dev/null`` — stderr is preserved so a Tailscale check-mode login wall can
be detected and surfaced as ``CheckWallError`` carrying its approval URL. Every argv is logged at
DEBUG, but ``pre_tailnet_run`` redacts the sshpass password before logging.
"""

import os
import re
import subprocess
from dataclasses import dataclass
from typing import NoReturn

import anyio
from loguru import logger

from . import keychain
from .manifest import Machine

CHECK_WALL_RE = re.compile(r"https://login\.tailscale\.com/a/[A-Za-z0-9]+")


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


async def run(machine: Machine, command: str, *, timeout: float | None = 30, capture: bool = True) -> RemoteResult:
    argv = ["tailscale", "ssh", f"{machine.ssh.user}@{machine.name}", "--", command]
    logger.debug("remote argv: {}", argv)
    try:
        with anyio.fail_after(timeout):
            if capture:
                completed = await anyio.run_process(argv, check=False)
                result = RemoteResult(completed.returncode, completed.stdout.decode(), completed.stderr.decode())
            else:
                completed = await anyio.run_process(argv, check=False, stdout=None, stderr=None)
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
