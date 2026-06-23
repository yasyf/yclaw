#!/usr/bin/env bash
# scripts/lib/secrets.sh — the single sourceable secrets module. Both
# scripts/collect-secrets.sh and scripts/bootstrap.sh source this and call
# `collect_secrets`, so there is exactly one path that mints the age key, prompts
# for the runtime secrets, and writes the sops-encrypted blob.
#
# ALL output lands under ~/.yclaw/state (override with $YCLAW_STATE), never the
# repo. Each host gets its OWN age keypair and its OWN bundle, encrypted only to
# that host's recipient and holding only the secrets it owns per
# nixos/secrets-manifest.json — so a host can decrypt only its own secrets:
#   hosts/<host>/key.txt            private age key for <host> (staged into <host>'s share)
#   hosts/<host>/secrets.sops.yaml  sops/age-encrypted bundle for <host> (its keys only)
#   sops.yaml                       resolved per-host sops creation rules (for `sops edit`)
#
# Every yclaw-generated password lives in a DEDICATED macOS keychain — never the login
# keychain — so the credentials are siloed from the user's personal keychain:
#   $HOME/Library/Keychains/yclaw.keychain-db
# Its unlock password is stored ONCE in the LOGIN keychain under `yclaw-keychain-password`,
# so the scripts can auto-unlock the dedicated keychain non-interactively. The dedicated
# keychain holds these items (account `-a "$USER"` on each), GENERATED here and reused on
# re-run (retrieve any with
# `security find-generic-password -s <service> -w "$HOME/Library/Keychains/yclaw.keychain-db"`):
#   yclaw-agent-vault-master        agent-vault master password
#   yclaw-metal-admin-pass          admin account baked into the metal guest image (packer)
#   yclaw-bluebubbles-admin-pass    admin account baked into the bluebubbles guest image (packer)
#   yclaw-bluebubbles-server-pass   BlueBubbles server password (also rendered into sops hermes/env)
#   yclaw-ts-oauth-client-id        Tailscale OAuth client id (mints per-node ephemeral tagged keys)
#   yclaw-ts-oauth-client-secret    Tailscale OAuth client secret (mints per-node ephemeral tagged keys)

YCLAW_STATE="${YCLAW_STATE:-$HOME/.yclaw/state}"
YCLAW_KEYCHAIN="$HOME/Library/Keychains/yclaw.keychain-db"
KC_SERVICE_KEYCHAIN_PASS="yclaw-keychain-password"
KC_SERVICE="yclaw-agent-vault-master"
KC_SERVICE_METAL_ADMIN="yclaw-metal-admin-pass"
KC_SERVICE_BLUEBUBBLES_ADMIN="yclaw-bluebubbles-admin-pass"
KC_SERVICE_BLUEBUBBLES_SERVER="yclaw-bluebubbles-server-pass"
KC_SERVICE_TS_OAUTH_ID="yclaw-ts-oauth-client-id"
KC_SERVICE_TS_OAUTH_SECRET="yclaw-ts-oauth-client-secret"
SECRETS_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_secrets_ask()  { gum input --password --prompt "  $1 ❯ "; }
_secrets_note() { gum style --foreground 244 "  $*"; }
_secrets_ok()   { gum style --foreground 84  "  $*"; }
_secrets_fail() { gum style --foreground 196 "  $*"; exit 1; }

# Ensure the dedicated yclaw keychain exists and is unlocked. On first run it is created with
# a freshly-generated unlock password that is persisted in the LOGIN keychain under
# `yclaw-keychain-password`; thereafter the unlock password is read back from the login
# keychain and used to unlock the dedicated keychain non-interactively. set-keychain-settings
# -l -t 300 re-locks the keychain on sleep and after 300s idle, so the same-user exposure
# window (any process can read every yclaw secret while unlocked) is bounded; the timeout is
# (re)applied on EVERY unlock so pre-existing keychains pick it up too. collect_secrets also
# re-locks explicitly when done (see _yclaw_keychain_lock). The items keep the DEFAULT ACL by
# design — same-user repo scripts (bootstrap.sh, collect-secrets.sh, connect-google-oauth.py,
# packer) must read them, and scoping with -T/set-key-partition-list to /usr/bin/security is
# fragile across macOS versions and would lock those callers out — so the auto-lock timeout
# plus the explicit re-lock are the mitigation, not an ACL restriction. Call this before any
# yclaw-secret access.
_yclaw_keychain_unlock() {
  local kc_pass
  if [ ! -f "$YCLAW_KEYCHAIN" ]; then
    kc_pass="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security create-keychain -p "$kc_pass" "$YCLAW_KEYCHAIN"
    security set-keychain-settings -l -t 300 "$YCLAW_KEYCHAIN"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_KEYCHAIN_PASS" \
      -l 'yclaw dedicated keychain unlock password' -w "$kc_pass"
    _secrets_ok "Created dedicated yclaw keychain → $YCLAW_KEYCHAIN (unlock pw → login Keychain $KC_SERVICE_KEYCHAIN_PASS)."
  fi
  kc_pass="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_KEYCHAIN_PASS" -w)"
  security unlock-keychain -p "$kc_pass" "$YCLAW_KEYCHAIN"
  security set-keychain-settings -l -t 300 "$YCLAW_KEYCHAIN"
}

# Re-lock the dedicated yclaw keychain so secrets are not readable after collect_secrets
# finishes (the -t 300 auto-lock timeout would eventually do this; this makes it immediate).
# Call this AFTER the last keychain read.
_yclaw_keychain_lock() {
  security lock-keychain "$YCLAW_KEYCHAIN"
}

# Mint ONE ephemeral, single-use, pre-authorized, TAGGED tailnet auth key for $1 (host short
# name, e.g. `hermes` → tag:hermes) via the Tailscale keys API. Reads the global TS_ACCESS_TOKEN
# (the OAuth access token exchanged in collect_secrets). The JSON body is built with python3
# json.dumps and the response parsed with json.load — never shell interpolation — so a tag or
# host name can never break out of the request. FATAL on an empty/garbled response or a key that
# is not a `tskey-…` string. Echoes the minted key on stdout.
_ts_mint_key() {
  local host="$1" body resp key
  body="$(python3 - "$host" <<'PY'
import json, sys
host = sys.argv[1]
print(json.dumps({
    "capabilities": {"devices": {"create": {
        "reusable": False, "ephemeral": True, "preauthorized": True,
        "tags": [f"tag:{host}"],
    }}},
    "expirySeconds": 7200,
    "description": f"yclaw bootstrap {host}",
}))
PY
)"
  resp="$(curl -fsS -H "Authorization: Bearer $TS_ACCESS_TOKEN" -H 'Content-Type: application/json' \
    -d "$body" https://api.tailscale.com/api/v2/tailnet/-/keys)" \
    || _secrets_fail "Tailscale key mint failed for $host (POST /keys)."
  key="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))')"
  [ "${key:0:6}" = "tskey-" ] || _secrets_fail "Tailscale key mint for $host did not return a tskey-… key."
  printf '%s' "$key"
}

# Prompt for the external API secrets, generate/reuse the age key + the dedicated-keychain
# passwords (vault master, the two per-VM admin passwords, BlueBubbles server), and write the
# sops-encrypted blob to ~/.yclaw/state. Idempotent: reuses an existing age key and the
# yclaw-keychain-stored passwords; reuses pre-set $OPENAI_API_KEY/$EXA_API_KEY/$HONCHO_API_KEY
# from the environment if present, else prompts for them. The caller must run under
# `set -euo pipefail`.
collect_secrets() {
  local t manifest sops_rendered host age_key pub plain recipients
  local TS_OAUTH_ID TS_OAUTH_SECRET TS_ACCESS_TOKEN ts_authkey

  for t in sops age-keygen gum security openssl python3 curl; do
    command -v "$t" >/dev/null || { printf 'FATAL: %s not on PATH.\n' "$t" >&2; exit 1; }
  done

  manifest="$SECRETS_LIB_REPO/nixos/secrets-manifest.json"
  sops_rendered="$YCLAW_STATE/sops.yaml"
  [ -s "$manifest" ] || _secrets_fail "secrets manifest not found: $manifest"
  mkdir -p "$YCLAW_STATE"

  gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 212 \
    'yclaw · runtime secret collection' \
    'Values are read locally and sops-encrypted. Nothing is printed or sent.'

  # Reuse a value already exported in the environment (non-interactive re-bootstrap), else prompt.
  OPENAI_API_KEY="${OPENAI_API_KEY:-$(_secrets_ask 'OpenAI API key (sk-…)')}"
  EXA_API_KEY="${EXA_API_KEY:-$(_secrets_ask 'Exa API key')}"
  HONCHO_API_KEY="${HONCHO_API_KEY:-$(_secrets_ask 'Honcho API key')}"
  # GitHub: reuse the locally-authenticated gh CLI token rather than prompting.
  if command -v gh >/dev/null && GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && [ -n "$GITHUB_TOKEN" ]; then
    _secrets_note "GitHub token sourced from gh CLI (account: $(gh api user -q .login 2>/dev/null || echo '?'))."
  else
    GITHUB_TOKEN="$(_secrets_ask 'GitHub token (ghp_… / github_pat_…)')"
  fi
  # Aperture static key: mint a random one when the operator did not supply it.
  if [ -z "${APERTURE_STATIC_KEY:-}" ]; then
    APERTURE_STATIC_KEY="$(openssl rand -hex 32)"
    _secrets_note 'Minted a random Aperture static key (openssl rand -hex 32).'
  fi
  # Every yclaw password lives in the dedicated yclaw keychain — ensure it exists and is
  # unlocked before any generate-or-reuse below.
  _yclaw_keychain_unlock

  # Tailscale OAuth client: the operator supplies it ONCE (an admin-tagged client with the
  # `auth_keys` write scope and the device tags it may mint), persisted in the yclaw keychain and
  # reused thereafter. We exchange it for a short-lived access token, then mint ONE ephemeral,
  # single-use, tagged key per tailnet-joining host that owns `tailscale/authkey` — so no reusable
  # fleet-wide key ever exists. REQUIRED: there is no fallback to a shared key (per-node is the point).
  if TS_OAUTH_ID="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_TS_OAUTH_ID" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing Tailscale OAuth client id from yclaw keychain ($KC_SERVICE_TS_OAUTH_ID)."
  else
    TS_OAUTH_ID="$(_secrets_ask 'Tailscale OAuth client id')"
    [ -n "$TS_OAUTH_ID" ] || _secrets_fail 'Tailscale OAuth client id is required (mints per-node keys).'
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_TS_OAUTH_ID" \
      -l 'yclaw Tailscale OAuth client id' -w "$TS_OAUTH_ID" "$YCLAW_KEYCHAIN"
    _secrets_ok "Stored Tailscale OAuth client id → yclaw keychain ($KC_SERVICE_TS_OAUTH_ID)."
  fi
  if TS_OAUTH_SECRET="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_TS_OAUTH_SECRET" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing Tailscale OAuth client secret from yclaw keychain ($KC_SERVICE_TS_OAUTH_SECRET)."
  else
    TS_OAUTH_SECRET="$(_secrets_ask 'Tailscale OAuth client secret')"
    [ -n "$TS_OAUTH_SECRET" ] || _secrets_fail 'Tailscale OAuth client secret is required (mints per-node keys).'
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_TS_OAUTH_SECRET" \
      -l 'yclaw Tailscale OAuth client secret' -w "$TS_OAUTH_SECRET" "$YCLAW_KEYCHAIN"
    _secrets_ok "Stored Tailscale OAuth client secret → yclaw keychain ($KC_SERVICE_TS_OAUTH_SECRET)."
  fi
  TS_ACCESS_TOKEN="$(curl -fsS \
    -d "client_id=$TS_OAUTH_ID" -d "client_secret=$TS_OAUTH_SECRET" \
    https://api.tailscale.com/api/v2/oauth/token \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')" \
    || _secrets_fail 'Tailscale OAuth token exchange failed (POST /oauth/token).'
  [ -n "$TS_ACCESS_TOKEN" ] || _secrets_fail 'Tailscale OAuth token exchange returned no access_token.'
  for host in $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("\n".join(h for h,v in m["hosts"].items() if "tailscale/authkey" in v["secrets"]))' "$manifest"); do
    # Assign-then-export, NOT `export VAR=$(_ts_mint_key …)`: `export` always succeeds, so it would
    # mask a mint failure under `set -e` and silently export an empty key. A bare assignment lets
    # set -e abort on a failed mint (and _ts_mint_key itself _secrets_fails before returning empty).
    ts_authkey="$(_ts_mint_key "$host")"
    export "TS_AUTHKEY_$(printf '%s' "$host" | tr a-z A-Z)=$ts_authkey"
    _secrets_ok "Minted ephemeral tag:$host auth key for $host (single-use, 2h)."
  done

  # Vault master password: generate once, persist in the dedicated yclaw keychain, reuse thereafter.
  if AGENT_VAULT_MASTER_PASSWORD="$(security find-generic-password -a "$USER" -s "$KC_SERVICE" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing vault master password from yclaw keychain ($KC_SERVICE)."
  else
    AGENT_VAULT_MASTER_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE" \
      -l 'yclaw agent-vault master password' -w "$AGENT_VAULT_MASTER_PASSWORD" "$YCLAW_KEYCHAIN"
    _secrets_ok "Generated vault master password → yclaw keychain ($KC_SERVICE)."
  fi

  # metal admin password: generate once, persist in the dedicated yclaw keychain, reuse thereafter.
  # NOT a sops/runtime secret — packer reads it from the yclaw keychain as PKR_VAR_vm_admin_pass
  # for the metal build (see docs/DEPLOY.md and packer/metal.pkr.hcl).
  if METAL_ADMIN_PASS="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_METAL_ADMIN" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing metal admin password from yclaw keychain ($KC_SERVICE_METAL_ADMIN)."
  else
    METAL_ADMIN_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_METAL_ADMIN" \
      -l 'yclaw metal admin password' -w "$METAL_ADMIN_PASS" "$YCLAW_KEYCHAIN"
    _secrets_ok "Generated metal admin password → yclaw keychain ($KC_SERVICE_METAL_ADMIN)."
  fi

  # bluebubbles admin password: generate once, persist in the dedicated yclaw keychain, reuse
  # thereafter. NOT a sops/runtime secret — packer reads it from the yclaw keychain as
  # PKR_VAR_vm_admin_pass for the bluebubbles build (see docs/DEPLOY.md and packer/bluebubbles.pkr.hcl).
  if BLUEBUBBLES_ADMIN_PASS="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_ADMIN" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing bluebubbles admin password from yclaw keychain ($KC_SERVICE_BLUEBUBBLES_ADMIN)."
  else
    BLUEBUBBLES_ADMIN_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_ADMIN" \
      -l 'yclaw bluebubbles admin password' -w "$BLUEBUBBLES_ADMIN_PASS" "$YCLAW_KEYCHAIN"
    _secrets_ok "Generated bluebubbles admin password → yclaw keychain ($KC_SERVICE_BLUEBUBBLES_ADMIN)."
  fi

  # BlueBubbles server password: generate once, persist in the dedicated yclaw keychain, reuse
  # thereafter. Rendered into the sops hermes/env below so the hermes VM carries it; the
  # bluebubbles VM's setup flow resolves @@BLUEBUBBLES_PASSWORD@@ from this same value.
  if BLUEBUBBLES_PASSWORD="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_SERVER" -w "$YCLAW_KEYCHAIN" 2>/dev/null)"; then
    _secrets_note "Reusing BlueBubbles server password from yclaw keychain ($KC_SERVICE_BLUEBUBBLES_SERVER)."
  else
    BLUEBUBBLES_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_SERVER" \
      -l 'yclaw BlueBubbles server password' -w "$BLUEBUBBLES_PASSWORD" "$YCLAW_KEYCHAIN"
    _secrets_ok "Generated BlueBubbles server password → yclaw keychain ($KC_SERVICE_BLUEBUBBLES_SERVER)."
  fi

  export AGENT_VAULT_MASTER_PASSWORD OPENAI_API_KEY EXA_API_KEY \
         HONCHO_API_KEY GITHUB_TOKEN BLUEBUBBLES_PASSWORD APERTURE_STATIC_KEY \
         METAL_ADMIN_PASS BLUEBUBBLES_ADMIN_PASS

  # One age keypair + one bundle PER HOST, each encrypted ONLY to that host's recipient and
  # holding ONLY the secrets that host owns (nixos/secrets-manifest.json). A host can decrypt
  # only its own bundle, so VM isolation is enforced at the crypto layer. Hosts that own no
  # secrets (bluebubbles) get no key and no bundle.
  recipients=""
  for host in $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("\n".join(h for h,v in m["hosts"].items() if v["secrets"]))' "$manifest"); do
    age_key="$YCLAW_STATE/hosts/$host/key.txt"
    mkdir -p "$YCLAW_STATE/hosts/$host"
    chmod 700 "$YCLAW_STATE/hosts/$host"
    if [ ! -s "$age_key" ]; then
      (umask 077; age-keygen -o "$age_key" 2>/dev/null)
      _secrets_ok "Minted age key for $host → $age_key"
    fi
    pub="$(age-keygen -y "$age_key")"
    [ "${pub:0:4}" = "age1" ] || _secrets_fail "could not derive age public key for $host."
    recipients="$recipients$host $pub"$'\n'

    plain="$(mktemp)"; trap 'rm -f "$plain"' EXIT
    # Built in Python so secret values are written literally (no shell/YAML interpolation),
    # and the YAML key paths stay byte-identical to what sops-nix navigates.
    python3 - "$manifest" "$host" "$plain" <<'PY'
import os, sys, json
from collections import OrderedDict
manifest = json.load(open(sys.argv[1]))
host, out = sys.argv[2], sys.argv[3]
e, catalog = os.environ, manifest["catalog"]
groups = OrderedDict()
for key in manifest["hosts"][host]["secrets"]:
    top, leaf = key.split("/", 1)
    groups.setdefault(top, []).append((leaf, catalog[key]))
parts = []
for top, leaves in groups.items():
    parts.append(f"{top}:\n")
    for leaf, spec in leaves:
        if spec["kind"] == "scalar":
            parts.append(f"  {leaf}: {json.dumps(e[spec['var']])}\n")
        elif spec["kind"] == "perhost":
            perhost_var = "{}_{}".format(spec["var"], host.upper())
            parts.append(f"  {leaf}: {json.dumps(e[perhost_var])}\n")
        else:
            parts.append(f"  {leaf}: |\n")
            for v in spec["vars"]:
                parts.append(f"    {v}={e[v]}\n")
open(out, "w").write("".join(parts))
PY

    # --input-type/--output-type yaml are REQUIRED: the mktemp file has no .yaml extension, so
    # sops would otherwise treat it as binary and wrap the document in a `data:` blob that
    # sops-nix cannot navigate (it extracts secrets by key path like tailscale/authkey).
    # --config /dev/null ignores any ambient .sops.yaml (e.g. the repo's, when collect_secrets
    # runs from the repo root): the explicit --age recipient is the single authoritative key.
    sops --encrypt --config /dev/null --input-type yaml --output-type yaml --age "$pub" "$plain" \
      > "$YCLAW_STATE/hosts/$host/secrets.sops.yaml"
    rm -f "$plain"; trap - EXIT
    _secrets_ok "Encrypted $host bundle → hosts/$host/secrets.sops.yaml"
  done

  # Resolved per-host sops creation rules for `sops edit hosts/<host>/secrets.sops.yaml`.
  # The bundles themselves are encrypted above via the explicit --age recipient (which
  # overrides creation_rules), so this file is only for interactive edits.
  printf '%s' "$recipients" | python3 - "$sops_rendered" <<'PY'
import sys
out, rules = sys.argv[1], ["creation_rules:"]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    host, pub = line.split(" ", 1)
    rules += [f"  - path_regex: hosts/{host}/secrets\\.sops\\.yaml$",
              "    key_groups:", "      - age:", f"          - {pub}"]
open(out, "w").write("\n".join(rules) + "\n")
PY

  # All yclaw-secret reads are done (the per-host bundle encryption above reads the keychain
  # passwords from the exported env, and _ts_mint_key read TS_ACCESS_TOKEN earlier) — re-lock
  # the dedicated keychain so nothing else can read it for the rest of the run.
  _yclaw_keychain_lock
}
