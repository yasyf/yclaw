#!/usr/bin/env bash
# Mint a FRESH ephemeral hermes tailnet auth key and re-encrypt hermes's sops bundle with it, refresh
# the node-config share, and wipe the stale /var/lib/tailscale pre-seed.
#
# WHY: hermes joins as an EPHEMERAL, single-use, tagged node (scripts/lib/secrets.sh `_ts_mint_key`,
# `"ephemeral": True`). Tailscale REAPS an ephemeral node shortly after it disconnects — so any
# disk-replace (scripts/deploy-vm.sh) or reboot strands the old node, and the booting image can NOT
# reconnect with the persisted node key (it's gone): it must join FRESH via a new auth key. Persisting
# /var/lib/tailscale can't preserve an ephemeral identity, so the disk-replace path re-mints instead.
# In-guest `nixos-rebuild switch` (scripts/redeploy.sh) never disconnects hermes, so it needs none of this.
#
# Reads ONLY the dedicated yclaw keychain (the Tailscale OAuth client + the BlueBubbles server password)
# — NO upstream API keys (those live in metal's bundle, not hermes's), so it runs unattended.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/lib/secrets.sh"
manifest="$REPO/nixos/secrets-manifest.json"
node_config_dir="$HOME/.config/yclaw/vm-secrets"

[ -f "$YCLAW_KEYCHAIN" ] || _secrets_fail "no yclaw keychain at $YCLAW_KEYCHAIN — run \`just bootstrap\` first."

# --- mint a fresh ephemeral authkey via the OAuth client (keychain) ----------------------------------
_yclaw_keychain_unlock
TS_OAUTH_ID="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_TS_OAUTH_ID" -w "$YCLAW_KEYCHAIN")"
TS_OAUTH_SECRET="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_TS_OAUTH_SECRET" -w "$YCLAW_KEYCHAIN")"
TS_ACCESS_TOKEN="$(curl -fsS -d "client_id=$TS_OAUTH_ID" -d "client_secret=$TS_OAUTH_SECRET" \
  https://api.tailscale.com/api/v2/oauth/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$TS_ACCESS_TOKEN" ] || _secrets_fail "Tailscale OAuth token exchange returned no access_token."
export TS_ACCESS_TOKEN
TS_AUTHKEY_HERMES="$(_ts_mint_key hermes)"; export TS_AUTHKEY_HERMES
BLUEBUBBLES_PASSWORD="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_SERVER" -w "$YCLAW_KEYCHAIN")"
export BLUEBUBBLES_PASSWORD
_yclaw_keychain_lock

# --- re-encrypt ONLY hermes's bundle (authkey + hermes/env) to hermes's age recipient -----------------
# Mirrors scripts/lib/secrets.sh's per-host bundle builder, restricted to hermes (whose catalog entries
# are all keychain-backed, so no API keys are needed).
age_key="$YCLAW_STATE/hosts/hermes/key.txt"
[ -s "$age_key" ] || _secrets_fail "no hermes age key at $age_key."
pub="$(age-keygen -y "$age_key")"
plain="$(mktemp)"; trap 'rm -f "$plain"' EXIT
python3 - "$manifest" hermes "$plain" <<'PY'
import os, sys, json
from collections import OrderedDict
manifest = json.load(open(sys.argv[1])); host, out = sys.argv[2], sys.argv[3]
e, catalog = os.environ, manifest["catalog"]
groups = OrderedDict()
for key in manifest["hosts"][host]["secrets"]:
    top, leaf = key.split("/", 1); groups.setdefault(top, []).append((leaf, catalog[key]))
parts = []
for top, leaves in groups.items():
    parts.append(f"{top}:\n")
    for leaf, spec in leaves:
        if spec["kind"] == "scalar":
            parts.append(f"  {leaf}: {json.dumps(e[spec['var']])}\n")
        elif spec["kind"] == "perhost":
            parts.append(f"  {leaf}: {json.dumps(e['{}_{}'.format(spec['var'], host.upper())])}\n")
        else:
            parts.append(f"  {leaf}: |\n")
            for v in spec["vars"]:
                parts.append(f"    {v}={e[v]}\n")
open(out, "w").write("".join(parts))
PY
sops --encrypt --config /dev/null --input-type yaml --output-type yaml --age "$pub" "$plain" \
  > "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml"
rm -f "$plain"; trap - EXIT

# Verify the new bundle decrypts to the fresh authkey before we rely on it.
SOPS_AGE_KEY_FILE="$age_key" sops --decrypt --config /dev/null --input-type yaml --output-type yaml \
  "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml" | grep -qF "$TS_AUTHKEY_HERMES" \
  || _secrets_fail "re-encrypted hermes bundle does not decrypt to the fresh authkey."

# Refresh the tart-hermes `sops` share source so the next first-boot seedNodeConfig installs the new key.
install -m 600 "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml" "$node_config_dir/secrets.sops.yaml"

# Wipe the /var/lib/tailscale pre-seed: the ephemeral node is reaped, so the booting image must join
# FRESH (empty state → uses the authkey) rather than reconnect with the dead node key.
rm -f "$YCLAW_STATE/hermes-tailscale"/* 2>/dev/null || true

echo "remint-hermes-authkey: fresh ephemeral authkey minted, hermes bundle + vm-secrets share refreshed, pre-seed wiped."
