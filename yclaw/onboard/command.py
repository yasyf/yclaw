"""The ``yclaw onboard`` command: preflight, a single-instance lock, the gate driver, a summary.

The driver runs SYNC and never goes through ``dispatch.run`` — that maps a Tailscale check-mode wall
to ``SystemExit(4)``, but the gates catch ``CheckWallError`` and loop instead. Preflight fails loud
before any gate runs: it wants the CLI tools on ``PATH``, the yclaw keychain present, the three OAuth
callback ports free on both IPv4 and IPv6, and no other onboard already holding the pid lockfile. The
summary lists every gate's verdict and, for each failure, the exact command that re-runs just it.
"""

import os
import shutil
import socket
import sys
from pathlib import Path

import click
from loguru import logger

from .. import keychain, output
from ..manifest import Manifest, load_manifest
from . import gates, ui

# The three loopback callback ports the login gates forward (Codex 1455, Gemini 8085, Google 8723);
# a browser resolves ``localhost`` to ::1 first, so both families must be free.
CALLBACK_PORTS = (1455, 8085, 8723)
REQUIRED_TOOLS = ("tailscale", "ssh", "just")


class PreflightError(Exception):
    """A precondition (tools, keychain, or a free port) is not satisfied — refuse to start."""


class OnboardLocked(Exception):
    """Another onboard run holds the lockfile (its pid is still alive)."""

    def __init__(self, path: Path, pid: int) -> None:
        super().__init__(f"another onboard is already running (pid {pid}, lock {path})")
        self.path = path
        self.pid = pid


def _port_in_use(port: int) -> bool:
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        sock = socket.socket(family, socket.SOCK_STREAM)
        # SO_REUSEADDR only skips a TIME_WAIT remnant (the immediate re-run case); on macOS a live
        # LISTEN still fails the bind, so this reports a real listener busy while not tripping over a
        # port left in TIME_WAIT (co-binding a live listener would need SO_REUSEPORT on both sides).
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((host, port))
        except OSError:
            return True
        finally:
            sock.close()
    return False


def _first_busy_port(ports: tuple[int, ...]) -> int | None:
    for port in ports:
        if _port_in_use(port):
            return port
    return None


def _preflight(ports: tuple[int, ...] | None = None) -> None:
    ports = CALLBACK_PORTS if ports is None else ports
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing:
        raise PreflightError(f"missing required tools on PATH: {', '.join(missing)} — install them and retry")
    if not keychain.KEYCHAIN_PATH.exists():
        raise PreflightError(f"no yclaw keychain at {keychain.KEYCHAIN_PATH} — run `just bootstrap` first")
    busy = _first_busy_port(ports)
    if busy is not None:
        raise PreflightError(f"host port {busy} is already in use — free it (lsof -iTCP:{busy}) and retry")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read_pid(path: Path) -> int | None:
    try:
        return int(path.read_text().strip())
    except OSError, ValueError:
        return None


def _lock_path(manifest: Manifest) -> Path:
    return Path.home() / manifest.host_paths.state_dir_rel / "onboard" / "lock"


def _acquire_lock(path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            existing = _read_pid(path)
            if existing is not None and _pid_alive(existing):
                raise OnboardLocked(path, existing) from None
            ui.note(f"replacing a stale onboard lock (pid {existing} is no longer running).")
            path.unlink(missing_ok=True)
            continue
        os.write(fd, str(os.getpid()).encode())
        return fd


def _release_lock(fd: int, path: Path) -> None:
    try:
        os.close(fd)
    except OSError:
        pass
    path.unlink(missing_ok=True)


def _confirm_retry(title: str) -> bool:
    try:
        return click.confirm(f"{title} did not complete — retry it now?", default=False)
    except click.Abort:
        # A ctrl-c at the retry prompt keeps the gate FAILED (the engine catches KeyboardInterrupt).
        raise KeyboardInterrupt from None


def _render_summary(results: list[tuple[gates.Gate, gates.GateResult]]) -> None:
    ui.hdr("Onboarding summary")
    for gate, result in results:
        if result.status is gates.GateStatus.DONE:
            ui.ok(f"{gate.title}: {result.detail}")
        elif result.status is gates.GateStatus.SKIPPED:
            ui.warn(f"{gate.title}: {result.detail or 'skipped'}")
        else:
            ui.fail(f"{gate.title}: {result.detail}")
            if result.retry_command:
                ui.note(f"    retry: {result.retry_command}")


def _exit_code(results: list[tuple[gates.Gate, gates.GateResult]]) -> int:
    failed = any(result.status is gates.GateStatus.FAILED for _, result in results)
    return output.EXIT_FAIL if failed else output.EXIT_CLEAN


@click.command()
@click.option(
    "--gate",
    "gate_key",
    default=None,
    metavar="KEY",
    help="Run a single gate: tailscale, hermes-identity, codex, gemini, google-oauth, bluebubbles, verify.",
)
@click.option("-v", "--verbose", is_flag=True, help="Enable DEBUG logging (disables spinner animation).")
def onboard(gate_key: str | None, verbose: bool) -> None:
    """Drive the human gates bootstrap stops at (idempotent — already-done gates skip)."""
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")
    ui.set_verbose(verbose)

    manifest = load_manifest()
    try:
        _preflight()
    except PreflightError as exc:
        ui.fail(str(exc))
        raise SystemExit(output.EXIT_FAIL) from None

    lock_path = _lock_path(manifest)
    try:
        fd = _acquire_lock(lock_path)
    except OnboardLocked as exc:
        ui.fail(str(exc))
        raise SystemExit(output.EXIT_FAIL) from None

    try:
        fleet_gates = gates.build_gates(manifest)
        try:
            results = gates.drive(fleet_gates, only=gate_key, confirm_retry=_confirm_retry)
        except gates.UnknownGateError as exc:
            raise click.UsageError(str(exc)) from None
        _render_summary(results)
        code = _exit_code(results)
    finally:
        _release_lock(fd, lock_path)
    raise SystemExit(code)
