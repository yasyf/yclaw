#!/usr/bin/env bash
# Smoke tests for a deployed yclaw stack, run ON THE HOST with the VMs up:
#   1. config integrity        — nix flake check
#   2. per-VM health           — hermes doctor over tailscale ssh
#   3. model-plane reachability — GET metal:8317/v1/models with the Aperture static bearer
# Some deeper live-stack checks still need a running stack and stay commented scaffolding below.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# secrets.sh (via manifest.sh) gives us YCLAW_STATE, where the per-host age keys + sops bundles live.
# collect_secrets is NEVER called, so nothing is minted (mirrors redeploy.sh / onboard.sh).
# shellcheck source=scripts/lib/secrets.sh
source "$REPO_ROOT/scripts/lib/secrets.sh"

# config integrity
nix flake check --extra-experimental-features 'nix-command flakes'

# per-VM health via tailscale ssh (a loop so more doctor-able VMs can be added; today just hermes)
# shellcheck disable=SC2043
for vm in hermes; do
  tailscale ssh "admin@${vm}" -- hermes doctor
done

# --- model-plane check --------------------------------------------------------
# CLIPROXY_API_KEY is minted in collect_secrets and lands ONLY in metal's sops bundle
# (nixos/secrets-manifest.json: metal owns cliproxy/api-key) — it is NOT persisted to any host
# plaintext file, so read it back by decrypting metal's bundle with the host-staged metal age key.
metal_key="$YCLAW_STATE/hosts/metal/key.txt"
metal_bundle="$YCLAW_STATE/hosts/metal/secrets.sops.yaml"
[ -s "$metal_key" ] && [ -s "$metal_bundle" ] \
  || die "no metal secrets bundle at $metal_bundle — run \`just bootstrap\` first."
cliproxy_key="$(SOPS_AGE_KEY_FILE="$metal_key" sops --decrypt --config /dev/null \
  --input-type yaml --output-type yaml "$metal_bundle" \
  | sed -n 's/^[[:space:]]*api-key:[[:space:]]*//p' | tr -d '"')"
[ -n "$cliproxy_key" ] || die "could not extract the cliproxy API key from metal's sops bundle."

# This model-plane probe doubles as the allowlist-enforcement check: a 2xx means cliproxy ACCEPTED
# the bearer; a 401/403 would mean the allowlist REJECTED it. The bearer path is settled — hermes
# presents this same key via its model-plane key_env and gets a 2xx (verified live).
log "Model-plane check: GET http://metal:8317/v1/models with the cliproxy bearer ..."
curl -fsS --max-time 10 -o /dev/null -H "Authorization: Bearer $cliproxy_key" \
  http://metal:8317/v1/models \
  || die "model-plane check failed: metal:8317/v1/models did not return 2xx with the cliproxy bearer."
log "Model-plane check passed."

# --- live-stack checks below need a running stack; run by hand once up. ---
# fallback: disable the gpt-5.5 upstream → confirm hermes hops gemini-3.5 → qwen-local
# agent-vault: a tool call needing Exa/OpenAI succeeds (bearer injected via http://metal.@@TAILNET_DOMAIN@@:14322) and fails cleanly if the broker is down
# gmail: `gws` with a dummy token round-trips through the agent-vault proxy (real token never in the hermes VM)
# bluebubbles: send/receive in a DM AND a group, from an authorized handle (allowlist enforced) via https://bluebubbles.@@TAILNET_DOMAIN@@
