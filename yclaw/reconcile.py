"""``yclaw secret reconcile`` — converge the keychain and per-host sops bundles onto the secrets
manifest. The keychain is the source of truth for durable values: reuse what is there, acquire
only what is missing, persist it back. Bundles are rendered projections, rewritten only when the
decrypted plaintext differs — sops re-MACs identical input, so ciphertext never compares equal."""

import json
import os
import secrets
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import click

from . import dispatch, keychain, output, sops, tailscale
from .keychain import KeychainError
from .manifest import Manifest, load_manifest
from .secrets_manifest import (
    EnvBlockSecret,
    PerHostSecret,
    ScalarSecret,
    SecretsManifest,
    load_secrets_manifest,
)
from .sops import SopsError
from .tailscale import Device, TailscaleError

AUTHKEY_KEY = "tailscale/authkey"
REQUIRED_TOOLS = ("sops", "age-keygen", "security", "gh")


class ReconcileError(Exception):
    """Reconcile cannot proceed: a missing tool, an unresolvable secret, or an unusable tailnet view."""


@dataclass(frozen=True, slots=True)
class Durable:
    """A keychain-backed secret reconcile manages: its keychain service, how it is acquired when
    missing, and — for shared catalog vars — the env var it renders into (``var=None`` items live
    only in the keychain, never in a bundle)."""

    service: str
    var: str | None
    fresh: str  # "prompt" | "password" | "hex-token" — the last-resort acquisition
    peer_import: bool = False  # may recover the live value from an existing host bundle
    pre_gh: bool = False  # consult `gh auth token` before the keychain

    @property
    def alias(self) -> str:
        return self.service.removeprefix("yclaw-")


@dataclass(frozen=True, slots=True)
class Decision:
    alias: str
    source: str
    stored: bool


@dataclass(frozen=True, slots=True)
class HostPlan:
    host: str
    changed: bool
    notes: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class TailnetView:
    token: str | None
    devices: tuple[Device, ...] | None
    error: str | None


@dataclass(frozen=True, slots=True)
class ReconcileReport:
    decisions: tuple[Decision, ...]
    plans: tuple[HostPlan, ...]
    rules: str
    dry_run: bool


def durables(manifest: Manifest) -> tuple[Durable, ...]:
    """Every durable keychain-backed secret reconcile manages. Services already named in
    ``machines.json`` come from the loaded manifest; items newly keychain-backed here (the cliproxy
    bearer, the LLM static keys) get ``yclaw-<kebab>`` names minted in this table — the Nix-read
    secrets-manifest schema stays untouched."""
    kc = manifest.host_paths.keychain
    bluebubbles = manifest.machines["bluebubbles"].services["bluebubbles"]
    entries = [
        Durable(service="yclaw-cliproxy-api-key", var="CLIPROXY_API_KEY", fresh="hex-token", peer_import=True),
        Durable(service="yclaw-openai-api-key", var="OPENAI_API_KEY", fresh="prompt", peer_import=True),
        Durable(service="yclaw-exa-api-key", var="EXA_API_KEY", fresh="prompt", peer_import=True),
        Durable(service="yclaw-honcho-api-key", var="HONCHO_API_KEY", fresh="prompt", peer_import=True),
        Durable(service="yclaw-github-token", var="GITHUB_TOKEN", fresh="prompt", pre_gh=True),
        Durable(service=kc.agent_vault_master, var="AGENT_VAULT_MASTER_PASSWORD", fresh="password"),
        Durable(service=bluebubbles.password_keychain, var="BLUEBUBBLES_PASSWORD", fresh="password"),
        Durable(service=kc.ts_oauth_client_id, var=None, fresh="prompt"),
        Durable(service=kc.ts_oauth_client_secret, var=None, fresh="prompt"),
    ]
    entries.extend(
        Durable(service=machine.admin_pass_keychain, var=None, fresh="password")
        for machine in manifest.machines.values()
        if machine.admin_pass_keychain is not None
    )
    return tuple(entries)


def _require_tools() -> None:
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing:
        raise ReconcileError(f"required tools not on PATH: {', '.join(missing)}")


def _gh_token() -> str | None:
    completed = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
    token = completed.stdout.strip()
    if completed.returncode != 0 or not token:
        return None
    return token


def _nonempty(path: Path) -> bool:
    return path.exists() and path.stat().st_size > 0


def _atomic_write(path: Path, content: str) -> None:
    """Write via a same-directory temp file + ``os.replace`` so a torn write never leaves a
    corrupt bundle behind (the next run would crash decrypting it)."""
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as tmp:
        tmp.write(content)
    os.replace(tmp.name, path)


def _host_vars(sm: SecretsManifest, host: str) -> tuple[str, ...]:
    out: list[str] = []
    for key in sm.hosts[host].secrets:
        entry = sm.catalog[key]
        if isinstance(entry, ScalarSecret):
            out.append(entry.var)
        elif isinstance(entry, EnvBlockSecret):
            out.extend(entry.vars)
    return tuple(dict.fromkeys(out))


def _validate_rotations(
    durs: tuple[Durable, ...], rotations: frozenset[str], targets: tuple[str, ...], sm: SecretsManifest
) -> None:
    """A ``--rotate`` of a rendered var must cover every owner host: a partial rotate would leave
    the uncovered owners' bundles carrying the old value — a real cross-host desync."""
    by_alias = {durable.alias: durable for durable in durs}
    for alias in sorted(rotations):
        var = by_alias[alias].var
        if var is None:  # keychain-only durables (admin passes, OAuth client) enter no bundle
            continue
        owners = [host for host in sm.hosts if var in _host_vars(sm, host)]
        uncovered = [host for host in owners if host not in targets]
        if uncovered:
            raise ReconcileError(
                f"--rotate {alias} must cover every owner of {var} — missing {', '.join(uncovered)}; "
                "target them too or run without host arguments"
            )


def _peer_value(durable: Durable, sm: SecretsManifest, state_dir: Path) -> tuple[str, str] | None:
    """The live value of ``durable.var`` recovered from an existing host bundle, with the host it
    came from. Load-bearing on the first reconcile: the live cliproxy bearer exists only in metal's
    bundle, and a fresh mint would desync every client already presenting it."""
    for key, entry in sm.catalog.items():
        if isinstance(entry, ScalarSecret) and entry.var == durable.var:
            block_var = None
        elif isinstance(entry, EnvBlockSecret) and durable.var in entry.vars:
            block_var = durable.var
        else:
            continue
        top, leaf = key.split("/", 1)
        for host in sm.owners(key):
            key_file = state_dir / "hosts" / host / "key.txt"
            bundle = state_dir / "hosts" / host / "secrets.sops.yaml"
            if not (_nonempty(key_file) and _nonempty(bundle)):
                continue
            try:
                raw = sops.extract(bundle, key_file, f'["{top}"]["{leaf}"]')
            except SopsError:
                continue  # a stale bundle without the leaf — keep probing the other owners
            if block_var is None:
                value = raw.rstrip("\n")
                if value:
                    return value, host
                continue
            for line in raw.splitlines():
                name, sep, value = line.partition("=")
                if sep and name == block_var and value:
                    return value, host
    return None


def _acquire_one(
    durable: Durable, rotated: bool, sm: SecretsManifest, state_dir: Path, dry_run: bool
) -> tuple[str | None, Decision]:
    current = keychain.read(durable.service) if keychain.has(durable.service) else None
    if durable.pre_gh:
        live = _gh_token()
        if live is not None:
            stored = live != current
            if stored and not dry_run:
                keychain.write(durable.service, live)
            return live, Decision(durable.alias, "gh auth token", stored)
    if current is not None and not rotated:
        return current, Decision(durable.alias, "keychain", False)
    if durable.peer_import and not rotated:
        found = _peer_value(durable, sm, state_dir)
        if found is not None:
            value, peer = found
            if not dry_run:
                keychain.write(durable.service, value)
            return value, Decision(durable.alias, f"bundle:{peer}", True)
    if dry_run:
        verb = "prompt" if durable.fresh == "prompt" else "generate"
        return None, Decision(durable.alias, f"MISSING — would {verb}", False)
    if durable.fresh == "prompt":
        value = click.prompt(durable.alias, hide_input=True)
        if not value:
            raise ReconcileError(f"{durable.alias} is required")
        source = "prompted"
    elif durable.fresh == "password":
        value = keychain.mint_password()
        source = "generated"
    elif durable.fresh == "hex-token":
        value = secrets.token_hex(32)
        source = "generated"
    else:
        raise ReconcileError(f"unknown fresh policy {durable.fresh!r} for {durable.alias}")
    keychain.write(durable.service, value)
    return value, Decision(durable.alias, source, True)


def _acquire_shared(
    durs: tuple[Durable, ...],
    needed_vars: tuple[str, ...],
    rotations: frozenset[str],
    sm: SecretsManifest,
    state_dir: Path,
    dry_run: bool,
) -> tuple[dict[str, str], tuple[Decision, ...]]:
    known_vars = {durable.var for durable in durs if durable.var is not None}
    unknown = [var for var in needed_vars if var not in known_vars]
    if unknown:
        raise ReconcileError(f"no keychain backing for catalog var(s) {', '.join(unknown)} — add them to durables()")
    acquired: dict[str, str] = {}
    decisions: list[Decision] = []
    for durable in durs:
        if durable.var is not None and durable.var not in needed_vars:
            continue
        value, decision = _acquire_one(durable, durable.alias in rotations, sm, state_dir, dry_run)
        decisions.append(decision)
        if value is not None:
            acquired[durable.service] = value
    return acquired, tuple(decisions)


async def _tailnet_view(client_id: str | None, client_secret: str | None) -> TailnetView:
    if client_id is None or client_secret is None:
        return TailnetView(token=None, devices=None, error="Tailscale OAuth client not in keychain")
    try:
        token = await tailscale.oauth_token(client_id, client_secret)
    except TailscaleError as exc:
        return TailnetView(token=None, devices=None, error=str(exc))
    try:
        devices = await tailscale.list_devices(token)
    except TailscaleError as exc:
        return TailnetView(token=token, devices=None, error=str(exc))
    return TailnetView(token=token, devices=devices, error=None)


async def _host_authkey(
    host: str, bundle: Path, key_file: Path, view: TailnetView, rotate_authkey: bool, dry_run: bool
) -> tuple[str | None, str]:
    """The authkey to render into ``host``'s bundle, plus a report note. ``None`` only in dry-run,
    standing for a mint the run is not allowed to perform."""
    prior = sops.extract(bundle, key_file, '["tailscale"]["authkey"]').rstrip("\n") if bundle.exists() else None
    if prior and not rotate_authkey:
        # Never silently replace an existing key: replacing a still-redeemable key (bundle written,
        # node not yet booted) desyncs the join. Rotation is an explicit operator decision.
        if view.devices is None:
            return prior, f"authkey reused (membership unknown — {view.error})"
        if any(f"tag:{host}" in device.tags for device in view.devices):
            return prior, "authkey reused (tailnet member)"
        return prior, f"authkey reused (WARNING: no tag:{host} device in the tailnet — --rotate-authkey to rejoin)"
    reason = "rotated" if rotate_authkey and prior else "no prior bundle value"
    if dry_run:
        return None, f"authkey would be minted ({reason})"
    if view.token is None:
        raise ReconcileError(f"cannot mint an authkey for {host}: {view.error}")
    key = await tailscale.mint_authkey(view.token, host)
    return key, f"authkey minted ({reason})"


def _render_plaintext(sm: SecretsManifest, host: str, values: dict[str, str]) -> str:
    """Port of the retired ``encrypt_host_bundle`` renderer: secret values land literally (json
    quoting for scalars, raw ``VAR=value`` lines inside literal blocks) and the YAML key paths stay
    byte-identical to what sops-nix navigates."""
    groups: dict[str, list[str]] = {}
    for key in sm.hosts[host].secrets:
        top, _ = key.split("/", 1)
        groups.setdefault(top, []).append(key)
    parts: list[str] = []
    for top, keys in groups.items():
        parts.append(f"{top}:\n")
        for key in keys:
            leaf = key.split("/", 1)[1]
            entry = sm.catalog[key]
            if isinstance(entry, ScalarSecret):
                parts.append(f"  {leaf}: {json.dumps(values[entry.var])}\n")
            elif isinstance(entry, PerHostSecret):
                parts.append(f"  {leaf}: {json.dumps(values[f'{entry.var}_{host.upper()}'])}\n")
            else:
                parts.append(f"  {leaf}: |\n")
                parts.extend(f"    {var}={values[var]}\n" for var in entry.vars)
    return "".join(parts)


def _canonical_plaintext(ciphertext: str, key_file: Path) -> str:
    """Round-trip a fresh ciphertext back through sops so it is byte-comparable with the decrypted
    current bundle: sops re-emits YAML through its own emitter, so comparing the rendered input
    against a decrypt would spuriously differ on scalar quoting and rewrite every bundle every run."""
    with tempfile.NamedTemporaryFile("w", delete_on_close=False) as tmp:
        tmp.write(ciphertext)
        tmp.close()
        return sops.decrypt(Path(tmp.name), key_file)


async def _reconcile_host(
    sm: SecretsManifest,
    host: str,
    values: dict[str, str],
    view: TailnetView,
    state_dir: Path,
    rotate_authkey: bool,
    dry_run: bool,
) -> HostPlan:
    host_dir = state_dir / "hosts" / host
    key_file = host_dir / "key.txt"
    bundle = host_dir / "secrets.sops.yaml"
    notes: list[str] = []

    if not _nonempty(key_file):
        if dry_run:
            return HostPlan(host, changed=True, notes=("age key would be minted", "bundle would be created"))
        host_dir.mkdir(parents=True, exist_ok=True)
        host_dir.chmod(0o700)
        sops.keygen(key_file)
        notes.append("age key minted")
    pub = sops.pubkey(key_file)

    host_values = dict(values)
    for key in sm.hosts[host].secrets:
        entry = sm.catalog[key]
        if not isinstance(entry, PerHostSecret):
            continue
        if key != AUTHKEY_KEY:
            raise ReconcileError(f"no per-host acquisition for {key!r}")
        authkey, note = await _host_authkey(host, bundle, key_file, view, rotate_authkey, dry_run)
        notes.append(note)
        if authkey is None:  # dry-run: the mint this run is not allowed to perform
            return HostPlan(host, changed=True, notes=(*notes, "bundle would change"))
        host_values[f"{entry.var}_{host.upper()}"] = authkey

    if dry_run:
        missing = [var for var in _host_vars(sm, host) if var not in host_values]
        if missing:
            return HostPlan(host, changed=True, notes=(*notes, f"cannot diff — missing {', '.join(missing)}"))
    plaintext = _render_plaintext(sm, host, host_values)
    ciphertext = sops.encrypt(plaintext, pub)
    if bundle.exists():
        if sops.decrypt(bundle, key_file) == _canonical_plaintext(ciphertext, key_file):
            return HostPlan(host, changed=False, notes=(*notes, "bundle unchanged"))
        state = "bundle would change" if dry_run else "bundle rewritten"
    else:
        state = "bundle would be created" if dry_run else "bundle created"
    if not dry_run:
        _atomic_write(bundle, ciphertext)
    return HostPlan(host, changed=True, notes=(*notes, state))


def _render_rules(recipients: list[tuple[str, str]]) -> str:
    lines = ["creation_rules:"]
    for host, pub in recipients:
        lines += [
            f"  - path_regex: hosts/{host}/secrets\\.sops\\.yaml$",
            "    key_groups:",
            "      - age:",
            f"          - {pub}",
        ]
    return "\n".join(lines) + "\n"


def _reconcile_rules(sm: SecretsManifest, state_dir: Path, dry_run: bool) -> str:
    """Regenerate ``state/sops.yaml`` (used only by interactive ``sops edit``) when the recipient
    set changed. Recipients cover every materialized host, so a targeted run never drops the rest."""
    recipients = [
        (name, sops.pubkey(state_dir / "hosts" / name / "key.txt"))
        for name in sm.hosts
        if _nonempty(state_dir / "hosts" / name / "key.txt")
    ]
    rendered = _render_rules(recipients)
    rules_path = state_dir / "sops.yaml"
    if rules_path.exists() and rules_path.read_text() == rendered:
        return "unchanged"
    if dry_run:
        return "would change"
    _atomic_write(rules_path, rendered)
    return "rewritten"


async def _reconcile(
    manifest: Manifest,
    sm: SecretsManifest,
    targets: tuple[str, ...],
    rotations: frozenset[str],
    rotate_authkey: bool,
    dry_run: bool,
) -> ReconcileReport:
    _require_tools()
    durs = durables(manifest)
    _validate_rotations(durs, rotations, targets, sm)
    keychain.require_aqua_session()
    if dry_run:
        if not keychain.KEYCHAIN_PATH.exists():
            raise ReconcileError(f"no yclaw keychain at {keychain.KEYCHAIN_PATH} — run without --dry-run to create it")
    else:
        keychain.ensure()

    state_dir = Path.home() / manifest.host_paths.state_dir_rel
    needed_vars = tuple(dict.fromkeys(var for host in targets for var in _host_vars(sm, host)))
    with keychain.unlocked():
        acquired, decisions = _acquire_shared(durs, needed_vars, rotations, sm, state_dir, dry_run)

    values = {
        durable.var: acquired[durable.service]
        for durable in durs
        if durable.var is not None and durable.service in acquired
    }
    kc = manifest.host_paths.keychain
    view = await _tailnet_view(acquired.get(kc.ts_oauth_client_id), acquired.get(kc.ts_oauth_client_secret))

    plans = tuple(
        [await _reconcile_host(sm, host, values, view, state_dir, rotate_authkey, dry_run) for host in targets]
    )
    rules = _reconcile_rules(sm, state_dir, dry_run)
    return ReconcileReport(decisions=decisions, plans=plans, rules=rules, dry_run=dry_run)


def _print_report(report: ReconcileReport) -> None:
    stored_word = "would store" if report.dry_run else "stored"
    rows = [[d.alias, d.source, stored_word if d.stored else "-"] for d in report.decisions]
    click.echo(output.render_table(["SECRET", "SOURCE", "KEYCHAIN"], rows))
    click.echo()
    click.echo(output.render_table(["HOST", "RESULT"], [[p.host, "; ".join(p.notes)] for p in report.plans]))
    click.echo()
    click.echo(f"sops.yaml: {report.rules}")


@click.command("reconcile")
@click.argument("hosts", nargs=-1)
@click.option("--rotate-authkey", is_flag=True, help="Mint a fresh tailnet authkey for each target host.")
@click.option(
    "--rotate",
    "rotations",
    multiple=True,
    metavar="SECRET",
    help="Force a fresh acquire of a named durable secret (an alias from `yclaw secret list`); repeatable.",
)
@click.option(
    "--dry-run", is_flag=True, help="Report what is missing and which bundles would change; write and mint nothing."
)
def reconcile(hosts: tuple[str, ...], rotate_authkey: bool, rotations: tuple[str, ...], dry_run: bool) -> None:
    """Converge the keychain and per-host sops bundles onto the secrets manifest.

    Keychain values are reused; only missing ones are imported, generated, or prompted for, then
    persisted back. A HOST bundle is re-encrypted only when its decrypted plaintext would change.
    """
    manifest = load_manifest()
    sm = load_secrets_manifest()
    owners = [name for name, host_secrets in sm.hosts.items() if host_secrets.secrets]
    for host in hosts:
        if host not in sm.hosts:
            known = ", ".join(sm.hosts)
            raise click.BadParameter(f"unknown host {host!r}; known: {known}", param_hint="HOSTS")
        if host not in owners:
            raise click.BadParameter(f"{host!r} owns no secrets — nothing to reconcile", param_hint="HOSTS")
    targets = tuple(hosts) or tuple(owners)
    aliases = {durable.alias for durable in durables(manifest)}
    for rotation in rotations:
        if rotation not in aliases:
            raise click.BadParameter(f"unknown secret {rotation!r}; try `yclaw secret list`", param_hint="--rotate")

    async def _main() -> ReconcileReport:
        return await _reconcile(manifest, sm, targets, frozenset(rotations), rotate_authkey, dry_run)

    try:
        report = dispatch.run(_main)
    except (KeychainError, SopsError, TailscaleError, ReconcileError) as exc:
        raise click.ClickException(str(exc)) from exc
    _print_report(report)
