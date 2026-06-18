#!/usr/bin/env bash
# Human-only step: collect the runtime secrets, mint the age key, and write the
# sops-encrypted secrets to ~/.yclaw/state. Thin wrapper over the single secrets
# module (scripts/lib/secrets.sh); run on the host (hidden input via gum, so the
# raw secrets never leave your terminal). Idempotent: reuses an existing age key
# and the dedicated-keychain generated passwords (vault master, the two per-VM
# admin passwords, BlueBubbles server).
#
# Every yclaw password lives in the dedicated yclaw keychain
# ($HOME/Library/Keychains/yclaw.keychain-db), unlocked via `yclaw-keychain-password`
# in the login keychain. Retrieve any generated password with:
#   KC="$HOME/Library/Keychains/yclaw.keychain-db"
#   security find-generic-password -s yclaw-agent-vault-master      -w "$KC"  # vault master
#   security find-generic-password -s yclaw-metal-admin-pass        -w "$KC"  # metal admin (packer)
#   security find-generic-password -s yclaw-bluebubbles-admin-pass  -w "$KC"  # bluebubbles admin (packer)
#   security find-generic-password -s yclaw-bluebubbles-server-pass -w "$KC"  # BlueBubbles server
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.nix-profile/bin:/opt/homebrew/bin:$PATH"

source "$REPO/scripts/lib/secrets.sh"
collect_secrets

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 84 \
  "✓ per-host secrets encrypted → $YCLAW_STATE/hosts/<host>/secrets.sops.yaml" \
  "✓ per-host age keys staged for the VMs → $YCLAW_STATE/hosts/<host>/key.txt" \
  "✓ dedicated yclaw keychain → $YCLAW_KEYCHAIN (unlock pw in login Keychain: $KC_SERVICE_KEYCHAIN_PASS)" \
  "✓ vault master password in yclaw keychain ($KC_SERVICE)" \
  "✓ metal admin password in yclaw keychain ($KC_SERVICE_METAL_ADMIN)" \
  "✓ bluebubbles admin password in yclaw keychain ($KC_SERVICE_BLUEBUBBLES_ADMIN)" \
  "✓ BlueBubbles server password in yclaw keychain ($KC_SERVICE_BLUEBUBBLES_SERVER)" \
  '' \
  'Reply  done  to the agent to continue the deploy.'
