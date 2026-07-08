"""Deliver a guest bootstrap script over the Tailscale SSH stdin pipe — ``guest_pipe`` parity.

Mirrors ``scripts/lib/ssh.sh``'s ``guest_pipe``: the stdin payload is ``wait.sh`` + ``pf.sh`` + the
per-node prelude + ``export`` lines for the caller's env + the script bytes, fed to
``/bin/bash -s -- <args>``. Env values may be secrets, so they ride the stdin stream (never argv,
never logs) and the payload itself is never logged. Success is decided by the caller's own probes,
not by this delivery — remote exit codes are garbage over the Tailscale intercept.
"""

import shlex
from collections.abc import Mapping
from pathlib import Path

from .. import remote
from ..manifest import Machine, load_manifest

_LIB_DIR = Path(__file__).resolve().parent.parent.parent / "scripts" / "lib"
WAIT_SH = _LIB_DIR / "wait.sh"
PF_SH = _LIB_DIR / "pf.sh"
GUEST_PIPE_TIMEOUT = 600.0


def _prelude(machine: Machine) -> str:
    lines = [f"YCLAW_NODE={machine.name}\n"]
    debloat = load_manifest().debloat.get(machine.name)
    if debloat is not None:
        lines.append(f"YCLAW_DEBLOAT_SYSTEM='{' '.join(debloat.system)}'\n")
        lines.append(f"YCLAW_DEBLOAT_GUI='{' '.join(debloat.gui)}'\n")
    return "".join(lines)


async def guest_pipe(machine: Machine, script_path: str, *args: str, env: Mapping[str, str] = {}) -> None:
    exports = "".join(f"export {name}={shlex.quote(value)}\n" for name, value in env.items())
    payload = b"".join(
        (
            WAIT_SH.read_bytes(),
            PF_SH.read_bytes(),
            _prelude(machine).encode(),
            exports.encode(),
            Path(script_path).read_bytes(),
        )
    )
    command = "/bin/bash -s --"
    if args:
        command += " " + " ".join(shlex.quote(arg) for arg in args)
    await remote.run(machine, command, input=payload, capture=False, timeout=GUEST_PIPE_TIMEOUT)
