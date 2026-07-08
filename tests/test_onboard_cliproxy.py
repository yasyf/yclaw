import re

import pytest
from loguru import logger

from yclaw import remote
from yclaw.onboard import cliproxy
from yclaw.onboard.cliproxy import CliproxyBinNotFound, ShareUnmounted, has_codex, has_gemini
from yclaw.remote import RemoteResult, RemoteTimeout

pytestmark = pytest.mark.anyio


def _fake_run(responses):
    """A fake remote.run: return the RemoteResult (or raise the Exception) for the first command
    that contains the paired needle, recording every command string in order."""
    calls: list[str] = []

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        calls.append(command)
        for needle, result in responses:
            if needle in command:
                if isinstance(result, Exception):
                    raise result
                return result
        raise AssertionError(f"unexpected remote command: {command!r}")

    return fake, calls


def test_list_auth_command_is_the_exact_sentinel_probe():
    assert cliproxy.LIST_AUTH_COMMAND == (
        "cd '/Volumes/My Shared Files/cliproxy/auth' 2>/dev/null && { echo __AUTH_DIR__; ls -1; }; true"
    )


def test_callback_ports_pinned_to_upstream_invariants():
    assert cliproxy.CODEX_CALLBACK_PORT == 1455
    assert cliproxy.GEMINI_CALLBACK_PORT == 8085


async def test_resolve_bin_prefers_running_process(manifest, monkeypatch):
    bin_path = "/nix/store/abc123-cli-proxy-api-7-unstable-2026-06-15/bin/cli-proxy-api"
    fake, calls = _fake_run([("ps -axo command", RemoteResult(0, bin_path + "\n", ""))])
    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.resolve_bin(manifest.machines["metal"]) == bin_path
    assert calls == [cliproxy._PS_RESOLVE_COMMAND]


async def test_resolve_bin_falls_back_to_store_skipping_drv_and_go_modules(manifest, monkeypatch):
    listing = (
        "def456-cli-proxy-api-7-unstable-2026-06-15-go-modules\n"
        "ghi789-cli-proxy-api-7-unstable-2026-06-15.drv\n"
        "abc123-cli-proxy-api-7-unstable-2026-06-15\n"
    )
    fake, calls = _fake_run(
        [
            ("ps -axo command", RemoteResult(0, "\n", "")),
            ("ls -1t /nix/store", RemoteResult(0, listing, "")),
        ]
    )
    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.resolve_bin(manifest.machines["metal"]) == (
        "/nix/store/abc123-cli-proxy-api-7-unstable-2026-06-15/bin/cli-proxy-api"
    )
    assert calls == [cliproxy._PS_RESOLVE_COMMAND, cliproxy._STORE_LIST_COMMAND]


async def test_resolve_bin_not_found_raises(manifest, monkeypatch):
    listing = "def456-cli-proxy-api-7-unstable-2026-06-15-go-modules\nghi789-cli-proxy-api-7-unstable-2026-06-15.drv\n"
    fake, _calls = _fake_run(
        [
            ("ps -axo command", RemoteResult(0, "", "")),
            ("ls -1t /nix/store", RemoteResult(0, listing, "")),
        ]
    )
    monkeypatch.setattr(remote, "run", fake)
    with pytest.raises(CliproxyBinNotFound):
        await cliproxy.resolve_bin(manifest.machines["metal"])


async def test_list_auth_files_returns_names_after_sentinel(manifest, monkeypatch):
    stdout = "__AUTH_DIR__\ncodex-abc.json\nsomeone@gmail.com-proj.json\n"
    fake, calls = _fake_run([(cliproxy.LIST_AUTH_COMMAND, RemoteResult(0, stdout, ""))])
    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.list_auth_files(manifest.machines["metal"]) == [
        "codex-abc.json",
        "someone@gmail.com-proj.json",
    ]
    assert calls == [cliproxy.LIST_AUTH_COMMAND]


async def test_list_auth_files_empty_dir_is_not_an_error(manifest, monkeypatch):
    fake, _calls = _fake_run([(cliproxy.LIST_AUTH_COMMAND, RemoteResult(0, "__AUTH_DIR__\n", ""))])
    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.list_auth_files(manifest.machines["metal"]) == []


async def test_list_auth_files_missing_sentinel_raises_share_unmounted(manifest, monkeypatch):
    fake, _calls = _fake_run([(cliproxy.LIST_AUTH_COMMAND, RemoteResult(0, "", ""))])
    monkeypatch.setattr(remote, "run", fake)
    with pytest.raises(ShareUnmounted) as excinfo:
        await cliproxy.list_auth_files(manifest.machines["metal"])
    assert excinfo.value.path == cliproxy.CLIPROXY_AUTH_DIR


@pytest.mark.parametrize(
    ("names", "expected"),
    [
        (["codex-abc123.json"], True),
        (["codex-.json"], True),
        (["someone@gmail.com-projectid.json"], False),
        (["config.yaml", "codex-x.json"], True),
        (["config.yaml", "notes.txt"], False),
        (["Codex-abc.json"], False),
        ([], False),
    ],
    ids=["codex-token", "empty-stem", "gemini-not-codex", "amid-noise", "no-codex", "wrong-case", "empty"],
)
def test_has_codex(names, expected):
    assert has_codex(names) is expected


@pytest.mark.parametrize(
    ("names", "expected"),
    [
        (["someone@gmail.com-projectid.json"], True),
        (["codex-abc123.json"], False),
        (["codex-abc@example.com.json"], False),
        (["config.yaml"], False),
        (["nofile.json"], False),
        (["someone@gmail.com-proj.json", "codex-x.json", "config.yaml"], True),
        ([], False),
    ],
    ids=["gemini-token", "codex-only", "codex-with-at", "noise", "json-no-at", "mixed", "empty"],
)
def test_has_gemini(names, expected):
    assert has_gemini(names) is expected


async def test_clear_stale_login_no_listener_returns_true_without_pkill(manifest, monkeypatch):
    fake, calls = _fake_run([("lsof -nP -iTCP:1455", RemoteResult(0, "", ""))])
    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.clear_stale_login(manifest.machines["metal"], 1455) is True
    assert calls == ["lsof -nP -iTCP:1455 -sTCP:LISTEN"]


async def test_clear_stale_login_kills_then_reports_cleared(manifest, monkeypatch):
    listener = "COMMAND PID USER FD TYPE NODE NAME\ncli-proxy 999 admin 7u IPv4 TCP 127.0.0.1:1455 (LISTEN)\n"
    lsof_results = iter([RemoteResult(0, listener, ""), RemoteResult(0, "", "")])
    calls: list[str] = []

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        calls.append(command)
        if command.startswith("lsof"):
            return next(lsof_results)
        if command.startswith("pkill"):
            return RemoteResult(0, "", "")
        raise AssertionError(command)

    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.clear_stale_login(manifest.machines["metal"], 1455) is True
    assert calls == [
        "lsof -nP -iTCP:1455 -sTCP:LISTEN",
        f"pkill -f '{cliproxy.PKILL_LOGIN_PATTERN}'",
        "lsof -nP -iTCP:1455 -sTCP:LISTEN",
    ]


async def test_clear_stale_login_still_listening_returns_false(manifest, monkeypatch):
    listener = "COMMAND PID USER\nx 1 admin (LISTEN)\n"

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        if command.startswith("lsof"):
            return RemoteResult(0, listener, "")
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    assert await cliproxy.clear_stale_login(manifest.machines["metal"], 1455) is False


@pytest.mark.parametrize(
    ("argv", "should_match"),
    [
        (
            "/nix/store/x-cli-proxy-api-7/bin/cli-proxy-api "
            "--config '/Volumes/My Shared Files/cliproxy/config.yaml' --codex-login --no-browser",
            True,
        ),
        (
            "/nix/store/x-cli-proxy-api-7/bin/cli-proxy-api "
            "--config '/Volumes/My Shared Files/cliproxy/config.yaml' --login --no-browser",
            True,
        ),
        (
            "/nix/store/x-cli-proxy-api-7/bin/cli-proxy-api "
            "--config '/Volumes/My Shared Files/cliproxy/config.yaml'",
            False,
        ),
        ("pkill -f cli-proxy-api.*[-]login", False),
    ],
    ids=["codex-login", "gemini-login", "daemon-no-login", "pkill-self"],
)
def test_pkill_login_pattern(argv, should_match):
    assert bool(re.search(cliproxy.PKILL_LOGIN_PATTERN, argv)) is should_match


async def test_kickstart_runs_launchctl_as_root_with_manifest_label(manifest, monkeypatch):
    calls: list[tuple[str, str, str]] = []

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        calls.append((machine.name, machine.ssh.user, command))
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    await cliproxy.kickstart(manifest.machines["metal"])
    assert calls == [("metal", "root", "launchctl kickstart -k system/org.nixos.cliproxy")]


async def test_kickstart_swallows_remote_error_and_warns(manifest, monkeypatch):
    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        raise RemoteTimeout(command, 30.0)

    monkeypatch.setattr(remote, "run", fake)
    logged: list[str] = []
    sink = logger.add(logged.append, level="WARNING", format="{message}")
    try:
        assert await cliproxy.kickstart(manifest.machines["metal"]) is None
    finally:
        logger.remove(sink)
    assert any("kickstart failed" in m for m in logged)
