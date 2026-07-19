import json

import pytest

from yclaw.secrets_manifest import (
    EnvBlockSecret,
    PerHostSecret,
    ScalarSecret,
    SecretsManifestError,
    load_secrets_manifest,
)


def test_catalog_models_each_kind_from_the_real_manifest():
    sm = load_secrets_manifest()
    assert sm.catalog["cliproxy/api-key"] == ScalarSecret(var="CLIPROXY_API_KEY")
    assert sm.catalog["tailscale/authkey"] == PerHostSecret(var="TS_AUTHKEY")
    assert sm.catalog["vault/master-password"] == EnvBlockSecret(vars=("AGENT_VAULT_MASTER_PASSWORD",))
    assert sm.catalog["vault/static-keys"] == EnvBlockSecret(
        vars=("OPENAI_API_KEY", "EXA_API_KEY", "HONCHO_API_KEY", "GITHUB_TOKEN")
    )
    assert sm.catalog["hermes/env"] == EnvBlockSecret(vars=("BLUEBUBBLES_PASSWORD", "CLIPROXY_API_KEY"))


@pytest.mark.parametrize(
    ("key", "owners"),
    [
        ("cliproxy/api-key", ("metal", "vault")),
        ("tailscale/authkey", ("hermes", "metal", "vault")),
        ("hermes/env", ("hermes",)),
        ("vault/master-password", ("metal", "vault")),
    ],
    ids=["cliproxy", "authkey", "hermes-env", "vault-master"],
)
def test_owners_returns_the_owning_hosts_in_manifest_order(key, owners):
    assert load_secrets_manifest().owners(key) == owners


def test_bluebubbles_owns_no_secrets():
    assert load_secrets_manifest().hosts["bluebubbles"].secrets == ()


def test_unknown_catalog_kind_raises(tmp_path):
    path = tmp_path / "secrets-manifest.json"
    path.write_text(
        json.dumps({"hosts": {"h": {"secrets": ["a/b"]}}, "catalog": {"a/b": {"kind": "blob", "var": "X"}}})
    )
    with pytest.raises(SecretsManifestError, match="unknown catalog kind for 'a/b'"):
        load_secrets_manifest(path)


def test_missing_required_field_crashes_loud(tmp_path):
    path = tmp_path / "secrets-manifest.json"
    path.write_text(json.dumps({"hosts": {"h": {"secrets": ["a/b"]}}, "catalog": {"a/b": {"kind": "scalar"}}}))
    with pytest.raises(KeyError):
        load_secrets_manifest(path)
