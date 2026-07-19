import subprocess

import pytest
from click.testing import CliRunner

from yclaw import keychain, secret
from yclaw.cli import main
from yclaw.keychain import KeychainError


def test_secret_list_maps_aliases_to_services():
    result = CliRunner().invoke(main, ["secret", "list"])
    assert result.exit_code == 0
    assert "login-unlock" not in result.output  # unlock key lives in the LOGIN keychain — not CLI-readable
    assert "yclaw-keychain-password" not in result.output
    assert "agent-vault-master" in result.output
    assert "yclaw-agent-vault-master" in result.output
    assert "metal-admin-pass" in result.output
    assert "yclaw-metal-admin-pass" in result.output
    assert "bluebubbles-admin-pass" in result.output


def test_secret_read_writes_value_to_stdout_only(monkeypatch):
    seen = {}

    def fake_read(service):
        seen["service"] = service
        return "sekret-value"

    monkeypatch.setattr(keychain, "read", fake_read)
    result = CliRunner().invoke(main, ["secret", "read", "metal-admin-pass"])
    assert result.exit_code == 0
    assert seen == {"service": "yclaw-metal-admin-pass"}
    assert result.output == "sekret-value\n"
    assert result.stderr == ""


def test_secret_read_unknown_alias_is_usage_error():
    result = CliRunner().invoke(main, ["secret", "read", "nope"])
    assert result.exit_code == 2
    assert "unknown alias 'nope'" in result.output


def test_secret_read_missing_keychain_item_fails_cleanly(monkeypatch):
    def fake_read(service):
        raise KeychainError("keychain item not found")

    monkeypatch.setattr(keychain, "read", fake_read)
    result = CliRunner().invoke(main, ["secret", "read", "agent-vault-master"])
    assert result.exit_code == 1
    assert "keychain item not found" in result.output


def test_secret_sops_decrypts_with_host_key(monkeypatch, tmp_path):
    host_dir = tmp_path / ".yclaw" / "state" / "hosts" / "metal"
    host_dir.mkdir(parents=True)
    key = host_dir / "key.txt"
    bundle = host_dir / "secrets.sops.yaml"
    key.write_text("stub-age-key\n")
    bundle.write_text("enc: data\n")
    monkeypatch.setattr(secret.Path, "home", lambda: tmp_path)
    seen = {}

    def fake_run(argv, env=None, **kwargs):
        seen["argv"] = argv
        seen["age_key"] = env["SOPS_AGE_KEY_FILE"]
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(secret.subprocess, "run", fake_run)
    result = CliRunner().invoke(main, ["secret", "sops", "metal"])
    assert result.exit_code == 0
    assert seen["argv"] == ["sops", "-d", str(bundle)]
    assert seen["age_key"] == str(key)


def test_secret_sops_missing_bundle_says_bootstrap(monkeypatch, tmp_path):
    monkeypatch.setattr(secret.Path, "home", lambda: tmp_path)
    result = CliRunner().invoke(main, ["secret", "sops", "metal"])
    assert result.exit_code == 1
    assert "run `just bootstrap` first" in result.output


def test_secret_help():
    result = CliRunner().invoke(main, ["secret", "--help"])
    assert result.exit_code == 0
    assert "Read keychain secrets" in result.output


@pytest.mark.parametrize(("present", "exit_code"), [(True, 0), (False, 1)], ids=["present", "absent"])
def test_secret_has_exit_code_reflects_presence(monkeypatch, present, exit_code):
    seen = {}

    def fake_has(service):
        seen["service"] = service
        return present

    monkeypatch.setattr(keychain, "has", fake_has)
    result = CliRunner().invoke(main, ["secret", "has", "cliproxy-api-key"])
    assert result.exit_code == exit_code
    assert seen == {"service": "yclaw-cliproxy-api-key"}


def test_secret_set_reads_value_from_stdin(monkeypatch):
    seen = {}
    monkeypatch.setattr(keychain, "write", lambda service, value: seen.update(service=service, value=value))
    result = CliRunner().invoke(main, ["secret", "set", "cliproxy-api-key", "--value", "-"], input="hunter2\n")
    assert result.exit_code == 0
    assert seen == {"service": "yclaw-cliproxy-api-key", "value": "hunter2"}


def test_secret_set_writes_literal_value(monkeypatch):
    seen = {}
    monkeypatch.setattr(keychain, "write", lambda service, value: seen.update(service=service, value=value))
    result = CliRunner().invoke(main, ["secret", "set", "agent-vault-master", "--value", "vvv"])
    assert result.exit_code == 0
    assert seen == {"service": "yclaw-agent-vault-master", "value": "vvv"}


def test_secret_set_rejects_empty_value(monkeypatch):
    monkeypatch.setattr(keychain, "write", lambda *a: pytest.fail("write must not be called for an empty value"))
    result = CliRunner().invoke(main, ["secret", "set", "agent-vault-master", "--value", "-"], input="\n")
    assert result.exit_code == 2
    assert "empty secret value" in result.output
