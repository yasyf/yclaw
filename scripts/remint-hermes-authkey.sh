#!/usr/bin/env bash
# Mint a FRESH hermes tailnet auth key and re-encrypt hermes's sops bundle with it, refresh
# the node-config share, and wipe any stale /var/lib/tailscale pre-seed.
#
# WHY: hermes joins as a PERSISTENT, single-use, tagged node (scripts/lib/secrets.sh `_ts_mint_key`).
# A persistent node survives an ordinary disconnect (reboot, sleep, blip): it reconnects from the node
# key persisted on its own disk (/var/lib/tailscale), so a reboot needs NONE of this. A disk-replace
# (scripts/deploy-vm.sh) is different — it throws away the whole VM disk, and with it the node key, so
# the fresh image boots with empty tailscale state and must join FRESH via a new auth key. This script
# mints that key and re-seeds hermes's bundle; deploy-vm.sh separately DELETES the old (now non-reaping)
# hermes device so the new node keeps the `hermes` MagicDNS name instead of drifting to `hermes-1`.
# In-guest `nixos-rebuild switch` (scripts/redeploy.sh) never disconnects hermes, so it needs none of this.
#
# Reads the yclaw keychain (Tailscale OAuth client + BlueBubbles password) and decrypts metal's
# bundle for the cliproxy key (age key = state file) — no upstream API keys, so it runs unattended.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/lib/secrets.sh"
node_config_dir="$HOME/.config/yclaw/vm-secrets"

[ -f "$YCLAW_KEYCHAIN" ] || _secrets_fail "no yclaw keychain at $YCLAW_KEYCHAIN — run \`just bootstrap\` first."

# --- mint a fresh authkey via the OAuth client (keychain) --------------------------------------------
# kc_read unlocks the yclaw keychain, reads the item, and re-locks — one self-contained read per call.
TS_OAUTH_ID="$(kc_read "$KC_SERVICE_TS_OAUTH_ID")"
TS_OAUTH_SECRET="$(kc_read "$KC_SERVICE_TS_OAUTH_SECRET")"
TS_ACCESS_TOKEN="$(curl -fsS -d "client_id=$TS_OAUTH_ID" -d "client_secret=$TS_OAUTH_SECRET" \
  https://api.tailscale.com/api/v2/oauth/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$TS_ACCESS_TOKEN" ] || _secrets_fail "Tailscale OAuth token exchange returned no access_token."
export TS_ACCESS_TOKEN
TS_AUTHKEY_HERMES="$(_ts_mint_key hermes)"; export TS_AUTHKEY_HERMES
BLUEBUBBLES_PASSWORD="$(kc_read "$KC_SERVICE_BLUEBUBBLES_SERVER")"
export BLUEBUBBLES_PASSWORD
# hermes/env also carries CLIPROXY_API_KEY — read it from metal's bundle, never mint fresh.
CLIPROXY_API_KEY="$(cliproxy_key_from_metal_bundle)"
export CLIPROXY_API_KEY

# --- re-encrypt ONLY hermes's bundle (authkey + hermes/env) to hermes's age recipient -----------------
# encrypt_host_bundle (scripts/lib/secrets.sh) renders the bundle from the exported env above.
age_key="$YCLAW_STATE/hosts/hermes/key.txt"
[ -s "$age_key" ] || _secrets_fail "no hermes age key at $age_key."
plain="$(mktemp)"; trap 'rm -f "$plain"' EXIT
encrypt_host_bundle hermes "$plain" "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml"
rm -f "$plain"; trap - EXIT

# Verify the new bundle decrypts to the fresh authkey before we rely on it.
SOPS_AGE_KEY_FILE="$age_key" sops --decrypt --config /dev/null --input-type yaml --output-type yaml \
  "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml" | grep -qF "$TS_AUTHKEY_HERMES" \
  || _secrets_fail "re-encrypted hermes bundle does not decrypt to the fresh authkey."

# Refresh the tart-hermes `sops` share source so the next first-boot seedNodeConfig installs the new key.
install -m 600 "$YCLAW_STATE/hosts/hermes/secrets.sops.yaml" "$node_config_dir/secrets.sops.yaml"

# Wipe any /var/lib/tailscale pre-seed: the disk-replace gives the new image empty tailscale state, so
# it joins FRESH via the authkey (deploy-vm.sh deletes the old device) rather than reconnect with a
# stale node key.
rm -f "$YCLAW_STATE/hermes-tailscale"/* 2>/dev/null || true

echo "remint-hermes-authkey: fresh authkey minted, hermes bundle + vm-secrets share refreshed, pre-seed wiped."
