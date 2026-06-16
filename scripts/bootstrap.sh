#!/usr/bin/env bash
# Single entrypoint for `just bootstrap`: prompt for placeholders, mint the age key and
# encrypt secrets, resolve every @@TOKEN@@ in the apply-time tree, build + boot the VMs,
# load the launchd agents, then print the human gates and stop cleanly.
#
# Idempotent: re-running prompts only for still-unset values, regenerates the age key only
# when absent, and re-applies the flake. Real secrets never touch a commit or the Nix store.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RUNTIME_DIR="$REPO_ROOT/secrets/runtime"
AGE_KEY_FILE="$RUNTIME_DIR/key.txt"            # private age key; gitignored, never committed
VALUES_FILE="$RUNTIME_DIR/values.env"          # resolved non-secret tokens; gitignored
SOPS_FILE="$REPO_ROOT/secrets/secrets.sops.yaml"
SOPS_RULES="$REPO_ROOT/.sops.yaml"
HOST_AGE_KEY="/var/lib/sops-nix/key.txt"       # where sops-nix expects the private key on the host

# The apply tree: everything `nix flake check` / a rebuild evaluates. Substitution and the
# residue guard both operate over this. Docs and the secrets template are excluded.
APPLY_TREE=(flake.nix nixos darwin pkgs .sops.yaml)

# Non-secret tokens substituted literally into the apply tree wherever they appear (config
# values + comment mentions alike — the value is the same). Rendered to the world-readable
# Nix store, so none of these is a secret. AGE_PUBLIC_KEY is generated, not prompted.
NONSECRET_TOKENS=(TAILNET_DOMAIN HOST_NAME HOST_USER HOST_RAM APERTURE_STATIC_KEY AUTHORIZED_HANDLES)

# Secret tokens prompted here and written ONLY into the sops-encrypted blob, never the tree.
# Their NAMES still appear in apply-tree comments (e.g. nixos/common.nix references
# @@TS_AUTHKEY@@) — those are documentation and are exempted from the residue guard below.
SECRET_TOKENS=(
  TS_AUTHKEY
  BLUEBUBBLES_PASSWORD
  AGENT_VAULT_MASTER_PASSWORD
  OPENAI_API_KEY
  EXA_API_KEY
  HONCHO_API_KEY
  GITHUB_TOKEN
  GOOGLE_OAUTH_CLIENT_ID
  GOOGLE_OAUTH_CLIENT_SECRET
)

# Tokens left UNRESOLVED on purpose: human-gate placeholders the residue guard must tolerate.
# The CA pem is fetched post-apply (human gate 6); the secret-name mentions in comments stay as docs.
# (terminal.docker_image now has a concrete default pinned in nixos/hermes.nix, so it is no longer
#  a placeholder — bootstrap leaves it alone.)
GUARD_EXEMPT_TOKENS=(
  "${SECRET_TOKENS[@]}"
  AGENT_VAULT_CA_PEM
)

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

# Replace every @@TOKEN@@ in a file with a literal value. Per-token (not envsubst): an
# unknown @@OTHER@@ is left untouched so the residue guard catches it instead of blanking it.
# bash `${var//pat/repl}` treats `&` in the replacement as the matched text, so escape it.
subst_token() {
  local file="$1" token="$2" value="$3" body
  value="${value//&/\\&}"
  body="$(cat "$file")"
  printf '%s' "${body//@@${token}@@/$value}" > "$file"
}

# --- 0. preflight ------------------------------------------------------------

need age-keygen
need sops
need openssl
need jq
need darwin-rebuild
need nix
need tart
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# --- 1. collect values -------------------------------------------------------

log "Resolving placeholder values (blank prompts are required; secrets are hidden)..."

# Tailnet domain: auto-detect from the host's own tailnet membership, else prompt.
if [[ -z "${TAILNET_DOMAIN:-}" ]]; then
  TAILNET_DOMAIN="$(tailscale status --json 2>/dev/null | jq -re '.MagicDNSSuffix' || true)"
  if [[ -n "$TAILNET_DOMAIN" ]]; then
    log "Auto-detected TAILNET_DOMAIN=$TAILNET_DOMAIN from tailscale status."
  fi
fi
prompt_var TAILNET_DOMAIN "MagicDNS suffix, e.g. tailXXXX.ts.net"
prompt_var HOST_NAME "this Mac's hostname (targets darwin/host.nix)"
prompt_var HOST_USER "the macOS login user that runs the launchd agents"
prompt_var HOST_RAM  "host RAM tier in GB, for VM sizing"
prompt_var AUTHORIZED_HANDLES "iMessage allowlist (comma-separated handles/groups)"

# Aperture static key: mint a random one if the operator did not supply it.
if [[ -z "${APERTURE_STATIC_KEY:-}" ]]; then
  APERTURE_STATIC_KEY="$(openssl rand -hex 32)"
  log "Minted a random APERTURE_STATIC_KEY (openssl rand -hex 32)."
fi

prompt_var TS_AUTHKEY "Tailscale auth key (reusable/ephemeral) for VM join" secret
prompt_var BLUEBUBBLES_PASSWORD "BlueBubbles server password" secret
prompt_var AGENT_VAULT_MASTER_PASSWORD "agent-vault vault encryption password" secret
prompt_var OPENAI_API_KEY "OpenAI API key (image-gen + vision)" secret
prompt_var EXA_API_KEY "Exa web-search API key" secret
prompt_var HONCHO_API_KEY "Honcho memory API key" secret
prompt_var GITHUB_TOKEN "GitHub PAT" secret
prompt_var GOOGLE_OAUTH_CLIENT_ID "Google Cloud Web OAuth client id" secret
prompt_var GOOGLE_OAUTH_CLIENT_SECRET "Google Cloud Web OAuth client secret" secret

# --- 2. age key + sops-encrypted secrets ------------------------------------

if [[ ! -s "$AGE_KEY_FILE" ]]; then
  log "Generating age key at $AGE_KEY_FILE ..."
  (umask 077; age-keygen -o "$AGE_KEY_FILE" 2>/dev/null)
fi
AGE_PUBLIC_KEY="$(age-keygen -y "$AGE_KEY_FILE")"
[[ "$AGE_PUBLIC_KEY" == age1* ]] || die "could not derive an age public key from $AGE_KEY_FILE."
log "age public key: $AGE_PUBLIC_KEY"

# Stage the private key where sops-nix reads it on this host (its VM counterpart is seeded
# out-of-band per node). Needs root; the admin user has passwordless sudo.
if [[ ! -s "$HOST_AGE_KEY" ]]; then
  log "Installing private age key to $HOST_AGE_KEY (sops-nix key path) ..."
  sudo install -D -m 600 "$AGE_KEY_FILE" "$HOST_AGE_KEY"
fi

# Pin the public key into the sops creation rules so re-encryption targets this recipient.
if rg -q '@@AGE_PUBLIC_KEY@@' "$SOPS_RULES"; then
  log "Writing age public key into $SOPS_RULES ..."
  subst_token "$SOPS_RULES" AGE_PUBLIC_KEY "$AGE_PUBLIC_KEY"
fi

log "Building and encrypting $SOPS_FILE from the prompted secrets ..."
PLAIN_SOPS="$(mktemp -t hermes-secrets.XXXXXX.yaml)"
trap 'rm -f "$PLAIN_SOPS"' EXIT
cat > "$PLAIN_SOPS" <<EOF
tailscale:
  authkey: "$TS_AUTHKEY"
hermes:
  env: |
    BLUEBUBBLES_PASSWORD=$BLUEBUBBLES_PASSWORD
vault:
  master-password: "$AGENT_VAULT_MASTER_PASSWORD"
  static-keys: |
    OPENAI_API_KEY=$OPENAI_API_KEY
    EXA_API_KEY=$EXA_API_KEY
    HONCHO_API_KEY=$HONCHO_API_KEY
    GITHUB_TOKEN=$GITHUB_TOKEN
  google-oauth: |
    GOOGLE_OAUTH_CLIENT_ID=$GOOGLE_OAUTH_CLIENT_ID
    GOOGLE_OAUTH_CLIENT_SECRET=$GOOGLE_OAUTH_CLIENT_SECRET
EOF
sops --encrypt --age "$AGE_PUBLIC_KEY" "$PLAIN_SOPS" > "$SOPS_FILE"
rm -f "$PLAIN_SOPS"; trap - EXIT
log "Encrypted secrets written to $SOPS_FILE."

# --- 3. resolve non-secret @@TOKEN@@ placeholders across the apply tree -------

# Record the resolved non-secret values so `just deploy <node>` re-runs reproduce them.
( umask 077; : > "$VALUES_FILE" )
for tok in "${NONSECRET_TOKENS[@]}"; do
  printf '%s=%s\n' "$tok" "${!tok}" >> "$VALUES_FILE"
done

# Substitute every non-secret token in every apply-tree file that mentions it. A token's
# value is identical whether it sits in a config string or a comment, so a blanket sweep is
# correct; unknown @@OTHER@@ tokens survive (subst_token is per-known-token) for the guard.
log "Resolving non-secret placeholders across: ${APPLY_TREE[*]} ..."
mapfile -t SUBST_FILES < <(rg -l '@@[A-Z0-9_]+@@' "${APPLY_TREE[@]}" -g '!**/secrets.sops.yaml' 2>/dev/null || true)
for f in "${SUBST_FILES[@]}"; do
  for tok in "${NONSECRET_TOKENS[@]}"; do
    subst_token "$f" "$tok" "${!tok}"
  done
done

# --- 4. fail-loud guard: no UNEXPECTED @@TOKEN@@ may reach a nix apply --------

# Build an alternation of the tokens that are EXEMPT (secrets named only in comments +
# undecided/human-gate placeholders), then flag any @@TOKEN@@ that is NOT one of them.
exempt_alt="$(IFS='|'; printf '%s' "${GUARD_EXEMPT_TOKENS[*]}")"
RESIDUE="$(rg -no "@@[A-Z0-9_]+@@" "${APPLY_TREE[@]}" \
  -g '!**/secrets.sops.yaml' 2>/dev/null \
  | rg -v "@@(${exempt_alt})@@" || true)"
if [[ -n "$RESIDUE" ]]; then
  die $'unexpected unresolved @@TOKEN@@ before nix apply (not a known secret/undecided token):\n'"$RESIDUE"
fi
log "Placeholder guard passed: only known secret/undecided @@TOKEN@@ remain in the apply tree."

# --- 5. apply the host config ------------------------------------------------

log "Applying host config: darwin-rebuild switch --flake .#host ..."
darwin-rebuild switch --flake "$REPO_ROOT#host"

# --- 6. build raw-efi images + disk-replace into tart (tart-nixos-darwin.md §5) ---

# TODO(human): the aarch64-linux build host is undecided (tart spec §1.2 BLOCKER). These
#   `nix build` invocations assume a reachable aarch64-linux builder (nix.linux-builder VM,
#   the VM itself, or a remote builder). Wire the chosen builder into nix.conf before this
#   step, or the image builds fail. Until decided, the loop below builds from the flake.
build_and_replace() {
  local node="$1" image_attr="$2" disk_gb="${3:-64}"
  log "Building $image_attr ..."
  local img
  img="$(nix build --no-link --print-out-paths "$REPO_ROOT#packages.aarch64-linux.$image_attr")/nixos.img"
  # TODO(human): confirm the raw-efi result filename is nixos.img (tart spec §1.4) before trusting this.
  [[ -f "$img" ]] || die "expected raw-efi image at $img — check the nixos-generators result layout."

  if ! tart list --format json 2>/dev/null | jq -re --arg n "$node" '.[]? | select(.Name==$n)' >/dev/null; then
    log "Creating tart Linux scaffold for $node ($disk_gb GB) ..."
    tart create --linux "$node" --disk-size "$disk_gb"
  fi
  log "Disk-replacing $node with $image_attr (APFS clonefile) ..."
  cp -c "$img" "$HOME/.tart/vms/$node/disk.img"
  tart set "$node" --disk-size "$disk_gb"   # grow the record so NixOS autoResize extends the FS
}

build_and_replace hermes hermes-image
build_and_replace vault  vault-image

# --- 7. load the launchd agents ---------------------------------------------

# nix-darwin owns the tart launchd agents (darwin/host.nix launchd.user.agents."tart-*").
# `darwin-rebuild switch` above bootstraps them; nudge them so a fresh disk is picked up.
for node in hermes vault; do
  # nix-darwin prefixes user-agent labels with `org.nixos.` (agent name `tart-<node>`).
  label="org.nixos.tart-$node"
  log "Reloading launchd agent $label ..."
  launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
    || log "  (agent $label not yet loaded — darwin-rebuild will bootstrap it on next switch)"
done

# --- 8. human gates ----------------------------------------------------------

cat <<EOF

================================================================================
  HUMAN GATES — these cannot be scripted. Do them in order, then verify.
================================================================================

  [ ] 1. SIP disable on the bluebubbles VM (recovery mode).
         tart run bluebubbles --recovery-mode  ->  Utilities > Terminal:
           csrutil disable ; reboot
         Verify:  csrutil status   # expect: "...status: disabled."
         (see scripts/sip-disable.md)

  [ ] 2. Apple-ID iMessage sign-in (2FA) on the bluebubbles VM.
         Sign in with the dedicated Apple ID, complete 2FA, enable iMessage.

  [ ] 3. CLIProxyAPI Codex login (host, one-time browser flow):
           cli-proxy-api --codex-login          # ChatGPT subscription account

  [ ] 4. CLIProxyAPI Gemini login (host, one-time browser flow):
           cli-proxy-api --login                 # NOTE: flag is --login, NOT --gemini-login
                                                 # personal Google (free Code Assist)

  [ ] 5. agent-vault Google OAuth connect (any tailnet device):
           POST http://vault.$TAILNET_DOMAIN:14321/v1/credentials/oauth/connect
         Follow the browser consent; callback lands at
           https://vault.$TAILNET_DOMAIN/v1/oauth/callback

  [ ] 6. Fetch the agent-vault MITM CA and commit it to the OS trust store:
           curl -fsS http://vault.$TAILNET_DOMAIN:14321/v1/mitm/ca.pem \\
             -o nixos/agent-vault-ca.pem
         Then re-apply hermes so security.pki.certificateFiles installs it:
           just deploy hermes
         (the committed file is currently the @@AGENT_VAULT_CA_PEM@@ placeholder)

================================================================================
  Bootstrap finished the autonomous steps. Stopping cleanly at the gates above.
================================================================================
EOF

log "Done."
