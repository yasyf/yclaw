#!/usr/bin/env bash
# scripts/lib/secrets.sh — the single sourceable secrets module. Both
# scripts/collect-secrets.sh and scripts/bootstrap.sh source this and call
# `collect_secrets`, so there is exactly one path that mints the age key, prompts
# for the runtime secrets, and writes the sops-encrypted blob.
#
# ALL output lands under ~/.yclaw/state (override with $YCLAW_STATE), never the
# repo:
#   age/key.txt          private age key (also staged to vm-secrets/key.txt)
#   secrets.sops.yaml     sops/age-encrypted secrets (canonical schema below)
#   sops.yaml             resolved sops creation rules (from the committed .sops.yaml)
#   vm-secrets/key.txt    age key staged for the VMs (virtiofs mount)
#
# The vault master password is GENERATED here and stored in the login Keychain
# (service "yclaw-agent-vault-master"); retrieve it with:
#   security find-generic-password -s yclaw-agent-vault-master -w

YCLAW_STATE="${YCLAW_STATE:-$HOME/.yclaw/state}"
KC_SERVICE="yclaw-agent-vault-master"
SECRETS_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_secrets_ask()  { gum input --password --prompt "  $1 ❯ "; }
_secrets_note() { gum style --foreground 244 "  $*"; }
_secrets_ok()   { gum style --foreground 84  "  $*"; }
_secrets_fail() { gum style --foreground 196 "  $*"; exit 1; }

# Prompt for the runtime secrets, mint/reuse the age key + vault master password,
# and write the sops-encrypted blob to ~/.yclaw/state. Idempotent: reuses an
# existing age key and the Keychain-stored vault master password; re-prompts the
# API keys. The caller must run under `set -euo pipefail`.
collect_secrets() {
  local t age_key vm_key sops_out sops_rendered sops_template pub plain

  for t in sops age-keygen gum security openssl python3; do
    command -v "$t" >/dev/null || { printf 'FATAL: %s not on PATH.\n' "$t" >&2; exit 1; }
  done

  age_key="$YCLAW_STATE/age/key.txt"
  vm_key="$YCLAW_STATE/vm-secrets/key.txt"
  sops_out="$YCLAW_STATE/secrets.sops.yaml"
  sops_rendered="$YCLAW_STATE/sops.yaml"
  sops_template="$SECRETS_LIB_REPO/.sops.yaml"
  mkdir -p "$YCLAW_STATE/age" "$YCLAW_STATE/vm-secrets"
  chmod 700 "$YCLAW_STATE/age" "$YCLAW_STATE/vm-secrets"

  gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 212 \
    'yclaw · runtime secret collection' \
    'Values are read locally and sops-encrypted. Nothing is printed or sent.'

  TS_AUTHKEY="$(_secrets_ask 'Tailscale auth key (tskey-auth-…, reusable)')"
  [ -n "$TS_AUTHKEY" ] || _secrets_fail 'Tailscale auth key is required.'
  OPENAI_API_KEY="$(_secrets_ask 'OpenAI API key (sk-…)')"
  EXA_API_KEY="$(_secrets_ask 'Exa API key')"
  HONCHO_API_KEY="$(_secrets_ask 'Honcho API key')"
  # GitHub: reuse the locally-authenticated gh CLI token rather than prompting.
  if command -v gh >/dev/null && GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && [ -n "$GITHUB_TOKEN" ]; then
    _secrets_note "GitHub token sourced from gh CLI (account: $(gh api user -q .login 2>/dev/null || echo '?'))."
  else
    GITHUB_TOKEN="$(_secrets_ask 'GitHub token (ghp_… / github_pat_…)')"
  fi
  # BlueBubbles is OPTIONAL: a blank answer OMITS the hermes/env key entirely (no
  # sentinel). Consumers that need it fail loud when the key is absent.
  BLUEBUBBLES_PASSWORD="$(_secrets_ask 'BlueBubbles password (leave blank to set later off the VM)')"

  # Aperture static key: mint a random one when the operator did not supply it.
  if [ -z "${APERTURE_STATIC_KEY:-}" ]; then
    APERTURE_STATIC_KEY="$(openssl rand -hex 32)"
    _secrets_note 'Minted a random Aperture static key (openssl rand -hex 32).'
  fi

  # Vault master password: generate once, persist in the login Keychain, reuse thereafter.
  if AGENT_VAULT_MASTER_PASSWORD="$(security find-generic-password -a "$USER" -s "$KC_SERVICE" -w 2>/dev/null)"; then
    _secrets_note "Reusing vault master password from Keychain ($KC_SERVICE)."
  else
    AGENT_VAULT_MASTER_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
    AGENT_VAULT_MASTER_PASSWORD="${AGENT_VAULT_MASTER_PASSWORD:0:40}"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE" \
      -l 'yclaw agent-vault master password' -w "$AGENT_VAULT_MASTER_PASSWORD"
    _secrets_ok "Generated vault master password → Keychain ($KC_SERVICE)."
  fi

  if [ ! -s "$age_key" ]; then
    (umask 077; age-keygen -o "$age_key" 2>/dev/null)
    _secrets_ok "Minted age key → $age_key"
  fi
  pub="$(age-keygen -y "$age_key")"
  [ "${pub:0:4}" = "age1" ] || _secrets_fail 'could not derive age public key.'
  _secrets_note "age public key: $pub"

  # Render the resolved sops creation rules to state from the committed template.
  # Read fully BEFORE writing — open(w) truncates, so a one-liner would clobber it.
  python3 - "$sops_template" "$sops_rendered" "$pub" <<'PY'
import sys
src, dst, pub = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
open(dst, "w").write(s.replace("@@AGE_PUBLIC_KEY@@", pub))
PY

  export TS_AUTHKEY AGENT_VAULT_MASTER_PASSWORD OPENAI_API_KEY EXA_API_KEY \
         HONCHO_API_KEY GITHUB_TOKEN BLUEBUBBLES_PASSWORD APERTURE_STATIC_KEY
  plain="$(mktemp)"; trap 'rm -f "$plain"' EXIT
  # Built in Python so secret values are written literally (no shell/YAML interpolation).
  # The hermes block is OMITTED when BlueBubbles is unset — no sentinel placeholder.
  python3 - "$plain" <<'PY'
import os, sys, json
e = os.environ
parts = [f'tailscale:\n  authkey: {json.dumps(e["TS_AUTHKEY"])}\n']
if e["BLUEBUBBLES_PASSWORD"]:
    parts.append(f'hermes:\n  env: |\n    BLUEBUBBLES_PASSWORD={e["BLUEBUBBLES_PASSWORD"]}\n')
parts.append(
    'vault:\n'
    f'  master-password: |\n    AGENT_VAULT_MASTER_PASSWORD={e["AGENT_VAULT_MASTER_PASSWORD"]}\n'
    '  static-keys: |\n'
    f'    OPENAI_API_KEY={e["OPENAI_API_KEY"]}\n'
    f'    EXA_API_KEY={e["EXA_API_KEY"]}\n'
    f'    HONCHO_API_KEY={e["HONCHO_API_KEY"]}\n'
    f'    GITHUB_TOKEN={e["GITHUB_TOKEN"]}\n'
)
parts.append(f'aperture:\n  static-key: {json.dumps(e["APERTURE_STATIC_KEY"])}\n')
open(sys.argv[1], "w").write("".join(parts))
PY

  # --input-type/--output-type yaml are REQUIRED: the mktemp file has no .yaml extension, so
  # sops would otherwise treat it as binary and wrap the document in a `data:` blob that
  # sops-nix cannot navigate (it extracts secrets by key path like tailscale/authkey).
  sops --encrypt --input-type yaml --output-type yaml --age "$pub" "$plain" > "$sops_out"
  rm -f "$plain"; trap - EXIT
  install -m 600 "$age_key" "$vm_key"
}
