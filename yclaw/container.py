"""Host-local reach into an Apple ``container`` OCI guest via ``container exec``.

A DIFFERENT transport from :mod:`yclaw.remote`: the host runs ``container exec <name> sh -c <command>``
against the local Apple ``container`` runtime, so ``remote`` stays the sole builder of ``tailscale ssh``
argv and this module is the sole builder of ``container exec`` argv. Exit codes are real here — a local
child process, not the Tailscale-intercepted ssh whose rc is always 0 on the macOS nodes.

When ``uid`` is given the payload drops privileges with ``setpriv`` before the inner ``sh -c``: the
container's agent runs as uid/gid 1000 with supplementary group 0, and group 0 is load-bearing for the
metal proxy socket the idmap presents as root:root 660 (cc-notes ca8ac58f). This mirrors the
image entrypoint's own ``exec setpriv --reuid=1000 --regid=1000 --groups=1000,0 --no-new-privs``.
"""

import shlex
from dataclasses import dataclass

import anyio
from loguru import logger

CONTAINER_BIN = "/opt/homebrew/bin/container"


class ContainerError(Exception):
    """Base class for container-exec failures."""


class ContainerTimeout(ContainerError):
    """A ``container exec`` command exceeded its timeout."""

    def __init__(self, name: str, command: str, timeout: float) -> None:
        super().__init__(f"container exec {name} timed out after {timeout}s: {command}")
        self.name = name
        self.command = command
        self.timeout = timeout


@dataclass(frozen=True, slots=True)
class ContainerResult:
    returncode: int
    stdout: str
    stderr: str


def _payload(command: str, uid: int | None) -> str:
    if uid is None:
        return command
    # setpriv drops to the agent user while keeping supplementary group 0 for the proxy socket;
    # --no-new-privs matches the entrypoint. The inner command is handed to a fresh sh as one arg.
    return f"setpriv --reuid={uid} --regid={uid} --groups={uid},0 --no-new-privs -- sh -c {shlex.quote(command)}"


async def exec_run(name: str, command: str, *, timeout: float | None = 30, uid: int | None = None) -> ContainerResult:
    argv = [CONTAINER_BIN, "exec", name, "sh", "-c", _payload(command, uid)]
    logger.debug("container argv: {}", argv)
    try:
        with anyio.fail_after(timeout):
            completed = await anyio.run_process(argv, check=False)
    except TimeoutError as exc:
        raise ContainerTimeout(name, command, timeout) from exc
    return ContainerResult(completed.returncode, completed.stdout.decode(), completed.stderr.decode())
