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

YCLAW_STATE="${YCLAW_STATE:-$HOME/.yclaw/state}"
YCLAW_KEYCHAIN="$HOME/Library/Keychains/yclaw.keychain-db"
KC_SERVICE_KEYCHAIN_PASS="yclaw-keychain-password"
KC_SERVICE="yclaw-agent-vault-master"
KC_SERVICE_METAL_ADMIN="yclaw-metal-admin-pass"
KC_SERVICE_BLUEBUBBLES_ADMIN="yclaw-bluebubbles-admin-pass"
KC_SERVICE_BLUEBUBBLES_SERVER="yclaw-bluebubbles-server-pass"
SECRETS_LIB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_secrets_ask()  { gum input --password --prompt "  $1 ❯ "; }
_secrets_note() { gum style --foreground 244 "  $*"; }
_secrets_ok()   { gum style --foreground 84  "  $*"; }
_secrets_fail() { gum style --foreground 196 "  $*"; exit 1; }

# Ensure the dedicated yclaw keychain exists and is unlocked. On first run it is created with
# a freshly-generated unlock password that is persisted in the LOGIN keychain under
# `yclaw-keychain-password`; thereafter the unlock password is read back from the login
# keychain and used to unlock the dedicated keychain non-interactively. set-keychain-settings
# (no -t) disables the auto-lock timeout so the keychain stays unlocked for the run. Call this
# before any yclaw-secret access.
_yclaw_keychain_unlock() {
  local kc_pass
  if [ ! -f "$YCLAW_KEYCHAIN" ]; then
    kc_pass="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    security create-keychain -p "$kc_pass" "$YCLAW_KEYCHAIN"
    security set-keychain-settings "$YCLAW_KEYCHAIN"
    security add-generic-password -U -a "$USER" -s "$KC_SERVICE_KEYCHAIN_PASS" \
      -l 'yclaw dedicated keychain unlock password' -w "$kc_pass"
    _secrets_ok "Created dedicated yclaw keychain → $YCLAW_KEYCHAIN (unlock pw → login Keychain $KC_SERVICE_KEYCHAIN_PASS)."
  fi
  kc_pass="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_KEYCHAIN_PASS" -w)"
  security unlock-keychain -p "$kc_pass" "$YCLAW_KEYCHAIN"
}

# Prompt for the external API secrets, generate/reuse the age key + the dedicated-keychain
# passwords (vault master, the two per-VM admin passwords, BlueBubbles server), and write the
# sops-encrypted blob to ~/.yclaw/state. Idempotent: reuses an existing age key and the
# yclaw-keychain-stored passwords; re-prompts the external API keys. The caller must run under
# `set -euo pipefail`.
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
  # Aperture static key: mint a random one when the operator did not supply it.
  if [ -z "${APERTURE_STATIC_KEY:-}" ]; then
    APERTURE_STATIC_KEY="$(openssl rand -hex 32)"
    _secrets_note 'Minted a random Aperture static key (openssl rand -hex 32).'
  fi

  # Every yclaw password lives in the dedicated yclaw keychain — ensure it exists and is
  # unlocked before any generate-or-reuse below.
  _yclaw_keychain_unlock

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
         HONCHO_API_KEY GITHUB_TOKEN BLUEBUBBLES_PASSWORD APERTURE_STATIC_KEY \
         METAL_ADMIN_PASS BLUEBUBBLES_ADMIN_PASS
  plain="$(mktemp)"; trap 'rm -f "$plain"' EXIT
  # Built in Python so secret values are written literally (no shell/YAML interpolation).
  # BLUEBUBBLES_PASSWORD is always generated above, so the hermes/env block is always rendered.
  python3 - "$plain" <<'PY'
import os, sys, json
e = os.environ
parts = [f'tailscale:\n  authkey: {json.dumps(e["TS_AUTHKEY"])}\n']
parts.append(
    'hermes:\n  env: |\n'
    f'    BLUEBUBBLES_PASSWORD={e["BLUEBUBBLES_PASSWORD"]}\n'
    # hermes bypasses Aperture and hits cliproxy on metal:8317 directly, so it must present
    # the same static bearer Aperture used to inject (model.key_env=APERTURE_STATIC_KEY).
    f'    APERTURE_STATIC_KEY={e["APERTURE_STATIC_KEY"]}\n'
)
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
