#!/usr/bin/env bash
# Human-only step: prompt for the runtime secrets, mint the age key, and write the
# sops-encrypted secrets/secrets.sops.yaml. Run this on the host (it reads hidden input,
# so the raw secrets never leave your terminal). Idempotent: reuses an existing age key.
#
# After this completes, the deploying agent rebuilds the VM images against the real
# encrypted secrets and boots them (the age private key is shared into each VM via a
# tart virtiofs mount, NOT baked into the world-readable Nix store).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
export PATH="$HOME/.nix-profile/bin:$PATH"

command -v sops       >/dev/null || { echo "FATAL: sops not on PATH (nix profile install nixpkgs#sops)"; exit 1; }
command -v age-keygen >/dev/null || { echo "FATAL: age-keygen not on PATH (nix profile install nixpkgs#age)"; exit 1; }

RUNTIME="$REPO/secrets/runtime"; mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
AGE_KEY="$RUNTIME/key.txt"
VM_SECRETS="$HOME/.config/yclaw/vm-secrets"; mkdir -p "$VM_SECRETS"; chmod 700 "$VM_SECRETS"

ask() { local var="$1" desc="$2" v; read -rsp "  $desc: " v; echo; printf -v "$var" '%s' "$v"; }

echo "Runtime secrets (input hidden). Leave BlueBubbles blank to read it off the VM later."
ask TS_AUTHKEY                 "Tailscale auth key (tskey-auth-...)"
ask AGENT_VAULT_MASTER_PASSWORD "agent-vault master password (choose one)"
ask OPENAI_API_KEY             "OpenAI API key (sk-...)"
ask EXA_API_KEY                "Exa API key"
ask HONCHO_API_KEY             "Honcho API key"
ask GITHUB_TOKEN               "GitHub token (ghp_.../github_pat_...)"
ask GOOGLE_OAUTH_CLIENT_ID     "Google Workspace OAuth client id"
ask GOOGLE_OAUTH_CLIENT_SECRET "Google Workspace OAuth client secret"
ask BLUEBUBBLES_PASSWORD       "BlueBubbles password (blank = read off VM)"
[ -n "${TS_AUTHKEY}" ] || { echo "FATAL: Tailscale auth key is required."; exit 1; }
[ -n "${AGENT_VAULT_MASTER_PASSWORD}" ] || { echo "FATAL: vault master password is required."; exit 1; }
[ -n "${BLUEBUBBLES_PASSWORD}" ] || BLUEBUBBLES_PASSWORD="__PENDING_READ_FROM_VM__"

if [ ! -s "$AGE_KEY" ]; then
  echo "Minting age key at $AGE_KEY ..."
  (umask 077; age-keygen -o "$AGE_KEY" 2>/dev/null)
fi
PUB="$(age-keygen -y "$AGE_KEY")"
[ "${PUB:0:4}" = "age1" ] || { echo "FATAL: could not derive age public key."; exit 1; }
echo "age public key: $PUB"

# Pin the public key into the sops creation rules (idempotent).
python3 - "$REPO/.sops.yaml" "$PUB" <<'PY'
import sys
p, pub = sys.argv[1], sys.argv[2]
open(p, "w").write(open(p).read().replace("@@AGE_PUBLIC_KEY@@", pub))
PY

export TS_AUTHKEY AGENT_VAULT_MASTER_PASSWORD OPENAI_API_KEY EXA_API_KEY \
       HONCHO_API_KEY GITHUB_TOKEN GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET BLUEBUBBLES_PASSWORD
PLAIN="$(mktemp)"; trap 'rm -f "$PLAIN"' EXIT
# Build the plaintext YAML in Python so secret values are written literally (no shell/YAML
# interpolation). authkey is a JSON-quoted scalar (no trailing newline); the EnvironmentFile
# secrets are block scalars (systemd parses NAME=value lines).
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

# Stage the age private key where the tart virtiofs mount picks it up for the VMs.
install -m 600 "$AGE_KEY" "$VM_SECRETS/key.txt"

echo
echo "OK: secrets/secrets.sops.yaml encrypted; age key staged at $VM_SECRETS/key.txt."
echo "Tell the agent it's done."
