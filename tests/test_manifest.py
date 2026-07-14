import os
from pathlib import Path

import pytest

from yclaw.manifest import (
    HttpHealth,
    LaunchdRef,
    ManifestError,
    Service,
    TcpHealth,
    _parse_health,
    _parse_service,
)


def test_hermes_ssh_user_is_root(manifest):
    assert manifest.machines["hermes"].ssh.user == "root"
    assert manifest.machines["hermes"].ssh.transport == "tailscale"


def test_rapid_mlx_launchd_label(manifest):
    rapid_mlx = manifest.machines["metal"].services["rapid-mlx"]
    assert rapid_mlx.launchd == LaunchdRef(domain="system", label="org.nixos.rapid-mlx")


def test_metal_share_list(manifest):
    assert manifest.machines["metal"].shares == (
        "metalsecrets",
        "agentvault",
        "cliproxy",
        "repo",
    )


def test_rapid_mlx_log_paths(manifest):
    assert manifest.machines["metal"].services["rapid-mlx"].logs == (
        "/Users/admin/Library/Logs/rapid-mlx/rapid-mlx.log",
        "/Users/admin/Library/Logs/rapid-mlx/rapid-mlx.error.log",
    )


def test_rapid_mlx_http_health(manifest):
    assert manifest.machines["metal"].services["rapid-mlx"].health == HttpHealth(url="http://metal:8000/v1/models")


def test_mlx_audio_tcp_health(manifest):
    assert manifest.machines["metal"].services["mlx-audio"].health == TcpHealth(host="metal", port=8765)


def test_hermes_systemd_service_has_no_launchd(manifest):
    svc = manifest.machines["hermes"].services["hermes-agent"]
    assert svc.systemd == "hermes-agent.service"
    assert svc.launchd is None
    assert svc.health is None


def test_host_has_null_ssh_and_shares(manifest):
    host = manifest.machines["host"]
    assert host.ssh is None
    assert host.tart_vm is None
    assert host.shares is None
    assert host.admin_pass_keychain is None


def test_host_tailnet_name_parsed(manifest):
    assert manifest.machines["host"].tailnet_name == "yasyf-home"


def test_tailnet_name_absent_is_none(manifest):
    assert manifest.machines["metal"].tailnet_name is None


def test_bluebubbles_password_fields(manifest):
    svc = manifest.machines["bluebubbles"].services["bluebubbles"]
    assert svc.password_keychain == "yclaw-bluebubbles-server-pass"
    assert svc.password_query_param == "password"
    assert svc.health == HttpHealth(url="https://bluebubbles/api/v1/ping")


def test_oneshot_flag(manifest):
    assert manifest.machines["metal"].services["agent-vault-provision"].oneshot is True
    assert manifest.machines["metal"].services["rapid-mlx"].oneshot is False


def test_pf_refresh_daemons_are_resident(manifest):
    # Resident KeepAlive loops, not StartInterval oneshots: probes render them healthy via
    # `state == "running"`, which requires oneshot False (a oneshot expects a terminal exit 0).
    for machine, name in (("metal", "metal-pf-refresh"), ("bluebubbles", "bb-pf-refresh")):
        assert manifest.machines[machine].services[name].oneshot is False


def test_keychain_login_unlock(manifest):
    assert manifest.host_paths.keychain.login_unlock == "yclaw-keychain-password"
    assert manifest.host_paths.keychain.agent_vault_master == "yclaw-agent-vault-master"


def test_debloat_lists(manifest):
    assert manifest.debloat["metal"].system[0] == "com.apple.metadata.mds"
    assert "com.apple.assistantd" in manifest.debloat["metal"].gui


def test_missing_key_raises_keyerror():
    with pytest.raises(KeyError):
        _parse_service("broken", {"launchd": {"domain": "system"}})


def test_unknown_health_kind_raises_manifest_error():
    with pytest.raises(ManifestError, match="unknown health kind"):
        _parse_health({"kind": "grpc", "url": "x"})


def test_service_is_frozen(manifest):
    svc = manifest.machines["metal"].services["rapid-mlx"]
    assert isinstance(svc, Service)
    with pytest.raises((AttributeError, TypeError)):
        svc.port = 1  # type: ignore[misc]


def test_launchd_ref_target_and_plist_path(manifest):
    rapid_mlx = manifest.machines["metal"].services["rapid-mlx"]
    assert rapid_mlx.launchd.target == "system/org.nixos.rapid-mlx"
    assert rapid_mlx.launchd.bootstrap_domain == "system"
    assert rapid_mlx.launchd.plist_path == "/Library/LaunchDaemons/org.nixos.rapid-mlx.plist"


def test_launchd_ref_gui_domain_target_and_plist_path(manifest):
    # The host's tart-* supervisors are gui-domain LaunchAgents, not system LaunchDaemons: the target
    # carries the numeric uid and the plist lives under the login user's ~/Library/LaunchAgents. The
    # bootstrap domain is bare `gui/<uid>` (no label) — launchctl rejects a bare `gui` there.
    ref = manifest.machines["host"].services["tart-metal"].launchd
    assert ref == LaunchdRef(domain="gui", label="com.yclaw.tart-metal")
    assert ref.target == f"gui/{os.getuid()}/com.yclaw.tart-metal"
    assert ref.bootstrap_domain == f"gui/{os.getuid()}"
    assert ref.plist_path == str(Path.home() / "Library/LaunchAgents" / "com.yclaw.tart-metal.plist")
