#!/usr/bin/env bash
# Clean slate: wipe host secret/agent state + the generated keychain items so the next
# `just bootstrap` regenerates everything fresh. PRESERVES the operator-supplied Tailscale OAuth
# client (yclaw-ts-oauth-client-{id,secret}) and the large, content-addressed model caches (set
# WIPE_MODELS=1 to drop those too). The VMs and their tailnet device registrations are torn down
# separately by scripts/destroy.sh (the `nuke: destroy` recipe dependency runs it first).
#
# The wipe subdir list and the generated-keychain-service list come from machines.json
# (host_paths.state_subdirs_wipe / host_paths.keychain_generated_services) — one source of truth.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"

state="$HOME/.yclaw/state"

# Secret + agent state under ~/.yclaw/state (keep model weight caches by default). The hermes
# agent writes some skill files read-only (mode 444 inside 555 dirs), so make each tree writable
# before removing it — otherwise rm cannot unlink them and aborts under `set -e`.
wipe_subdirs="$(manifest_list '.host_paths.state_subdirs_wipe')"
while IFS= read -r d; do
  [ -e "$state/$d" ] && chmod -R u+w "$state/$d" 2>/dev/null || true
  rm -rf "${state:?}/$d"
done <<< "$wipe_subdirs"
rm -f "$state"/secrets.sops.yaml* "$state/values.env"
if [ "${WIPE_MODELS:-0}" = "1" ]; then
  rm -rf "$state/hf" "$state/omlx" "$HOME/.cache/huggingface/hub"
  echo "nuke: dropped model caches (WIPE_MODELS=1) — redeploy will re-download ~20 GB"
else
  echo "nuke: preserved model caches ($state/{hf,omlx}, ~/.cache/huggingface/hub); set WIPE_MODELS=1 to drop them"
fi
# The hermes node-config share source, so a fresh hermes can't re-seed stale secrets.
rm -rf "$HOME/.config/yclaw/vm-secrets"
# Gitignored repo build cruft.
rm -rf secrets/runtime .build

# Keychain: delete only the GENERATED items; keep the OAuth client + keychain unlock password.
kc="$HOME/Library/Keychains/yclaw.keychain-db"
if [ -f "$kc" ]; then
  generated_services="$(manifest_list '.host_paths.keychain_generated_services')"
  while IFS= read -r svc; do
    security delete-generic-password -s "$svc" "$kc" >/dev/null 2>&1 || true
  done <<< "$generated_services"
  echo "nuke: cleared generated keychain passwords; preserved yclaw-ts-oauth-client-{id,secret}"
fi
echo "nuke: clean slate (tailnet devices deleted by destroy). Next: just bootstrap."
