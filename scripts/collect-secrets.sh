#!/usr/bin/env bash
# Human-only step: collect the runtime secrets, mint the age key, and write the
# sops-encrypted secrets/secrets.sops.yaml. Run on the host (hidden input via gum, so the
# raw secrets never leave your terminal). Idempotent: reuses an existing age key and the
# Keychain-stored vault master password.
#
# The vault master password is GENERATED here and stored in the login Keychain (service
# "yclaw-agent-vault-master"); retrieve it with:
#   security find-generic-password -s yclaw-agent-vault-master -w
#
# After this completes, the deploying agent rebuilds the VM images against the real
# encrypted secrets and boots them (the age private key is shared into each VM via a tart
# virtiofs mount, never baked into the world-readable Nix store).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
export PATH="$HOME/.nix-profile/bin:/opt/homebrew/bin:$PATH"

for t in sops age-keygen gum security openssl python3; do
  command -v "$t" >/dev/null || { echo "FATAL: '$t' not on PATH."; exit 1; }
done

RUNTIME="$REPO/secrets/runtime"; mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
AGE_KEY="$RUNTIME/key.txt"
VM_SECRETS="$HOME/.config/yclaw/vm-secrets"; mkdir -p "$VM_SECRETS"; chmod 700 "$VM_SECRETS"
KC_SERVICE="yclaw-agent-vault-master"

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 212 \
  'yclaw · runtime secret collection' \
  'Values are read locally and sops-encrypted. Nothing is printed or sent.'

ask()    { gum input --password --prompt "  $1 ❯ "; }
note()   { gum style --foreground 244 "  $*"; }
ok()     { gum style --foreground 84  "  $*"; }
fail()   { gum style --foreground 196 "  $*"; exit 1; }

TS_AUTHKEY="$(ask 'Tailscale auth key (tskey-auth-…, reusable)')"
[ -n "$TS_AUTHKEY" ] || fail 'Tailscale auth key is required.'
OPENAI_API_KEY="$(ask 'OpenAI API key (sk-…)')"
EXA_API_KEY="$(ask 'Exa API key')"
HONCHO_API_KEY="$(ask 'Honcho API key')"
# GitHub: reuse the locally-authenticated gh CLI token rather than prompting.
if command -v gh >/dev/null && GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && [ -n "$GITHUB_TOKEN" ]; then
  note "GitHub token sourced from gh CLI (account: $(gh api user -q .login 2>/dev/null || echo '?'))."
else
  GITHUB_TOKEN="$(ask 'GitHub token (ghp_… / github_pat_…)')"
fi
GOOGLE_OAUTH_CLIENT_ID="$(ask 'Google Workspace OAuth client id')"
GOOGLE_OAUTH_CLIENT_SECRET="$(ask 'Google Workspace OAuth client secret')"
BLUEBUBBLES_PASSWORD="$(ask 'BlueBubbles password (leave blank to read off the VM)')"
[ -n "$BLUEBUBBLES_PASSWORD" ] || BLUEBUBBLES_PASSWORD="__PENDING_READ_FROM_VM__"

# Vault master password: generate once, persist in the login Keychain, reuse thereafter.
if AGENT_VAULT_MASTER_PASSWORD="$(security find-generic-password -a "$USER" -s "$KC_SERVICE" -w 2>/dev/null)"; then
  note "Reusing vault master password from Keychain ($KC_SERVICE)."
else
  AGENT_VAULT_MASTER_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  AGENT_VAULT_MASTER_PASSWORD="${AGENT_VAULT_MASTER_PASSWORD:0:40}"
  security add-generic-password -U -a "$USER" -s "$KC_SERVICE" \
    -l 'yclaw agent-vault master password' -w "$AGENT_VAULT_MASTER_PASSWORD"
  ok "Generated vault master password → Keychain ($KC_SERVICE)."
fi

if [ ! -s "$AGE_KEY" ]; then
  (umask 077; age-keygen -o "$AGE_KEY" 2>/dev/null)
  ok "Minted age key → $AGE_KEY"
fi
PUB="$(age-keygen -y "$AGE_KEY")"
[ "${PUB:0:4}" = "age1" ] || fail 'could not derive age public key.'
note "age public key: $PUB"

# Pin the public key into the sops creation rules (idempotent).
python3 - "$REPO/.sops.yaml" "$PUB" <<'PY'
import sys
p, pub = sys.argv[1], sys.argv[2]
open(p, "w").write(open(p).read().replace("@@AGE_PUBLIC_KEY@@", pub))
PY

export TS_AUTHKEY AGENT_VAULT_MASTER_PASSWORD OPENAI_API_KEY EXA_API_KEY \
       HONCHO_API_KEY GITHUB_TOKEN GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET BLUEBUBBLES_PASSWORD
PLAIN="$(mktemp)"; trap 'rm -f "$PLAIN"' EXIT
# Built in Python so secret values are written literally (no shell/YAML interpolation).
python3 - "$PLAIN" <<'PY'
import os, sys, json
e = os.environ
open(sys.argv[1], "w").write(f'''tailscale:
  authkey: {json.dumps(e["TS_AUTHKEY"])}
hermes:
  env: |
    BLUEBUBBLES_PASSWORD={e["BLUEBUBBLES_PASSWORD"]}
vault:
  master-password: |
    AGENT_VAULT_MASTER_PASSWORD={e["AGENT_VAULT_MASTER_PASSWORD"]}
  static-keys: |
    OPENAI_API_KEY={e["OPENAI_API_KEY"]}
    EXA_API_KEY={e["EXA_API_KEY"]}
    HONCHO_API_KEY={e["HONCHO_API_KEY"]}
    GITHUB_TOKEN={e["GITHUB_TOKEN"]}
  google-oauth: |
    GOOGLE_OAUTH_CLIENT_ID={e["GOOGLE_OAUTH_CLIENT_ID"]}
    GOOGLE_OAUTH_CLIENT_SECRET={e["GOOGLE_OAUTH_CLIENT_SECRET"]}
''')
PY

sops --encrypt --age "$PUB" "$PLAIN" > "$REPO/secrets/secrets.sops.yaml"
rm -f "$PLAIN"; trap - EXIT
install -m 600 "$AGE_KEY" "$VM_SECRETS/key.txt"

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 84 \
  '✓ secrets/secrets.sops.yaml encrypted' \
  "✓ age key staged for the VMs at $VM_SECRETS/key.txt" \
  "✓ vault master password in Keychain ($KC_SERVICE)" \
  '' \
  'Reply  done  to the agent to continue the deploy.'
