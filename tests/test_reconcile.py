"""End-to-end tests for ``yclaw secret reconcile``.

The engine's branch logic stays REAL — only the process boundaries are faked: the ``security``
subprocess (``keychain.subprocess.run``), the sops/age binaries (``sops._run``), the Tailscale HTTP
API (``reconcile.tailscale.*``), ``gh auth token`` (``reconcile._gh_token``), ``click.prompt``, and
``PATH`` lookups. ``FakeSops`` round-trips: a bundle is ``# recipient=<pub>`` + plaintext and decrypt
verifies the key's derived pubkey matches the recipient, so a bundle re-keyed under a fresh age key
fails loud exactly as real sops would. ``FakeSecurity`` models the login + dedicated keychains as
two dicts, so ``keychain`` runs for real through it.
"""

import hashlib
import json
import os
import re
import subprocess
import uuid
from itertools import takewhile
from pathlib import Path

import pytest
from click.testing import CliRunner

from yclaw import keychain, reconcile, sops
from yclaw.cli import main
from yclaw.manifest import load_manifest
from yclaw.reconcile import ReconcileError
from yclaw.secrets_manifest import load_secrets_manifest
from yclaw.sops import SopsError
from yclaw.tailscale import Device

# The keychain values a fully-provisioned fleet would hold, keyed by the durable's keychain service.
FULL_DEDICATED = {
    "yclaw-cliproxy-api-key": "cliproxy-secret-000",
    "yclaw-openai-api-key": "sk-openai-111",
    "yclaw-exa-api-key": "exa-222",
    "yclaw-honcho-api-key": "honcho-333",
    "yclaw-github-token": "ghp-444",
    "yclaw-agent-vault-master": "vault-master-555",
    "yclaw-bluebubbles-server-pass": "bb-server-666",
    "yclaw-ts-oauth-client-id": "oauth-id-777",
    "yclaw-ts-oauth-client-secret": "oauth-secret-888",
    "yclaw-metal-admin-pass": "metal-admin-999",
    "yclaw-bluebubbles-admin-pass": "bb-admin-aaa",
}

# The same values keyed by the env var they render into (BLUEBUBBLES_PASSWORD mirrors the
# bluebubbles server-pass durable), for seeding pre-existing host bundles.
VALUES_BY_VAR = {
    "CLIPROXY_API_KEY": "cliproxy-secret-000",
    "OPENAI_API_KEY": "sk-openai-111",
    "EXA_API_KEY": "exa-222",
    "HONCHO_API_KEY": "honcho-333",
    "GITHUB_TOKEN": "ghp-444",
    "AGENT_VAULT_MASTER_PASSWORD": "vault-master-555",
    "BLUEBUBBLES_PASSWORD": "bb-server-666",
}

LOGIN = {"yclaw-keychain-password": "unlock-pw"}


def _fake_pub(content: str) -> str:
    return "age1" + hashlib.sha256(content.encode()).hexdigest()[:52]


def _fake_extract(plaintext: str, sops_path: str) -> str:
    """Navigate the rendered plaintext YAML to the ``["top"]["leaf"]`` sops path, matching what
    real ``sops --extract`` returns: a scalar leaf verbatim, an envblock as its ``VAR=value`` lines."""
    top_key, leaf_key = re.findall(r'\["([^"]+)"\]', sops_path)
    lines = plaintext.splitlines()
    in_top = False
    for i, line in enumerate(lines):
        if not line.startswith(" "):
            in_top = line.rstrip().removesuffix(":") == top_key
            continue
        if not in_top or line.startswith("    "):
            continue
        leaf, _, val = line[2:].partition(": ")
        if leaf != leaf_key:
            continue
        if val != "|":
            return json.loads(val) + "\n"
        block = list(takewhile(lambda follow: follow.startswith("    "), lines[i + 1 :]))
        return "".join(f"{entry[4:]}\n" for entry in block)
    raise AssertionError(f"{sops_path} not found in plaintext")


class FakeSops:
    """Round-trippable stand-in for the sops/age binaries at the ``sops._run`` seam."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def __call__(self, argv, *, env=None):
        self.calls.append(list(argv))
        tool = argv[0]
        if tool == "age-keygen":
            if argv[1] == "-o":
                Path(argv[2]).write_text(f"AGE-SECRET-KEY-FAKE-{uuid.uuid4().hex}\n")
                return ""
            if argv[1] == "-y":
                return _fake_pub(Path(argv[2]).read_text().strip()) + "\n"
            raise AssertionError(f"unexpected age-keygen argv {argv}")
        if tool == "sops":
            path = Path(argv[-1])
            if "--encrypt" in argv:
                pub = argv[argv.index("--age") + 1]
                return f"# recipient={pub}\n" + path.read_text()
            if "--decrypt" in argv:
                cipher = path.read_text()
                head, _, body = cipher.partition("\n")
                recipient = head.removeprefix("# recipient=")
                key_content = Path(env["SOPS_AGE_KEY_FILE"]).read_text().strip()
                if _fake_pub(key_content) != recipient:
                    raise SopsError("sops --decrypt exited 1: no matching age recipient found")
                if "--extract" in argv:
                    return _fake_extract(body, argv[argv.index("--extract") + 1])
                return body
        raise AssertionError(f"unexpected sops argv {argv}")


class FakeSecurity:
    """Models the login + dedicated keychains as two dicts, honoring ``check``."""

    def __init__(self, *, dedicated, login, keychain_path) -> None:
        self.dedicated = dict(dedicated)
        self.login = dict(login)
        self.keychain_path = str(keychain_path)
        self.calls: list[list[str]] = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        check = kwargs.get("check", False)
        sub = argv[1]
        store = self.dedicated if self.keychain_path in argv else self.login

        def done(rc, out=""):
            if check and rc != 0:
                raise subprocess.CalledProcessError(rc, argv, output=out)
            return subprocess.CompletedProcess(argv, rc, stdout=out, stderr="")

        if sub == "find-generic-password":
            svc = argv[argv.index("-s") + 1]
            return done(0, store[svc] + "\n") if svc in store else done(44, "")
        if sub == "add-generic-password":
            svc = argv[argv.index("-s") + 1]
            store[svc] = argv[argv.index("-w") + 1]
            return done(0)
        if sub in ("unlock-keychain", "lock-keychain", "set-keychain-settings", "create-keychain"):
            return done(0)
        raise AssertionError(f"unexpected security subcommand {sub}")

    def writes(self):
        """Every write to the DEDICATED keychain, as ``(service, value)`` pairs."""
        return [
            (a[a.index("-s") + 1], a[a.index("-w") + 1])
            for a in self.calls
            if a[1] == "add-generic-password" and self.keychain_path in a
        ]


class ReconcileEnv:
    def __init__(self, home, sec, fake_sops, sm) -> None:
        self.home = home
        self.sec = sec
        self.sops = fake_sops
        self.sm = sm
        self.state_dir = home / ".yclaw" / "state"
        self.replaces: list[tuple[str, str]] = []
        self.mints: list[str] = []
        self.oauth_calls: list[tuple[str, str]] = []
        self.token_hex_calls: list[int] = []
        self.prompts: list[str] = []
        self.devices: list[Device] = []
        self.gh_token = None
        self.token_hex_value = "GENERATED-HEX-TOKEN"

    def seed_host(self, host, values_by_var):
        host_dir = self.state_dir / "hosts" / host
        host_dir.mkdir(parents=True)
        host_dir.chmod(0o700)
        key = host_dir / "key.txt"
        sops.keygen(key)
        bundle = host_dir / "secrets.sops.yaml"
        plaintext = reconcile._render_plaintext(self.sm, host, values_by_var)
        bundle.write_text(sops.encrypt(plaintext, sops.pubkey(key)))
        return key, bundle

    def seed_rules(self, hosts):
        recipients = [(h, sops.pubkey(self.state_dir / "hosts" / h / "key.txt")) for h in hosts]
        (self.state_dir / "sops.yaml").write_text(reconcile._render_rules(recipients))

    def bundle_replaces(self):
        return [dst for _, dst in self.replaces if dst.endswith("secrets.sops.yaml")]

    def run(self, *args):
        return CliRunner().invoke(main, ["secret", "reconcile", *args])


@pytest.fixture
def env(tmp_path, monkeypatch):
    kc_path = tmp_path / "yclaw.keychain-db"
    kc_path.write_text("")  # keychain exists → ensure() no-ops; require_aqua_session probes it
    monkeypatch.setattr(keychain, "KEYCHAIN_PATH", kc_path)

    fake_sops = FakeSops()
    monkeypatch.setattr(sops, "_run", fake_sops)
    sec = FakeSecurity(dedicated=FULL_DEDICATED, login=LOGIN, keychain_path=kc_path)
    monkeypatch.setattr(keychain.subprocess, "run", sec)
    monkeypatch.setattr(reconcile.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(reconcile.shutil, "which", lambda tool: f"/usr/bin/{tool}")

    e = ReconcileEnv(tmp_path, sec, fake_sops, load_secrets_manifest())

    async def fake_oauth(cid, csec, *, client=None):
        e.oauth_calls.append((cid, csec))
        return "TOKEN"

    async def fake_list(token, *, client=None):
        return tuple(e.devices)

    async def fake_mint(token, host, *, client=None):
        e.mints.append(host)
        return f"tskey-{host}-minted"

    def fake_token_hex(n):
        e.token_hex_calls.append(n)
        return e.token_hex_value

    def fake_prompt(alias, hide_input=False):
        e.prompts.append(alias)
        return f"prompted-{alias}"

    real_replace = os.replace

    def replace_spy(src, dst):
        e.replaces.append((str(src), str(dst)))
        return real_replace(src, dst)

    monkeypatch.setattr(reconcile.tailscale, "oauth_token", fake_oauth)
    monkeypatch.setattr(reconcile.tailscale, "list_devices", fake_list)
    monkeypatch.setattr(reconcile.tailscale, "mint_authkey", fake_mint)
    monkeypatch.setattr(reconcile, "_gh_token", lambda: e.gh_token)
    monkeypatch.setattr(reconcile.secrets, "token_hex", fake_token_hex)
    monkeypatch.setattr(reconcile.click, "prompt", fake_prompt)
    monkeypatch.setattr(reconcile.os, "replace", replace_spy)
    return e


# --- 1. Idempotency / anti-churn -------------------------------------------------------------


def test_reconcile_idempotent_touches_nothing(env):
    key, bundle = env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-live"})
    env.seed_rules(["metal"])
    env.devices = [Device("metal", "metal", ("tag:metal",))]  # live tailnet member
    before = bundle.read_bytes()

    result = env.run("metal")

    assert result.exit_code == 0, result.output
    assert env.replaces == []  # no bundle or sops.yaml rewrite
    assert env.sec.writes() == []  # no keychain write
    assert env.mints == []  # no authkey mint
    assert bundle.read_bytes() == before  # byte-identical
    assert "bundle unchanged" in result.output


# --- 2. Fresh host imports the shared cliproxy bearer from a peer ------------------------------


def test_reconcile_fresh_vault_peer_imports_cliproxy(env):
    _, metal_bundle = env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-live"})
    env.seed_rules(["metal"])
    del env.sec.dedicated["yclaw-cliproxy-api-key"]  # only source is metal's bundle
    env.devices = [Device("metal", "metal", ("tag:metal",))]
    metal_before = metal_bundle.read_bytes()

    result = env.run("vault")

    assert result.exit_code == 0, result.output
    vault_dir = env.state_dir / "hosts" / "vault"
    vault_key, vault_bundle = vault_dir / "key.txt", vault_dir / "secrets.sops.yaml"
    assert vault_key.exists()  # age key minted
    assert env.bundle_replaces() == [str(vault_bundle)]  # exactly one new bundle, metal untouched
    assert metal_bundle.read_bytes() == metal_before
    assert env.mints == ["vault"]  # one authkey mint
    imported = sops.extract(vault_bundle, vault_key, '["cliproxy"]["api-key"]').rstrip("\n")
    assert imported == "cliproxy-secret-000"  # peer import, equals metal's value
    assert env.token_hex_calls == []  # the fresh-generate branch did NOT fire


# --- 3. Peer-import fallback is persisted back to the keychain --------------------------------


def test_reconcile_peer_import_stored_to_keychain(env):
    env.seed_host("vault", {**VALUES_BY_VAR, "TS_AUTHKEY_VAULT": "tskey-vault-live"})
    env.seed_rules(["vault"])
    del env.sec.dedicated["yclaw-cliproxy-api-key"]
    env.devices = [Device("vault", "vault", ("tag:vault",))]

    result = env.run("metal")

    assert result.exit_code == 0, result.output
    assert ("yclaw-cliproxy-api-key", "cliproxy-secret-000") in env.sec.writes()
    assert env.token_hex_calls == []  # value came from the peer bundle, not a fresh generate


def test_reconcile_peer_imports_from_envblock_leaf(env):
    # A lost LLM key is recovered from a peer's vault/static-keys ENVBLOCK (not a scalar leaf),
    # exercising the VAR=value parse — the recovered value matches, so nothing else churns.
    env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-live"})
    env.seed_rules(["metal"])
    del env.sec.dedicated["yclaw-openai-api-key"]
    env.devices = [Device("metal", "metal", ("tag:metal",))]

    result = env.run("metal")

    assert result.exit_code == 0, result.output
    assert ("yclaw-openai-api-key", "sk-openai-111") in env.sec.writes()
    assert env.prompts == []  # recovered from the envblock, never prompted


# --- 4. Generate (random) / prompt (LLM key) when absent everywhere ---------------------------


@pytest.mark.parametrize(
    ("removed_service", "kind", "expected"),
    [
        ("yclaw-cliproxy-api-key", "generate", "GENERATED-HEX-TOKEN"),
        ("yclaw-openai-api-key", "prompt", "prompted-openai-api-key"),
    ],
    ids=["generate-hex-token", "prompt-llm-key"],
)
def test_reconcile_acquire_generate_or_prompt(env, removed_service, kind, expected):
    del env.sec.dedicated[removed_service]  # absent from keychain, and no bundle exists anywhere
    env.devices = [Device("vault", "vault", ("tag:vault",))]

    result = env.run("vault")

    assert result.exit_code == 0, result.output
    assert (removed_service, expected) in env.sec.writes()  # persisted back
    if kind == "generate":
        assert len(env.token_hex_calls) == 1
        assert env.prompts == []
    else:
        assert env.prompts == ["openai-api-key"]
        assert env.token_hex_calls == []


# --- 5. --rotate-authkey forces a mint even for a live member with a prior bundle -------------


def test_reconcile_rotate_authkey_forces_mint(env):
    key, bundle = env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-old"})
    env.seed_rules(["metal"])
    env.devices = [Device("metal", "metal", ("tag:metal",))]  # live member — would normally reuse

    result = env.run("metal", "--rotate-authkey")

    assert result.exit_code == 0, result.output
    assert env.mints == ["metal"]  # forced mint
    rendered = sops.extract(bundle, key, '["tailscale"]["authkey"]').rstrip("\n")
    assert rendered == "tskey-metal-minted"  # bundle now carries the fresh key
    assert env.bundle_replaces() == [str(bundle)]


# --- 6. --rotate owner-coverage validation (runs before any keychain contact) ----------------


@pytest.mark.parametrize(
    ("args", "missing"),
    [
        (["hermes", "--rotate", "openai-api-key"], "missing metal, vault"),
        (["hermes", "metal", "--rotate", "cliproxy-api-key"], "missing vault"),
    ],
    ids=["single-owner-target", "two-of-three-owners"],
)
def test_reconcile_rotate_requires_all_owners(env, args, missing):
    result = env.run(*args)

    assert result.exit_code == 1
    assert "must cover every owner" in result.output
    assert missing in result.output
    assert env.sec.calls == []  # rejected before any keychain / ensure contact


def test_validate_rotations_accepts_full_owner_coverage(env):
    durs = reconcile.durables(load_manifest())
    # Untargeted (all owners) and explicitly-all-owners both pass.
    reconcile._validate_rotations(durs, frozenset({"cliproxy-api-key"}), ("hermes", "metal", "vault"), env.sm)
    reconcile._validate_rotations(durs, frozenset({"openai-api-key"}), ("metal", "vault"), env.sm)
    # A keychain-only durable (var=None) renders into no bundle, so owner coverage never applies.
    reconcile._validate_rotations(durs, frozenset({"metal-admin-pass"}), ("hermes",), env.sm)


def test_validate_rotations_rejects_partial_coverage(env):
    durs = reconcile.durables(load_manifest())
    with pytest.raises(ReconcileError, match="must cover every owner of OPENAI_API_KEY"):
        reconcile._validate_rotations(durs, frozenset({"openai-api-key"}), ("hermes",), env.sm)


# --- 7. --dry-run mutates nothing -------------------------------------------------------------


def test_reconcile_dry_run_mutates_nothing(env):
    del env.sec.dedicated["yclaw-cliproxy-api-key"]  # a real run would generate + write this
    env.devices = [Device("vault", "vault", ("tag:vault",))]

    result = env.run("vault", "--dry-run")

    assert result.exit_code == 0, result.output
    assert env.replaces == []  # no bundle / rules write
    assert env.sec.writes() == []  # no keychain create or write
    assert env.mints == []  # no authkey mint
    assert env.prompts == []
    assert env.token_hex_calls == []
    assert not (env.state_dir / "hosts" / "vault").exists()  # no age key minted
    assert "would" in result.output


def test_reconcile_dry_run_requires_existing_keychain(env):
    keychain.KEYCHAIN_PATH.unlink()  # no keychain to plan against
    result = env.run("vault", "--dry-run")

    assert result.exit_code == 1
    assert "run without --dry-run to create it" in result.output


# --- 9. Atomic bundle + rules writes ----------------------------------------------------------


def test_reconcile_writes_bundle_and_rules_atomically(env):
    del env.sec.dedicated["yclaw-cliproxy-api-key"]
    env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-live"})
    env.seed_rules(["metal"])
    env.devices = [Device("metal", "metal", ("tag:metal",))]

    result = env.run("vault")

    assert result.exit_code == 0, result.output
    dsts = {dst for _, dst in env.replaces}
    assert str(env.state_dir / "hosts" / "vault" / "secrets.sops.yaml") in dsts
    assert str(env.state_dir / "sops.yaml") in dsts  # recipient set changed → rewritten
    for src, dst in env.replaces:
        assert Path(src).parent == Path(dst).parent  # same-dir temp → os.replace is atomic


# --- 10. Orphaned bundle (key.txt lost) fails loud, never silently overwrites -----------------


def test_reconcile_orphaned_bundle_fails_loud(env):
    key, bundle = env.seed_host("metal", {**VALUES_BY_VAR, "TS_AUTHKEY_METAL": "tskey-metal-live"})
    env.seed_rules(["metal"])
    before = bundle.read_bytes()
    key.unlink()  # age key lost — the ciphertext is now orphaned
    env.devices = [Device("metal", "metal", ("tag:metal",))]

    result = env.run("metal")

    assert result.exit_code == 1
    assert "sops" in result.output.lower()
    assert bundle.read_bytes() == before  # never silently overwritten


# --- Bonus: fresh hermes exercises the envblock render path -----------------------------------


def test_reconcile_fresh_hermes_renders_envblock(env):
    env.devices = [Device("hermes", "hermes", ("tag:hermes",))]

    result = env.run("hermes")

    assert result.exit_code == 0, result.output
    host_dir = env.state_dir / "hosts" / "hermes"
    body = sops.extract(host_dir / "secrets.sops.yaml", host_dir / "key.txt", '["hermes"]["env"]')
    assert "BLUEBUBBLES_PASSWORD=bb-server-666" in body
    assert "CLIPROXY_API_KEY=cliproxy-secret-000" in body
    assert env.mints == ["hermes"]
