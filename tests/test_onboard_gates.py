import anyio
import click
import pytest

from yclaw import container, keychain, probes, remote
from yclaw.container import ContainerResult
from yclaw.onboard import cliproxy, gates, google_oauth, guest, ui
from yclaw.onboard.gates import GateStatus, build_gates
from yclaw.onboard.google_oauth import OAuthResult, VaultAuthError
from yclaw.probes import ProbeResult, Status
from yclaw.remote import CheckWallError, OutcomeKind, RemoteResult, RemoteTimeout, SessionOutcome


def _gate(manifest, key):
    return {gate.key: gate for gate in build_gates(manifest)}[key]


def _boom(*args, **kwargs):
    raise AssertionError(f"unexpected call: args={args} kwargs={kwargs}")


def _login_recorder(outcome, sink):
    async def fake(machine, command, *, user, forwards, stdin_payload, on_line, probe, fatal_markers=(), ceiling):
        sink.update(
            machine=machine,
            command=command,
            user=user,
            forwards=tuple(forwards),
            stdin_payload=stdin_payload,
            fatal_markers=tuple(fatal_markers),
            ceiling=ceiling,
            probe=probe,
        )
        return outcome

    return fake


# --- gate: tailscale ------------------------------------------------------------------------------


def test_tailscale_all_reachable_is_done(manifest, monkeypatch):
    probed: list[str] = []

    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        probed.append(machine.name)
        assert command == "true"
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = _gate(manifest, "tailscale").body()
    assert result.status is GateStatus.DONE
    # hermes is a container node (no ssh) — the Tailscale-SSH gate only covers the ssh-reached fleet.
    assert probed == ["metal", "bluebubbles"]


def test_tailscale_check_wall_opens_url_then_advances_on_approval(manifest, monkeypatch):
    monkeypatch.setattr(gates, "CHECK_POLL", 0.01)
    monkeypatch.setattr(gates, "CHECK_CEILING", 5.0)
    opened: list[str] = []
    monkeypatch.setattr(ui, "open_url", opened.append)
    seen = {"metal": 0}
    url = "https://login.tailscale.com/a/deadbeef00"

    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        if machine.name == "metal":
            seen["metal"] += 1
            if seen["metal"] <= 2:
                raise CheckWallError(url)
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = _gate(manifest, "tailscale").body()
    assert result.status is GateStatus.DONE
    assert opened == [url]  # opened exactly once, at first sighting


def test_tailscale_check_wall_ceiling_fails_with_retry_command(manifest, monkeypatch):
    monkeypatch.setattr(gates, "CHECK_POLL", 0.01)
    monkeypatch.setattr(gates, "CHECK_CEILING", 0.05)
    monkeypatch.setattr(ui, "open_url", lambda url: None)

    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        if machine.name == "metal":
            raise CheckWallError("https://login.tailscale.com/a/never")
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = _gate(manifest, "tailscale").body()
    assert result.status is GateStatus.FAILED
    assert "metal" in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate tailscale"


def test_tailscale_timeout_node_is_reported_unreachable(manifest, monkeypatch):
    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        if machine.name == "bluebubbles":
            raise RemoteTimeout("true", 30.0)
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake_run)
    result = _gate(manifest, "tailscale").body()
    assert result.status is GateStatus.FAILED
    assert "bluebubbles" in result.detail


def test_clear_check_fast_transport_failure_is_unreachable(manifest, monkeypatch):
    # The LOCAL tailscale client exits non-zero with no check URL (node off tailnet, "No route to
    # host"): rc!=0 is a transport failure, so the node is unreachable — not a swallowed remote rc.
    warned: list[str] = []
    monkeypatch.setattr(ui, "warn", warned.append)

    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        return RemoteResult(255, "", "ssh: connect to host metal port 22: No route to host")

    monkeypatch.setattr(remote, "run", fake_run)
    metal = manifest.machines["metal"]
    reachable = anyio.run(lambda: gates._clear_check(metal, ceiling=5.0, poll_interval=0.01))
    assert reachable is False
    assert any("metal" in line for line in warned)


def test_clear_check_retry_loop_ignores_transport_flake_then_approves(manifest, monkeypatch):
    monkeypatch.setattr(ui, "open_url", lambda url: None)
    url = "https://login.tailscale.com/a/deadbeef00"
    calls = {"n": 0}

    async def fake_run(machine, command, *, timeout=30, capture=True, input=None):
        calls["n"] += 1
        if calls["n"] == 1:
            raise CheckWallError(url)  # first probe -> enter the approval poll loop
        if calls["n"] == 2:
            return RemoteResult(255, "", "No route to host")  # transport flake -> keep polling
        return RemoteResult(0, "", "")  # approved

    monkeypatch.setattr(remote, "run", fake_run)
    metal = manifest.machines["metal"]
    reachable = anyio.run(lambda: gates._clear_check(metal, ceiling=5.0, poll_interval=0.01))
    assert reachable is True
    assert calls["n"] == 3


# --- gate: hermes-identity ------------------------------------------------------------------------


def test_hermes_identity_both_present_is_done_probing_container_not_ssh(manifest, monkeypatch):
    # No hermes-onboard and no prompting: the gate is a pure `container exec` check of the state dir.
    monkeypatch.setattr(click, "prompt", _boom)
    monkeypatch.setattr(remote, "run", _boom)  # the node has no ssh transport — never reached
    seen = {}

    async def fake_exec(name, command, *, timeout=30, uid=None):
        seen["name"] = name
        seen["command"] = command
        return ContainerResult(0, "USER_OK\nSOUL_OK\n", "")

    monkeypatch.setattr(container, "exec_run", fake_exec)
    result = _gate(manifest, "hermes-identity").body()
    assert result.status is GateStatus.DONE
    assert seen["name"] == "hermes"
    assert seen["command"] == gates.HERMES_IDENTITY_PROBE
    assert "USER.md" in seen["command"]
    assert "SOUL.md" in seen["command"]


@pytest.mark.parametrize(
    ("probe_out", "missing"),
    [
        ("SOUL_OK\n", "USER.md"),
        ("USER_OK\n", "SOUL.md"),
        ("", "USER.md + SOUL.md"),
    ],
    ids=["user-absent", "soul-absent", "both-absent"],
)
def test_hermes_identity_unseeded_is_manual(manifest, monkeypatch, probe_out, missing):
    monkeypatch.setattr(click, "prompt", _boom)

    async def fake_exec(name, command, *, timeout=30, uid=None):
        return ContainerResult(0, probe_out, "")

    monkeypatch.setattr(container, "exec_run", fake_exec)
    result = _gate(manifest, "hermes-identity").body()
    assert result.status is GateStatus.MANUAL
    assert missing in result.detail
    assert gates.HERMES_HOME in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate hermes-identity"


def test_hermes_identity_container_error_becomes_failed(manifest, monkeypatch):
    async def boom_exec(name, command, *, timeout=30, uid=None):
        raise container.ContainerTimeout(name, command, 30.0)

    monkeypatch.setattr(container, "exec_run", boom_exec)
    result = _gate(manifest, "hermes-identity").body()
    assert result.status is GateStatus.FAILED
    assert result.retry_command == "uv run yclaw onboard --gate hermes-identity"


# --- gate: codex ----------------------------------------------------------------------------------


def test_codex_already_logged_in_skips_login(manifest, monkeypatch):
    async def fake_list(metal):
        return ["codex-abc.json"]

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", _boom)
    monkeypatch.setattr(remote, "login_capture", _boom)
    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.DONE


def test_codex_login_success_kicks_and_records_exact_kwargs(manifest, monkeypatch):
    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        assert port == 1455
        return True

    async def fake_bin(metal):
        return "/nix/store/x-cli-proxy-api/bin/cli-proxy-api"

    kicked: list[str] = []

    async def fake_kick(metal):
        kicked.append(metal.name)

    sink: dict = {}
    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", fake_kick)
    monkeypatch.setattr(remote, "login_capture", _login_recorder(SessionOutcome(OutcomeKind.TOKEN), sink))

    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.DONE
    assert sink["user"] == "admin"
    assert sink["forwards"] == (1455,)
    assert sink["stdin_payload"] is None
    assert sink["fatal_markers"] == ()
    assert sink["ceiling"] == gates.CODEX_CEILING
    assert "--codex-login" in sink["command"]
    assert "--config '/Volumes/My Shared Files/cliproxy/config.yaml'" in sink["command"]
    assert kicked == ["metal"]


def test_codex_stale_port_uncleared_fails(manifest, monkeypatch):
    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        return False

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(remote, "login_capture", _boom)
    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.FAILED
    assert "1455" in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate codex"


@pytest.mark.parametrize(
    "kind",
    [OutcomeKind.EXITED_NO_TOKEN, OutcomeKind.TIMEOUT, OutcomeKind.FORWARD_FAILED],
    ids=["exited", "timeout", "forward-failed"],
)
def test_codex_login_failure_outcomes_fail_without_kickstart(manifest, monkeypatch, kind):
    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        return True

    async def fake_bin(metal):
        return "/bin/cpa"

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", _boom)
    monkeypatch.setattr(remote, "login_capture", _login_recorder(SessionOutcome(kind, "boom-line"), {}))
    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.FAILED
    assert kind.name in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate codex"


def test_codex_first_url_is_auto_opened_once(manifest, monkeypatch):
    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        return True

    async def fake_bin(metal):
        return "/bin/cpa"

    async def fake_kick(metal):
        pass

    opened: list[str] = []
    monkeypatch.setattr(ui, "open_url", opened.append)

    async def fake_login(machine, command, *, on_line, **kwargs):
        on_line("please visit https://auth.example/one to sign in")
        on_line("still waiting on https://auth.example/two")
        return SessionOutcome(OutcomeKind.TOKEN)

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", fake_kick)
    monkeypatch.setattr(remote, "login_capture", fake_login)
    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.DONE
    assert opened == ["https://auth.example/one"]


# --- gate: gemini ---------------------------------------------------------------------------------


def test_gemini_phase1_success_records_piped_menu_and_marker(manifest, monkeypatch):
    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        assert port == 8085
        return True

    async def fake_bin(metal):
        return "/bin/cpa"

    async def fake_kick(metal):
        pass

    sink: dict = {}
    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", fake_kick)
    monkeypatch.setattr(remote, "login_capture", _login_recorder(SessionOutcome(OutcomeKind.TOKEN), sink))
    monkeypatch.setattr(remote, "attached", _boom)
    result = _gate(manifest, "gemini").body()
    assert result.status is GateStatus.DONE
    assert sink["forwards"] == (8085,)
    assert sink["stdin_payload"] == b"2\n"
    assert sink["fatal_markers"] == ("project selection required",)
    assert sink["ceiling"] == gates.GEMINI_PHASE1_CEILING
    assert "--login" in sink["command"]
    assert "--codex-login" not in sink["command"]


def test_gemini_fatal_marker_hands_off_to_attached_then_settles(manifest, monkeypatch):
    monkeypatch.setattr(gates, "GEMINI_SETTLE_POLL", 0.01)
    listings = iter([[], ["someone@gmail.com-proj.json"]])  # detection, then settle finds the token

    async def fake_list(metal):
        return next(listings)

    async def fake_clear(metal, port):
        return True

    async def fake_bin(metal):
        return "/bin/cpa"

    kicked: list[str] = []

    async def fake_kick(metal):
        kicked.append(metal.name)

    attached: list[tuple] = []

    def fake_attached(machine, command, *, user, forwards):
        attached.append((machine.name, command, user, tuple(forwards)))

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", fake_kick)
    monkeypatch.setattr(
        remote,
        "login_capture",
        _login_recorder(SessionOutcome(OutcomeKind.FATAL_MARKER, "project selection required"), {}),
    )
    monkeypatch.setattr(remote, "attached", fake_attached)
    result = _gate(manifest, "gemini").body()
    assert result.status is GateStatus.DONE
    assert len(attached) == 1
    name, command, user, forwards = attached[0]
    assert (name, user, forwards) == ("metal", "admin", (8085,))
    assert "--login" in command
    assert kicked == ["metal"]


def test_gemini_fatal_marker_no_token_after_picker_fails(manifest, monkeypatch):
    monkeypatch.setattr(gates, "GEMINI_SETTLE_CEILING", 0.03)
    monkeypatch.setattr(gates, "GEMINI_SETTLE_POLL", 0.01)

    async def fake_list(metal):
        return []

    async def fake_clear(metal, port):
        return True

    async def fake_bin(metal):
        return "/bin/cpa"

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    monkeypatch.setattr(cliproxy, "clear_stale_login", fake_clear)
    monkeypatch.setattr(cliproxy, "resolve_bin", fake_bin)
    monkeypatch.setattr(cliproxy, "kickstart", _boom)
    monkeypatch.setattr(
        remote,
        "login_capture",
        _login_recorder(SessionOutcome(OutcomeKind.FATAL_MARKER, "project selection required"), {}),
    )
    monkeypatch.setattr(remote, "attached", lambda *a, **k: None)
    result = _gate(manifest, "gemini").body()
    assert result.status is GateStatus.FAILED
    assert result.retry_command == "uv run yclaw onboard --gate gemini"


# --- gate: google-oauth ---------------------------------------------------------------------------


def test_google_oauth_already_connected_skips_connect(manifest, monkeypatch):
    async def fake_status(config):
        return OAuthResult(connected=True, detail="connected")

    monkeypatch.setattr(google_oauth, "status", fake_status)
    monkeypatch.setattr(google_oauth, "connect", _boom)
    result = _gate(manifest, "google-oauth").body()
    assert result.status is GateStatus.DONE


def test_google_oauth_connect_success(manifest, monkeypatch):
    async def fake_status(config):
        return OAuthResult(connected=False, detail="not connected")

    async def fake_connect(config, *, open_browser, on_status, ceiling):
        assert ceiling == gates.OAUTH_CEILING
        on_status("https://consent.example/approve")
        return OAuthResult(connected=True, detail="connected")

    monkeypatch.setattr(google_oauth, "status", fake_status)
    monkeypatch.setattr(google_oauth, "connect", fake_connect)
    result = _gate(manifest, "google-oauth").body()
    assert result.status is GateStatus.DONE


def test_google_oauth_named_error_fails_with_message(manifest, monkeypatch):
    async def fake_status(config):
        return OAuthResult(connected=False, detail="not connected")

    async def fake_connect(config, *, open_browser, on_status, ceiling):
        raise VaultAuthError("http://metal:14321", 401)

    monkeypatch.setattr(google_oauth, "status", fake_status)
    monkeypatch.setattr(google_oauth, "connect", fake_connect)
    result = _gate(manifest, "google-oauth").body()
    assert result.status is GateStatus.FAILED
    assert "401" in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate google-oauth"


# --- gate: bluebubbles ----------------------------------------------------------------------------


def test_bluebubbles_already_healthy_skips_setup(manifest, monkeypatch):
    async def fake_health(machine, **kwargs):
        return ProbeResult("bluebubbles", Status.PASS, "ok")

    monkeypatch.setattr(probes, "bluebubbles_health", fake_health)
    monkeypatch.setattr(guest, "guest_pipe", _boom)
    result = _gate(manifest, "bluebubbles").body()
    assert result.status is GateStatus.DONE


def test_bluebubbles_polls_then_pipes_setup_with_secrets_in_env(manifest, monkeypatch, tmp_path):
    monkeypatch.setattr(gates, "BB_POLL", 0.01)
    monkeypatch.setattr(ui, "open_url", lambda url: None)
    monkeypatch.setattr(gates, "_host_tailnet_ip", lambda: "100.64.0.7")
    monkeypatch.setattr(keychain, "read", lambda service: "bb-server-pw")
    monkeypatch.setattr(gates.Path, "home", lambda: tmp_path)

    node_dir = tmp_path / manifest.host_paths.node_config_dir_rel
    node_dir.mkdir(parents=True)
    (node_dir / "node.env").write_text(
        "BLUEBUBBLES_ALLOWED_USERS=+15551234567,+15559990000\nBLUEBUBBLES_HOME_CHANNEL=x\n"
    )

    states = iter([Status.FAIL, Status.PASS, Status.PASS])  # detection, poll, final

    async def fake_health(machine, **kwargs):
        return ProbeResult("bluebubbles", next(states), "x")

    piped: dict = {}

    async def fake_pipe(machine, script, *args, env):
        piped.update(machine=machine.name, script=script, args=args, env=dict(env))

    monkeypatch.setattr(probes, "bluebubbles_health", fake_health)
    monkeypatch.setattr(guest, "guest_pipe", fake_pipe)

    result = _gate(manifest, "bluebubbles").body()
    assert result.status is GateStatus.DONE
    assert piped["machine"] == "bluebubbles"
    assert piped["args"] == ("setup",)
    assert piped["script"].endswith("scripts/bluebubbles-setup.sh")
    assert piped["env"] == {
        "BLUEBUBBLES_PASSWORD": "bb-server-pw",
        "BLUEBUBBLES_ALLOWED_USERS": "+15551234567,+15559990000",
        "BB_ALLOWED_HOST_IP": "100.64.0.7",
    }


def test_bluebubbles_missing_node_env_fails_before_pipe(manifest, monkeypatch, tmp_path):
    monkeypatch.setattr(gates, "BB_POLL", 0.01)
    monkeypatch.setattr(ui, "open_url", lambda url: None)
    monkeypatch.setattr(keychain, "read", lambda service: "bb-server-pw")
    monkeypatch.setattr(gates.Path, "home", lambda: tmp_path)  # no node.env under it
    monkeypatch.setattr(guest, "guest_pipe", _boom)

    states = iter([Status.FAIL, Status.PASS])

    async def fake_health(machine, **kwargs):
        return ProbeResult("bluebubbles", next(states), "x")

    monkeypatch.setattr(probes, "bluebubbles_health", fake_health)
    result = _gate(manifest, "bluebubbles").body()
    assert result.status is GateStatus.FAILED
    assert "node.env" in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate bluebubbles"


# --- gate: verify ---------------------------------------------------------------------------------


def test_verify_runs_validate_then_smoke_locally(manifest, monkeypatch):
    argvs: list[list[str]] = []

    def fake_run_attached(argv):
        argvs.append(list(argv))
        return 0

    monkeypatch.setattr(remote, "run_attached", fake_run_attached)
    result = _gate(manifest, "verify").body()
    assert result.status is GateStatus.DONE
    assert argvs == [["just", "validate"], ["just", "smoke"]]


@pytest.mark.parametrize(
    ("validate_rc", "smoke_rc", "expect_command", "expect_rc"),
    [(1, 0, "just validate", "rc 1"), (0, 2, "just smoke", "rc 2")],
    ids=["validate-red", "smoke-red"],
)
def test_verify_fails_on_nonzero_local_rc(manifest, monkeypatch, validate_rc, smoke_rc, expect_command, expect_rc):
    rcs = {("just", "validate"): validate_rc, ("just", "smoke"): smoke_rc}
    monkeypatch.setattr(remote, "run_attached", lambda argv: rcs[tuple(argv)])
    result = _gate(manifest, "verify").body()
    assert result.status is GateStatus.FAILED
    assert expect_command in result.detail
    assert expect_rc in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate verify"


# --- _guard (per-gate fleet-error conversion) -----------------------------------------------------


def test_guard_converts_share_unmounted_during_codex_detection(manifest, monkeypatch):
    async def fake_list(metal):
        raise cliproxy.ShareUnmounted(cliproxy.CLIPROXY_AUTH_DIR)

    monkeypatch.setattr(cliproxy, "list_auth_files", fake_list)
    result = _gate(manifest, "codex").body()
    assert result.status is GateStatus.FAILED
    assert "not mounted" in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate codex"


def test_guard_converts_checkwall_to_failed_with_url_in_detail():
    url = "https://login.tailscale.com/a/abc123def0"

    def body() -> GateStatus:
        raise CheckWallError(url)

    result = gates._guard("codex", body)()
    assert result.status is GateStatus.FAILED
    assert url in result.detail
    assert result.retry_command == "uv run yclaw onboard --gate codex"


def test_guard_lets_unexpected_exceptions_propagate():
    def body() -> GateStatus:
        raise ValueError("not a fleet error")

    with pytest.raises(ValueError):
        gates._guard("codex", body)()
