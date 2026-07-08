"""CLIProxyAPI (metal) helpers for the onboarding Codex/Gemini login gates.

Every remote decision is made client-side from command output: remote exit codes are garbage over
the Tailscale SSH intercept (always 0 on the macOS nodes). No remote shell globs (admin's zsh
nomatch is fatal, root's /bin/sh passes them literally) and no ``cat`` of token files over the wire
— token presence is decided from filenames alone.
"""

import fnmatch
from collections.abc import Iterable

from loguru import logger

from .. import remote
from ..manifest import Machine
from ..remote import RemoteError

# The cli-proxy runtime config + auth dir live on a virtiofs share mounted into metal; the path
# carries a space, so every remote reference single-quotes it.
CLIPROXY_CONFIG = "/Volumes/My Shared Files/cliproxy/config.yaml"
CLIPROXY_AUTH_DIR = "/Volumes/My Shared Files/cliproxy/auth"
CLIPROXY_SERVICE = "cliproxy"

CODEX_CALLBACK_PORT = 1455  # redirect_uri is hardcoded to localhost:1455 upstream — never override
GEMINI_CALLBACK_PORT = 8085  # upstream --login callback port

AUTH_DIR_SENTINEL = "__AUTH_DIR__"
# `cd` fires the Tahoe virtiofs automount on a direct path stat; the sentinel proves the listing ran
# (its absence means the share is gone, not merely empty); `; true` keeps the remote zsh from
# decorating the tail.
LIST_AUTH_COMMAND = f"cd '{CLIPROXY_AUTH_DIR}' 2>/dev/null && {{ echo {AUTH_DIR_SENTINEL}; ls -1; }}; true"

# The `[c]` bracket keeps grep from matching its own argv; awk prints argv[0] = the running binary.
_PS_RESOLVE_COMMAND = "ps -axo command | grep -m1 '[c]li-proxy-api --config' | awk '{print $1}'"
# Glob-free store fallback: list newest-first, reduce with a remote grep (not a shell glob), then
# decide client-side — the buildGoModule `-go-modules` sibling and the `.drv` share the substring
# but carry no `bin/cli-proxy-api`.
_STORE_LIST_COMMAND = "ls -1t /nix/store | grep -e -cli-proxy-api-"

# pkill -f pattern for a stray login child. The `[-]` bracket stops pkill matching its OWN argv
# (whose literal `[-]login` never contains a bare `-login`), while `--codex-login` and ` --login` do.
PKILL_LOGIN_PATTERN = "cli-proxy-api.*[-]login"


class CliproxyError(Exception):
    """Base class for CLIProxyAPI onboarding-helper failures."""


class CliproxyBinNotFound(CliproxyError):
    """No running cli-proxy-api process and no store binary — the daemon is absent."""


class ShareUnmounted(CliproxyError):
    """The cli-proxy auth-dir share is not mounted on metal (the sentinel never printed)."""

    def __init__(self, path: str) -> None:
        super().__init__(f"cli-proxy auth dir not mounted on metal: {path}")
        self.path = path


def has_codex(names: Iterable[str]) -> bool:
    return any(fnmatch.fnmatchcase(name, "codex-*.json") for name in names)


def has_gemini(names: Iterable[str]) -> bool:
    return any(
        name.endswith(".json") and not fnmatch.fnmatchcase(name, "codex-*.json") and "@" in name for name in names
    )


async def resolve_bin(metal: Machine) -> str:
    running = (await remote.run(metal, _PS_RESOLVE_COMMAND)).stdout.strip()
    if running:
        return running
    for line in (await remote.run(metal, _STORE_LIST_COMMAND)).stdout.splitlines():
        name = line.strip()
        if name and not name.endswith((".drv", "-go-modules")):
            return f"/nix/store/{name}/bin/cli-proxy-api"
    raise CliproxyBinNotFound("cli-proxy-api not found on metal (no running process, no store output)")


async def list_auth_files(metal: Machine) -> list[str]:
    lines = [line.strip() for line in (await remote.run(metal, LIST_AUTH_COMMAND)).stdout.splitlines()]
    if AUTH_DIR_SENTINEL not in lines:
        raise ShareUnmounted(CLIPROXY_AUTH_DIR)
    return [name for name in lines[lines.index(AUTH_DIR_SENTINEL) + 1 :] if name]


async def clear_stale_login(metal: Machine, port: int) -> bool:
    lsof = f"lsof -nP -iTCP:{port} -sTCP:LISTEN"
    if not (await remote.run(metal, lsof)).stdout.strip():
        return True
    await remote.run(metal, f"pkill -f '{PKILL_LOGIN_PATTERN}'")
    return not (await remote.run(metal, lsof)).stdout.strip()


async def kickstart(metal: Machine) -> None:
    label = metal.services[CLIPROXY_SERVICE].launchd.target
    try:
        await remote.run(metal, f"launchctl kickstart -k {label}")
    except RemoteError as exc:
        logger.warning("cliproxy kickstart failed (best-effort, ignoring): {}", exc)
