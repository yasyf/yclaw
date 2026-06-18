#!/usr/bin/env bash
# Single entrypoint for `just bootstrap`: the de-Nix'd onboarding wizard. Prompts for the
# non-secret values, mints the age key + sops-encrypts the secrets (scripts/lib/secrets.sh),
# assembles the hermes node-config share, applies the host config, builds ALL THREE guest
# images (metal + bluebubbles via packer, hermes via the linux-builder VM), then prints the
# human gates and stops cleanly.
#
# Idempotent: re-running prompts only for still-unset values, reuses the age key + the
# yclaw-keychain passwords, and rebuilds images in place. Real secrets never touch a commit or
# the Nix store — env-specifics flow via bare Tailscale MagicDNS names (baked-generic images),
# the runtime node.env share, sops, and PKR_VAR_* exports.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RUNTIME_DIR="$REPO_ROOT/secrets/runtime"
VALUES_FILE="$RUNTIME_DIR/values.env"            # resolved non-secret values; gitignored

# The hermes node-config share source: setup.sh mounts this dir into the hermes guest as the
# virtiofs `sops` tag, and common.nix's seedNodeConfig installs key.txt → /var/lib/sops-nix,
# secrets.sops.yaml + node.env (+ agent-vault-ca.pem) → /var/lib/node-config on first boot.
NODE_CONFIG_DIR="$HOME/.config/yclaw/vm-secrets"

# Gitignored build copy of the repo. The hermes image bakes nixos/agent-vault-ca.pem, whose
# REAL value is fetched from metal at run time — so the hermes build runs from this copy with
# the fetched CA written in, never dirtying the tracked tree.
BUILD_DIR="$REPO_ROOT/.build"

# The dirs `nix flake check` / a rebuild evaluates — where a stray @@TAILNET_DOMAIN@@ would break
# the GENERIC image. Post-Stage-B every config uses bare MagicDNS names, so this guard must pass.
GENERIC_TREE=(nixos darwin)

# --- helpers -----------------------------------------------------------------

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bootstrap] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not on PATH (install it, then re-run)."
}

# Read a value into the named global. Skips the prompt if already set in the environment.
prompt_var() {
  local name="$1" desc="$2" secret="${3:-no}" current="${!1:-}"
  if [[ -n "$current" ]]; then return; fi
  if [[ "$secret" == "secret" ]]; then
    read -rsp "  $name ($desc): " "$name"; echo
  else
    read -rp "  $name ($desc): " "$name"
  fi
  [[ -n "${!name}" ]] || die "$name is required and was left empty."
}

# --- 0. preflight ------------------------------------------------------------

need age-keygen
need sops
need openssl
need jq
need gum
need python3
need tart
need packer
need security
need rsync
need curl
need rg               # the genericity guard below scans the config tree with ripgrep
need nix              # hermes image: build-hermes-image.sh drives nix inside a linux builder VM
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# --- 1. collect non-secret values --------------------------------------------

log "Resolving non-secret values (secrets come in step 2)..."

# Tailnet domain: auto-detect from the host's own tailnet membership, else prompt. Used only for
# the human-gate URLs printed at the end — the configs themselves use bare MagicDNS names.
if [[ -z "${TAILNET_DOMAIN:-}" ]]; then
  TAILNET_DOMAIN="$(tailscale status --json 2>/dev/null | jq -re '.MagicDNSSuffix' || true)"
  [[ -n "$TAILNET_DOMAIN" ]] && log "Auto-detected TAILNET_DOMAIN=$TAILNET_DOMAIN from tailscale status."
fi
prompt_var TAILNET_DOMAIN "MagicDNS suffix, e.g. tailXXXX.ts.net"

# GitHub owner: derive from the repo's origin remote (owner of git@github.com:OWNER/yclaw.git or
# https://github.com/OWNER/yclaw.git), else prompt. The packer builds clone this fork.
if [[ -z "${GITHUB_OWNER:-}" ]]; then
  origin="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
  GITHUB_OWNER="$(printf '%s' "$origin" | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#/[^/]+(\.git)?$##')"
  [[ -n "$GITHUB_OWNER" && "$GITHUB_OWNER" != "$origin" ]] \
    && log "Derived GITHUB_OWNER=$GITHUB_OWNER from remote.origin.url." \
    || GITHUB_OWNER=""
fi
prompt_var GITHUB_OWNER "GitHub owner whose yclaw fork the guests clone"

# IPSW URL: the pinned macOS Tahoe restore image the metal packer build installs from. Reachability
# is a warn, not a hard fail — the URL may be a local path or require auth headers packer supplies.
prompt_var IPSW_URL "pinned macOS Tahoe IPSW (URL or local path) for the metal build"
if [[ "$IPSW_URL" == http*://* ]]; then
  curl -fsI --max-time 15 "$IPSW_URL" >/dev/null 2>&1 \
    && log "IPSW_URL is reachable." \
    || log "WARNING: IPSW_URL not reachable (HEAD failed) — continuing; packer will fail loud if it is wrong."
fi

prompt_var HOST_RAM "host RAM tier in GB, for VM sizing"
prompt_var AUTHORIZED_HANDLES "iMessage allowlist (comma-separated handles; first is the home channel)"

# --- 2. age key + sops-encrypted secrets (single secrets module) -------------

# scripts/lib/secrets.sh is the ONE path that prompts for secrets, mints/reuses a per-host age
# keypair, mints the Aperture static key, the per-VM admin passwords, and the BlueBubbles server
# password into the dedicated yclaw keychain, renders ~/.yclaw/state/sops.yaml, and writes one
# encrypted per-host bundle at ~/.yclaw/state/hosts/<host>/secrets.sops.yaml (each scoped to only
# that host's manifest secrets). Real secrets never touch the repo. Sourcing it also exposes
# YCLAW_KEYCHAIN + the KC_SERVICE_* names used by the packer builds below.
source "$REPO_ROOT/scripts/lib/secrets.sh"
collect_secrets

# Record the resolved non-secret values so `just deploy <node>` re-runs reproduce them.
( umask 077; : > "$VALUES_FILE" )
for tok in TAILNET_DOMAIN GITHUB_OWNER IPSW_URL HOST_RAM AUTHORIZED_HANDLES; do
  printf '%s=%s\n' "$tok" "${!tok}" >> "$VALUES_FILE"
done

# --- 3. assemble the hermes node-config share --------------------------------

# seedNodeConfig (nixos/common.nix) reads key.txt + secrets.sops.yaml (REQUIRED) and node.env +
# agent-vault-ca.pem (OPTIONAL) from this share on first boot. node.env carries the per-user,
# NON-SECRET BlueBubbles wiring: the allowlist, the home channel (the first handle), and the two
# endpoints that must be the node FQDN rather than a bare MagicDNS name — the BlueBubbles server
# URL (tailscale-serve's TLS cert is FQDN-only) and the webhook host (bare `hermes` resolves to
# 127.0.0.2 via /etc/hosts, binding the webhook to loopback). node.env overrides hermesEnvFile.
log "Assembling hermes node-config share at $NODE_CONFIG_DIR ..."
install -d -m 700 "$NODE_CONFIG_DIR"
install -m 600 "$HOME/.yclaw/state/hosts/hermes/key.txt"           "$NODE_CONFIG_DIR/key.txt"
install -m 600 "$HOME/.yclaw/state/hosts/hermes/secrets.sops.yaml" "$NODE_CONFIG_DIR/secrets.sops.yaml"

BLUEBUBBLES_HOME_CHANNEL="${AUTHORIZED_HANDLES%%,*}"
( umask 077
  cat > "$NODE_CONFIG_DIR/node.env" <<EOF
BLUEBUBBLES_ALLOWED_USERS=$AUTHORIZED_HANDLES
BLUEBUBBLES_HOME_CHANNEL=$BLUEBUBBLES_HOME_CHANNEL
BLUEBUBBLES_SERVER_URL=https://bluebubbles.$TAILNET_DOMAIN
BLUEBUBBLES_WEBHOOK_HOST=hermes.$TAILNET_DOMAIN
EOF
)
chmod 644 "$NODE_CONFIG_DIR/node.env"

# --- 4. genericity guard: no @@TAILNET_DOMAIN@@ may survive in the configs ----

# Post-Stage-B every nixos/ + darwin/ config uses bare Tailscale MagicDNS names (metal,
# bluebubbles, hermes). A surviving @@TAILNET_DOMAIN@@ would bake the literal placeholder into
# the generic image — the exact defect this stage fixes. Fail loud if any remain.
# rg exits 1 when nothing matches (the pass case) and >=2 on a real scan error — distinguish
# them so a broken scan fails loud instead of silently "passing" (rg is preflighted above).
set +e
RESIDUE="$(rg -n '@@TAILNET_DOMAIN@@' "${GENERIC_TREE[@]}")"
rc=$?
set -e
[[ "$rc" -le 1 ]] || die "genericity guard: rg failed (exit $rc) scanning ${GENERIC_TREE[*]}"
if [[ -n "$RESIDUE" ]]; then
  die $'@@TAILNET_DOMAIN@@ survives in the generic config tree (must be bare MagicDNS post-Stage-B):\n'"$RESIDUE"
fi
log "Genericity guard passed: no @@TAILNET_DOMAIN@@ in ${GENERIC_TREE[*]}."

# --- 5. apply the host config ------------------------------------------------

log "Applying host config: ./scripts/setup.sh ..."
./scripts/setup.sh

# --- 6. build the macOS guest images (metal + bluebubbles) via packer --------

# The yclaw keychain holds the per-VM admin passwords; unlock it once, then feed packer its
# inputs as PKR_VAR_* env exports (NOT in-tree @@token@@ substitution). vm_admin_user is always
# `admin` to match darwin/metal.nix's primaryUser. repo_url is left empty so the packer locals
# fall back to https://github.com/$GITHUB_OWNER/yclaw.git.
_yclaw_keychain_unlock

build_macos_image() {
  local node="$1" admin_service="$2" pkr_file="$3" admin_pass
  admin_pass="$(security find-generic-password -a "$USER" -s "$admin_service" -w "$YCLAW_KEYCHAIN")"
  [[ -n "$admin_pass" ]] || die "no $admin_service in $YCLAW_KEYCHAIN — collect_secrets should have generated it."
  log "Building $node image via packer ($pkr_file) ..."
  PKR_VAR_ipsw_url="$IPSW_URL" \
  PKR_VAR_github_owner="$GITHUB_OWNER" \
  PKR_VAR_vm_admin_user="admin" \
  PKR_VAR_vm_admin_pass="$admin_pass" \
  PKR_VAR_repo_url="" \
    packer init "$REPO_ROOT/packer/$pkr_file"
  PKR_VAR_ipsw_url="$IPSW_URL" \
  PKR_VAR_github_owner="$GITHUB_OWNER" \
  PKR_VAR_vm_admin_user="admin" \
  PKR_VAR_vm_admin_pass="$admin_pass" \
  PKR_VAR_repo_url="" \
    packer build "$REPO_ROOT/packer/$pkr_file"
}

build_macos_image metal       "$KC_SERVICE_METAL_ADMIN"       metal.pkr.hcl
build_macos_image bluebubbles "$KC_SERVICE_BLUEBUBBLES_ADMIN" bluebubbles.pkr.hcl

# Boot the freshly-built macOS guests now that their disks exist. setup.sh (step 5) loaded the
# com.yclaw.tart-* agents before the images were built, so KeepAlive would eventually boot them —
# but the CA fetch below needs metal up + agent-vault provisioned, so kickstart it explicitly.
for node in metal bluebubbles; do
  launchctl kickstart -k "gui/$(id -u)/com.yclaw.tart-$node" 2>/dev/null \
    || log "  (agent com.yclaw.tart-$node not loaded yet; ./scripts/setup.sh bootstraps it)"
done

# --- 7. build the hermes image with the REAL agent-vault CA ------------------

# hermes trusts the agent-vault MITM CA (security.pki.certificateFiles → nixos/agent-vault-ca.pem).
# The CA is generated by agent-vault on metal, so fetch it AFTER metal is up, write it into a
# gitignored build copy of the repo, and build hermes from there — the tracked tree stays clean.
log "Fetching agent-vault MITM CA from metal (waiting for metal:14321) ..."
CA_PEM=""
for _ in $(seq 1 60); do
  CA_PEM="$(curl -fsS --max-time 10 http://metal:14321/v1/mitm/ca.pem 2>/dev/null || true)"
  [[ "$CA_PEM" == *"BEGIN CERTIFICATE"* ]] && break
  sleep 5
done
[[ "$CA_PEM" == *"BEGIN CERTIFICATE"* ]] \
  || die "could not fetch the agent-vault CA from http://metal:14321/v1/mitm/ca.pem — is metal up and agent-vault running?"

log "Staging gitignored build copy at $BUILD_DIR ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rsync -a --exclude '.git' --exclude '.build' --exclude 'result' --exclude 'result-*' "$REPO_ROOT/" "$BUILD_DIR/"
printf '%s' "$CA_PEM" > "$BUILD_DIR/nixos/agent-vault-ca.pem"

log "Building hermes image from the build copy ..."
YCLAW_BUILD_DIR="$BUILD_DIR" ./scripts/build-hermes-image.sh

# Disk-replace the freshly built hermes image into its tart VM (mirrors deploy-vm.sh).
HERMES_IMG="$BUILD_DIR/result-hermes/nixos.img"
[[ -f "$HERMES_IMG" ]] || die "hermes build finished but $HERMES_IMG is missing."
if ! tart list --format json 2>/dev/null | jq -re '.[]? | select(.Name=="hermes")' >/dev/null; then
  log "Creating tart Linux scaffold for hermes (64 GB) ..."
  tart create --linux hermes --disk-size 64
fi
log "Disk-replacing hermes (APFS clonefile) ..."
cp -c "$HERMES_IMG" "$HOME/.tart/vms/hermes/disk.img"
tart set hermes --disk-size 64   # grow the record so NixOS autoResize extends the FS

# --- 8. (re)load the launchd agents ------------------------------------------

# metal + bluebubbles were booted in step 6; kickstart hermes now that its disk is in place.
log "Reloading launchd agent com.yclaw.tart-hermes ..."
launchctl kickstart -k "gui/$(id -u)/com.yclaw.tart-hermes" 2>/dev/null \
  || log "  (agent com.yclaw.tart-hermes not yet loaded — ./scripts/setup.sh bootstraps it on next run)"

# --- 8b. hermes onboarding (identity + Honcho peer) --------------------------

# Seed the identity yclaw's declarative provisioning can't: USER.md (profile) + SOUL.md
# (persona), then the Honcho peer identity. Honcho itself is configured declaratively
# (remote cloud — see nixos/hermes.nix), so this only fills user-specific gaps. Runs as
# the hermes user (sudo) so writes get service-correct ownership; admin is passwordless
# wheel. Idempotent. If hermes isn't reachable yet, print the one-liner instead of blocking.
ONBOARD_CMD="tailscale ssh -t admin@hermes -- sudo -u hermes -H hermes-onboard"
log "Waiting for hermes to be reachable for onboarding (tailscale ssh admin@hermes) ..."
hermes_up=0
for _ in $(seq 1 60); do
  if tailscale ssh admin@hermes -- true 2>/dev/null; then hermes_up=1; break; fi
  sleep 5
done
if [[ "$hermes_up" == 1 ]]; then
  log "Launching hermes onboarding (interactive) ..."
  $ONBOARD_CMD || log "  (onboarding exited non-zero; re-run any time: $ONBOARD_CMD)"
else
  log "  hermes not reachable yet — skipping auto-onboarding. Run it once hermes is up:"
  log "    $ONBOARD_CMD"
fi

# --- 9. human gates ----------------------------------------------------------

cat <<EOF

================================================================================
  HUMAN GATES — these cannot be scripted. Do them in order, then verify.
================================================================================

  [ ] 1. Apple-ID iMessage sign-in (2FA) on the bluebubbles VM.
         Sign in with the dedicated Apple ID, complete 2FA, enable iMessage,
         then run scripts/bluebubbles-setup.sh on the bluebubbles VM.

  [ ] 2. CLIProxyAPI Codex login (metal, one-time browser flow):
           cli-proxy-api --codex-login          # ChatGPT subscription account

  [ ] 3. CLIProxyAPI Gemini login (metal, one-time browser flow):
           cli-proxy-api --login                 # NOTE: flag is --login, NOT --gemini-login
                                                 # personal Google (free Code Assist)

  [ ] 4. agent-vault Google OAuth connect (run on the host):
           ./scripts/connect-google-oauth.py
         Open the printed CONSENT_URL, approve, and it finishes + verifies.

  [ ] 5. Place the Qwen MLX model on metal:
           hf download $(rg -o 'qwen = "[^"]+"' nixos/models.nix | sed -E 's/qwen = "(.*)"/\1/')
         into the host's ~/.yclaw/state/hf (metal mounts it as the narrow `hf` share at
         /Volumes/My Shared Files/hf, which the omlx wrapper sets as HF_HOME).

================================================================================
  Bootstrap finished the autonomous steps. Stopping cleanly at the gates above.
================================================================================
EOF

log "Done."
