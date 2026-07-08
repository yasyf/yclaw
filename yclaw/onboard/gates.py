"""The onboard gate engine: run a sequence of gates, retrying the failures the operator chooses to.

A :class:`Gate` pairs a selector ``key`` with a sync ``body`` that returns a :class:`GateResult`;
the body owns its own event loop (it calls ``anyio.run`` internally for async steps) so the terminal
hand-off in an interactive gate happens with no loop alive. :func:`drive` is pure control flow — it
carries no fleet or ssh knowledge, so it is exercised without mocks. It runs gates in order (or just
the one named by ``only``), re-runs a FAILED gate while ``confirm_retry`` keeps saying yes, and turns
a ctrl-c inside a body into a SKIPPED result instead of letting it escape. Exit-code policy lives in
``command.py``, not here.
"""

import enum
import re
import subprocess
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

import anyio
import click

from .. import keychain, probes, remote
from ..manifest import Machine, Manifest
from . import cliproxy, google_oauth, guest, ui

SKIPPED_BY_USER = "skipped by user (ctrl-c)"

# Every human-visible failure names the exact command that re-runs just that gate.
RETRY_TEMPLATE = "uv run yclaw onboard --gate {}"

# Ceilings and poll cadences (seconds). Module constants so tests shrink them to keep timings tiny.
CHECK_CEILING = 600.0  # Tailscale SSH re-auth is human-paced but bounded (~10 min)
CHECK_POLL = 5.0
CODEX_CEILING = 900.0  # Codex OAuth incl. the 15s stdin paste fallback
GEMINI_PHASE1_CEILING = 360.0  # upstream caps the OAuth at 5 min; more is pointless
GEMINI_SETTLE_CEILING = 15.0  # after the attached picker, the token lands with fs latency
GEMINI_SETTLE_POLL = 3.0
BB_POLL = 5.0  # BlueBubbles helper poll is UNBOUNDED (human-paced; ctrl-c skips the gate)
OAUTH_CEILING = 600.0
HERMES_ONBOARD_TIMEOUT = 300.0  # hermes-onboard makes Honcho network calls; the 30s default is too tight

# The upstream marker that means Google One auto-discovery failed and a project must be picked
# by hand — triggers the attached-terminal phase-2 hand-off. Authored from cli-proxy-api source.
GEMINI_FATAL_MARKER = "project selection required"

# hermes identity: the sentinel probe re-derives cfg.stateDir/workingDirectory from the installed
# hermes-onboard script (writeShellApplication bakes them in), so nothing is hardcoded here. Fed
# over stdin to `bash -s` to dodge the tailscale-ssh remote-arg word-split. USER_OK/SOUL_OK are the
# only signal — remote exit codes are garbage over the Tailscale intercept.
HERMES_PROBE_CMD = "sudo -u hermes -H bash -s"
HERMES_ONBOARD_CMD = "sudo -u hermes -H hermes-onboard"
HERMES_IDENTITY_PROBE = (
    b's="$(command -v hermes-onboard)" || exit 0\n'
    b'eval "$(grep -E \'^[[:space:]]*(export HOME=|export HERMES_HOME=|workspace=|memdir=|usermd=|soulmd=)\' "$s")"\n'
    b'[ -s "$usermd" ] && echo USER_OK\n'
    b'[ -s "$soulmd" ] && echo SOUL_OK\n'
    b"exit 0\n"
)

# node.env (host-side, written by bootstrap.sh) carries the non-secret iMessage allowlist.
NODE_ENV_ALLOWLIST_KEY = "BLUEBUBBLES_ALLOWED_USERS"

_URL_RE = re.compile(r"https://\S+")

# onboard/ -> yclaw/ -> repo root; the guest bring-up script lives under scripts/.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BLUEBUBBLES_SETUP = REPO_ROOT / "scripts" / "bluebubbles-setup.sh"


class OnboardError(Exception):
    """Base class for onboard engine failures."""


class UnknownGateError(OnboardError):
    """``drive(..., only=key)`` named a gate that is not in the sequence."""

    def __init__(self, key: str, known: Sequence[str]) -> None:
        super().__init__(f"unknown gate {key!r}; known: {', '.join(known)}")
        self.key = key
        self.known = tuple(known)


class AllowlistMissing(OnboardError):
    """The host node.env is absent or carries no BLUEBUBBLES_ALLOWED_USERS (bootstrap incomplete)."""


class GateStatus(enum.Enum):
    DONE = enum.auto()
    SKIPPED = enum.auto()
    FAILED = enum.auto()


@dataclass(frozen=True, slots=True)
class GateResult:
    status: GateStatus
    detail: str = ""
    retry_command: str = ""


@dataclass(frozen=True, slots=True)
class Gate:
    key: str
    title: str
    body: Callable[[], GateResult]


def _select(gates: Sequence[Gate], only: str | None) -> list[Gate]:
    if only is None:
        return list(gates)
    for gate in gates:
        if gate.key == only:
            return [gate]
    raise UnknownGateError(only, [gate.key for gate in gates])


def _run_gate(gate: Gate, confirm_retry: Callable[[str], bool]) -> GateResult:
    while True:
        try:
            result = gate.body()
        except (KeyboardInterrupt, click.Abort):
            # click.prompt turns a ctrl-c into click.Abort, not KeyboardInterrupt.
            return GateResult(GateStatus.SKIPPED, detail=SKIPPED_BY_USER)
        if result.status is not GateStatus.FAILED:
            return result
        try:
            retry = confirm_retry(gate.title)
        except KeyboardInterrupt:
            return result
        if not retry:
            return result


def drive(
    gates: Sequence[Gate],
    *,
    only: str | None = None,
    confirm_retry: Callable[[str], bool],
) -> list[tuple[Gate, GateResult]]:
    return [(gate, _run_gate(gate, confirm_retry)) for gate in _select(gates, only)]


# --- gate helpers ---------------------------------------------------------------------------------
# Each gate body is SYNC and enters the event loop per async step with ``anyio.run`` — so the
# interactive hand-off (a ``click.prompt`` or an attached child) happens with no loop alive. Every
# remote decision is made client-side from output; a returncode is never consulted.


async def _clear_check(machine: Machine, *, ceiling: float, poll_interval: float) -> bool:
    try:
        result = await remote.run(machine, "true")
    except remote.RemoteTimeout:
        ui.warn(f"{machine.name} not reachable over Tailscale SSH (timed out).")
        return False
    except remote.CheckWallError as exc:
        url = exc.url
    else:
        # rc here is the LOCAL tailscale client's — non-zero is a transport failure, not a remote rc.
        if result.returncode != 0:
            ui.warn(f"{machine.name} not reachable over Tailscale SSH.")
            return False
        ui.ok(f"{machine.name} reachable over Tailscale SSH.")
        return True
    ui.note(f"{machine.name}: Tailscale wants you to re-authorize SSH — open:")
    ui.note(f"  {url}")
    ui.open_url(url)
    async with ui.Spinner(f"waiting for Tailscale SSH approval → {machine.name}") as spin:
        with anyio.move_on_after(ceiling):
            while True:
                await anyio.sleep(poll_interval)
                try:
                    result = await remote.run(machine, "true")
                except remote.CheckWallError, remote.RemoteTimeout:
                    continue
                if result.returncode != 0:
                    continue
                spin.ok(f"{machine.name} reachable — check approved.")
                return True
        spin.fail(f"{machine.name} not reachable after {ceiling:.0f}s.")
    return False


def _hermes_identity_state(hermes: Machine) -> str:
    return anyio.run(lambda: remote.run(hermes, HERMES_PROBE_CMD, input=HERMES_IDENTITY_PROBE)).stdout


def _login_command(bin_path: str, login_flag: str) -> str:
    # bin is a nix-store path and the config path carries a space — both single-quoted for the
    # remote login shell. Flag order matches the authored spec; the CLI is order-insensitive.
    return f"'{bin_path}' {login_flag} --no-browser --config '{cliproxy.CLIPROXY_CONFIG}'"


def _codex_probe(metal: Machine) -> Callable[[], Awaitable[bool]]:
    async def probe() -> bool:
        return cliproxy.has_codex(await cliproxy.list_auth_files(metal))

    return probe


def _gemini_probe(metal: Machine) -> Callable[[], Awaitable[bool]]:
    async def probe() -> bool:
        return cliproxy.has_gemini(await cliproxy.list_auth_files(metal))

    return probe


async def _run_login(
    machine: Machine,
    command: str,
    *,
    forwards: Sequence[int],
    stdin_payload: bytes | None,
    probe: Callable[[], Awaitable[bool]],
    ceiling: float,
    fatal_markers: Sequence[str] = (),
) -> remote.SessionOutcome:
    opened = [False]

    def on_line(line: str) -> None:
        if line:
            ui.note(line)
        if not opened[0]:
            match = _URL_RE.search(line)
            if match is not None:
                opened[0] = True
                ui.open_url(match.group(0))

    return await remote.login_capture(
        machine,
        command,
        user="admin",
        forwards=forwards,
        stdin_payload=stdin_payload,
        on_line=on_line,
        probe=probe,
        fatal_markers=fatal_markers,
        ceiling=ceiling,
    )


def _login_failure_detail(outcome: remote.SessionOutcome, label: str) -> str:
    detail = f"{label} login did not complete ({outcome.kind.name})"
    if outcome.line:
        detail += f": {outcome.line}"
    return detail


async def _settle_has_gemini(metal: Machine) -> bool:
    with anyio.move_on_after(GEMINI_SETTLE_CEILING):
        while True:
            if cliproxy.has_gemini(await cliproxy.list_auth_files(metal)):
                return True
            await anyio.sleep(GEMINI_SETTLE_POLL)
    return False


async def _wait_bluebubbles_healthy(bluebubbles: Machine) -> None:
    async with ui.Spinner("waiting for the BlueBubbles helper to connect (sign in over VNC)…") as spin:
        while True:
            if (await probes.bluebubbles_health(bluebubbles)).status is probes.Status.PASS:
                spin.ok("BlueBubbles helper connected.")
                return
            await anyio.sleep(BB_POLL)


def _read_allowlist(manifest: Manifest) -> str:
    node_env = Path.home() / manifest.host_paths.node_config_dir_rel / "node.env"
    if not node_env.exists():
        raise AllowlistMissing(f"no {node_env} (the iMessage allowlist) — run `just bootstrap`")
    for line in node_env.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() == NODE_ENV_ALLOWLIST_KEY:
            return value.strip()
    raise AllowlistMissing(f"{node_env} has no {NODE_ENV_ALLOWLIST_KEY}")


def _host_tailnet_ip() -> str:
    # The operator's OWN tailnet IP (authorizes this host on bluebubbles' pf gate). Resolved
    # host-side: the guest's own `tailscale ip -4` would be bluebubbles' address. An empty result
    # leaves the guest allowlist untouched (setup skips the seed), mirroring the bash `local` mask.
    result = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, check=False)
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[0] if lines else ""


# --- the seven gates ------------------------------------------------------------------------------


def _guard(key: str, body: Callable[[], GateResult]) -> Callable[[], GateResult]:
    # An operator-facing remote/cliproxy/keychain failure (check wall, unmounted share, timeout,
    # missing keychain item) becomes a FAILED gate the retry loop can re-drive, not a raw traceback;
    # CheckWallError's message carries the approval URL, so the detail surfaces it. Everything else
    # propagates loud.
    def guarded() -> GateResult:
        try:
            return body()
        except (remote.RemoteError, cliproxy.CliproxyError, keychain.KeychainError) as exc:
            return GateResult(GateStatus.FAILED, detail=str(exc), retry_command=RETRY_TEMPLATE.format(key))

    return guarded


def build_gates(manifest: Manifest) -> tuple[Gate, ...]:
    """Assemble the ordered gate sequence from the fleet manifest."""
    metal = manifest.machines["metal"]
    hermes = manifest.machines["hermes"]
    bluebubbles = manifest.machines["bluebubbles"]
    fleet = tuple(machine for machine in manifest.machines.values() if machine.ssh is not None)

    def tailscale_body() -> GateResult:
        unreachable = [
            machine.name
            for machine in fleet
            if not anyio.run(lambda m=machine: _clear_check(m, ceiling=CHECK_CEILING, poll_interval=CHECK_POLL))
        ]
        if unreachable:
            return GateResult(
                GateStatus.FAILED,
                detail=f"not reachable over Tailscale SSH: {', '.join(unreachable)}",
                retry_command=RETRY_TEMPLATE.format("tailscale"),
            )
        return GateResult(GateStatus.DONE, detail=f"all fleet nodes reachable ({', '.join(m.name for m in fleet)})")

    def hermes_identity_body() -> GateResult:
        state = _hermes_identity_state(hermes)
        user_ok = "USER_OK" in state
        soul_ok = "SOUL_OK" in state
        if user_ok and soul_ok:
            return GateResult(GateStatus.DONE, detail="hermes already onboarded (USER.md + SOUL.md present)")
        ui.hdr("Gate — hermes identity")
        ui.note("Seeds the profile (USER.md) and persona (SOUL.md) hermes-onboard can't infer.")
        feed = ""
        if user_ok:
            ui.ok("USER.md already present — keeping it.")
        else:
            name = click.prompt("  Your name", default="", show_default=False)
            about = click.prompt("  A sentence or two about you", default="", show_default=False)
            feed += f"{name}\n{about}\n"
        if soul_ok:
            ui.ok("SOUL.md already present — keeping it.")
        else:
            persona = click.prompt(
                "  Agent persona in one line (blank = sensible default)", default="", show_default=False
            )
            feed += f"{persona}\n"
        anyio.run(lambda: remote.run(hermes, HERMES_ONBOARD_CMD, input=feed.encode(), timeout=HERMES_ONBOARD_TIMEOUT))
        state = _hermes_identity_state(hermes)
        if "USER_OK" in state and "SOUL_OK" in state:
            return GateResult(GateStatus.DONE, detail="hermes identity written (USER.md + SOUL.md)")
        return GateResult(
            GateStatus.FAILED,
            detail="hermes onboarding did not leave both USER.md and SOUL.md",
            retry_command=RETRY_TEMPLATE.format("hermes-identity"),
        )

    def codex_body() -> GateResult:
        if cliproxy.has_codex(anyio.run(lambda: cliproxy.list_auth_files(metal))):
            return GateResult(GateStatus.DONE, detail="Codex already logged in (codex-*.json present)")
        ui.hdr("Gate — CLIProxyAPI Codex login")
        ui.note("Approve with your ChatGPT-subscription account; the callback is forwarded, so no paste.")
        if not anyio.run(lambda: cliproxy.clear_stale_login(metal, cliproxy.CODEX_CALLBACK_PORT)):
            return GateResult(
                GateStatus.FAILED,
                detail=f"port {cliproxy.CODEX_CALLBACK_PORT} still busy on metal (stale login could not be cleared)",
                retry_command=RETRY_TEMPLATE.format("codex"),
            )
        command = _login_command(anyio.run(lambda: cliproxy.resolve_bin(metal)), "--codex-login")
        outcome = anyio.run(
            lambda: _run_login(
                metal,
                command,
                forwards=[cliproxy.CODEX_CALLBACK_PORT],
                stdin_payload=None,
                probe=_codex_probe(metal),
                ceiling=CODEX_CEILING,
            )
        )
        if outcome.kind is remote.OutcomeKind.TOKEN:
            anyio.run(lambda: cliproxy.kickstart(metal))
            return GateResult(GateStatus.DONE, detail="Codex login succeeded (codex-*.json written)")
        return GateResult(
            GateStatus.FAILED,
            detail=_login_failure_detail(outcome, "Codex"),
            retry_command=RETRY_TEMPLATE.format("codex"),
        )

    def gemini_body() -> GateResult:
        if cliproxy.has_gemini(anyio.run(lambda: cliproxy.list_auth_files(metal))):
            return GateResult(GateStatus.DONE, detail="Gemini already logged in (token present)")
        ui.hdr("Gate — CLIProxyAPI Gemini login")
        ui.note("Approve with your personal Google account; the callback is forwarded, so no paste.")
        if not anyio.run(lambda: cliproxy.clear_stale_login(metal, cliproxy.GEMINI_CALLBACK_PORT)):
            return GateResult(
                GateStatus.FAILED,
                detail=f"port {cliproxy.GEMINI_CALLBACK_PORT} still busy on metal (stale login could not be cleared)",
                retry_command=RETRY_TEMPLATE.format("gemini"),
            )
        command = _login_command(anyio.run(lambda: cliproxy.resolve_bin(metal)), "--login")
        outcome = anyio.run(
            lambda: _run_login(
                metal,
                command,
                forwards=[cliproxy.GEMINI_CALLBACK_PORT],
                stdin_payload=b"2\n",
                probe=_gemini_probe(metal),
                ceiling=GEMINI_PHASE1_CEILING,
                fatal_markers=(GEMINI_FATAL_MARKER,),
            )
        )
        if outcome.kind is remote.OutcomeKind.TOKEN:
            anyio.run(lambda: cliproxy.kickstart(metal))
            return GateResult(GateStatus.DONE, detail="Gemini login succeeded (token written)")
        if outcome.kind is remote.OutcomeKind.FATAL_MARKER:
            ui.warn("Gemini's Google One auto-discovery failed — your account needs a project picked.")
            ui.note("cli-proxy-api will hand you its project picker: choose option 1 and pick a project.")
            ui.note("The browser OAuth repeats (usually one click).")
            remote.attached(metal, command, user="admin", forwards=[cliproxy.GEMINI_CALLBACK_PORT])
            if anyio.run(lambda: _settle_has_gemini(metal)):
                anyio.run(lambda: cliproxy.kickstart(metal))
                return GateResult(
                    GateStatus.DONE, detail="Gemini login succeeded (project picked in the attached picker)"
                )
            return GateResult(
                GateStatus.FAILED,
                detail="Gemini login did not leave a token after the project picker",
                retry_command=RETRY_TEMPLATE.format("gemini"),
            )
        return GateResult(
            GateStatus.FAILED,
            detail=_login_failure_detail(outcome, "Gemini"),
            retry_command=RETRY_TEMPLATE.format("gemini"),
        )

    def google_oauth_body() -> GateResult:
        config = google_oauth.config_for_machine(metal)
        if anyio.run(lambda: google_oauth.status(config)).connected:
            return GateResult(GateStatus.DONE, detail="Google Workspace OAuth already connected to the hermes vault")
        ui.hdr("Gate — agent-vault Google Workspace OAuth")
        ui.note("Reuses your local gws desktop OAuth client; approve ONE consent URL in a browser on this Mac.")

        def on_status(url: str) -> None:
            ui.note("Open this consent URL and approve the requested scopes:")
            ui.note(f"  {url}")

        try:
            result = anyio.run(
                lambda: google_oauth.connect(
                    config, open_browser=ui.open_url, on_status=on_status, ceiling=OAUTH_CEILING
                )
            )
        except (google_oauth.GoogleOAuthError, keychain.KeychainError) as exc:
            return GateResult(GateStatus.FAILED, detail=str(exc), retry_command=RETRY_TEMPLATE.format("google-oauth"))
        if result.connected:
            return GateResult(GateStatus.DONE, detail="Google Workspace OAuth connected")
        return GateResult(
            GateStatus.FAILED,
            detail="vault did not report connected:true",
            retry_command=RETRY_TEMPLATE.format("google-oauth"),
        )

    def bluebubbles_body() -> GateResult:
        if anyio.run(lambda: probes.bluebubbles_health(bluebubbles)).status is probes.Status.PASS:
            return GateResult(
                GateStatus.DONE, detail="BlueBubbles already healthy (server + Private API helper connected)"
            )
        ui.hdr("Gate — Apple-ID iMessage / BlueBubbles")
        ui.note("The one irreducibly-human gate: sign into the dedicated Apple ID + 2FA in the VNC window.")
        ui.note("You type the Apple-ID password and 2FA code in the GUI — they never touch this process.")
        ui.open_url("vnc://bluebubbles")
        anyio.run(lambda: _wait_bluebubbles_healthy(bluebubbles))
        password = keychain.read(bluebubbles.services["bluebubbles"].password_keychain)
        try:
            allowlist = _read_allowlist(manifest)
        except AllowlistMissing as exc:
            return GateResult(GateStatus.FAILED, detail=str(exc), retry_command=RETRY_TEMPLATE.format("bluebubbles"))
        env = {
            "BLUEBUBBLES_PASSWORD": password,
            "BLUEBUBBLES_ALLOWED_USERS": allowlist,
            "BB_ALLOWED_HOST_IP": _host_tailnet_ip(),
        }
        anyio.run(lambda: guest.guest_pipe(bluebubbles, str(BLUEBUBBLES_SETUP), "setup", env=env))
        if anyio.run(lambda: probes.bluebubbles_health(bluebubbles)).status is probes.Status.PASS:
            return GateResult(
                GateStatus.DONE, detail="BlueBubbles healthy — setup auto-hardened (Screen Sharing disabled)"
            )
        return GateResult(
            GateStatus.FAILED,
            detail="BlueBubbles not healthy yet — grant Full Disk Access + Accessibility over VNC, then retry",
            retry_command=RETRY_TEMPLATE.format("bluebubbles"),
        )

    def verify_body() -> GateResult:
        ui.hdr("Final — validate + smoke")
        ui.note("Running `just validate` (per-VM isolation + audit hardening probes)…")
        validate_rc = remote.run_attached(["just", "validate"])
        ui.note("Running `just smoke` (nix flake check + model-plane curl + hermes doctor)…")
        smoke_rc = remote.run_attached(["just", "smoke"])
        ui.note("Final manual check: send an iMessage from an allowlisted handle and confirm hermes replies")
        ui.note("(and that a non-allowlisted handle is ignored).")
        # `just` runs LOCALLY, so its rc is trustworthy (unlike a remote child's over the intercept).
        runs = (("just validate", validate_rc), ("just smoke", smoke_rc))
        failed = [f"{name} (rc {rc})" for name, rc in runs if rc != 0]
        if failed:
            return GateResult(
                GateStatus.FAILED,
                detail=f"{' and '.join(failed)} reported failures — see the output above",
                retry_command=RETRY_TEMPLATE.format("verify"),
            )
        return GateResult(GateStatus.DONE, detail="validate + smoke run (review their output above)")

    return (
        Gate("tailscale", "Tailscale SSH access", _guard("tailscale", tailscale_body)),
        Gate("hermes-identity", "hermes identity (USER.md + SOUL.md)", _guard("hermes-identity", hermes_identity_body)),
        Gate("codex", "CLIProxyAPI Codex login", _guard("codex", codex_body)),
        Gate("gemini", "CLIProxyAPI Gemini login", _guard("gemini", gemini_body)),
        Gate("google-oauth", "agent-vault Google Workspace OAuth", _guard("google-oauth", google_oauth_body)),
        Gate("bluebubbles", "Apple-ID iMessage / BlueBubbles", _guard("bluebubbles", bluebubbles_body)),
        Gate("verify", "validate + smoke", _guard("verify", verify_body)),
    )
