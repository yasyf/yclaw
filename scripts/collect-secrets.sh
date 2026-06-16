#!/usr/bin/env bash
# Human-only step: collect the runtime secrets, mint the age key, and write the
# sops-encrypted secrets to ~/.yclaw/state. Thin wrapper over the single secrets
# module (scripts/lib/secrets.sh); run on the host (hidden input via gum, so the
# raw secrets never leave your terminal). Idempotent: reuses an existing age key
# and the Keychain-stored vault master password.
#
# Retrieve the generated vault master password with:
#   security find-generic-password -s yclaw-agent-vault-master -w
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.nix-profile/bin:/opt/homebrew/bin:$PATH"

source "$REPO/scripts/lib/secrets.sh"
collect_secrets

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 84 \
  "✓ secrets encrypted → $YCLAW_STATE/secrets.sops.yaml" \
  "✓ age key staged for the VMs → $YCLAW_STATE/vm-secrets/key.txt" \
  "✓ vault master password in Keychain ($KC_SERVICE)" \
  '' \
  'Reply  done  to the agent to continue the deploy.'
