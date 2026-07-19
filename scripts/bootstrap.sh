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

# Load persisted bootstrap inputs from .env (reused API keys + the non-secret answers) so re-runs
# are non-interactive. .env is gitignored; scripts/nuke-tailnet.sh sources it the same way.
# shellcheck disable=SC1091
if [ -f .env ]; then set -a; . ./.env; set +a; fi

# Shared helpers: common.sh (log/die/need), manifest.sh (manifest_get over machines.json), wait.sh
# (bounded polling), launchd.sh (bootout_drain), ssh.sh (ts_run). secrets.sh is sourced later, at
# its proper place just before collect_secrets.
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=scripts/lib/wait.sh
source "$REPO_ROOT/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/launchd.sh
source "$REPO_ROOT/scripts/lib/launchd.sh"
# shellcheck source=scripts/lib/ssh.sh
source "$REPO_ROOT/scripts/lib/ssh.sh"

RUNTIME_DIR="$REPO_ROOT/secrets/runtime"
VALUES_FILE="$RUNTIME_DIR/values.env"            # resolved non-secret values; gitignored

# The hermes node-config share source: setup.sh mounts this dir into the hermes guest as the
# virtiofs `sops` tag, and common.nix's seedNodeConfig installs key.txt → /var/lib/sops-nix,
# secrets.sops.yaml + node.env (+ agent-vault-ca.pem) → /var/lib/node-config on first boot.
NODE_CONFIG_DIR="$HOME/$(manifest_get '.host_paths.node_config_dir_rel')"

# The dirs `nix flake check` / a rebuild evaluates — where a stray @@TAILNET_DOMAIN@@ would break
# the GENERIC image. Post-Stage-B every config uses bare MagicDNS names, so this guard must pass.
GENERIC_TREE=(nixos darwin)

# --- helpers -----------------------------------------------------------------

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

# rg: genericity guard; hf: Qwen model download. (nix/rsync dropped with the tart-hermes build.)
need age-keygen sops openssl jq gum python3 tart packer security curl rg hf
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

# metal clones a digest-pinned cirruslabs base image (see packer/metal.pkr.hcl) rather than
# installing from a raw IPSW, so there is no IPSW to collect here.
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
for tok in TAILNET_DOMAIN GITHUB_OWNER HOST_RAM AUTHORIZED_HANDLES; do
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
# NOTE: this guard targets ONLY @@TAILNET_DOMAIN@@. Other @@…@@ tokens live in the generic tree ON
# PURPOSE — @@CLIPROXY_API_KEY@@ / @@VM_ADMIN_PASS@@ (darwin/) and @@TS_AUTHKEY@@ /
# @@AGENT_VAULT_CA_PEM@@ (nixos/) are rendered at build- or activation-time (packer PKR_VAR_*, sops,
# the fetched CA), never at flake-eval, so they are exempt and must survive this scan.
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

# setup.sh (re)loads the com.yclaw.tart-* runners with RunAtLoad + KeepAlive, so each immediately
# starts retrying `tart run <node>`. That races the packer builds and the hermes disk-replace below:
# the instant a VM with the target name exists, KeepAlive boots it and packer's own start fails
# ("VM <node> is already running"), or it boots hermes mid-clonefile and corrupts the disk. Boot all
# three out now; each is re-loaded at its proper boot point once its disk is in place.
for node in metal bluebubbles hermes; do
  bootout_drain "gui/$(id -u)" "com.yclaw.tart-$node"
done

# --- 6. build the macOS guest images (metal + bluebubbles) via packer --------

# The yclaw keychain holds the per-VM admin passwords, fed to packer as PKR_VAR_* env exports (NOT
# in-tree @@token@@ substitution). vm_admin_user is always `admin` to match darwin/metal.nix's
# primaryUser. metal applies github:$GITHUB_OWNER/yclaw#metal.

build_macos_image() {
  local node="$1" admin_service="$2" admin_pass
  # Idempotent: skip the (expensive) build if the VM already exists, so a re-run resumes past it.
  # `just destroy` / `just nuke` removes the VMs to force a clean rebuild.
  if tart list --format json 2>/dev/null | jq -re --arg n "$node" '.[]? | select(.Name==$n)' >/dev/null; then
    log "$node VM already exists — skipping build (run 'just destroy' to force a rebuild)."
    return 0
  fi
  # kc_read unlocks the yclaw keychain, reads, and re-locks per call — exactly the per-read re-unlock
  # this needs: the keychain auto-locks after 300s, and a build ahead of this one (metal takes ~6 min)
  # trips that, so a single up-front unlock would have re-locked by the second build (a locked read
  # then pops a GUI prompt / fails exit 152 non-interactively). kc_read dies loud if the item is absent.
  admin_pass="$(kc_read "$admin_service")"
  log "Building $node image via packer (-only=tart-cli.$node) ..."
  # Packer loads every packer/*.pkr.hcl together (shared common.pkr.hcl); -only picks this node.
  # Both nodes clone a digest-pinned base in their .pkr.hcl, so no IPSW var is passed here.
  # github_token authenticates metal's nix flake-input fetches (unauthenticated GitHub API is
  # 60/hr — one metal build exhausts it); it is used only during the build, never baked.
  PKR_VAR_github_owner="$GITHUB_OWNER" \
  PKR_VAR_vm_admin_user="admin" \
  PKR_VAR_vm_admin_pass="$admin_pass" \
  PKR_VAR_github_token="${GITHUB_TOKEN:-}" \
    packer init "$REPO_ROOT/packer/"
  PKR_VAR_github_owner="$GITHUB_OWNER" \
  PKR_VAR_vm_admin_user="admin" \
  PKR_VAR_vm_admin_pass="$admin_pass" \
  PKR_VAR_github_token="${GITHUB_TOKEN:-}" \
    packer build -only="tart-cli.$node" "$REPO_ROOT/packer/"
}

build_macos_image metal       "$KC_SERVICE_METAL_ADMIN"
build_macos_image bluebubbles "$KC_SERVICE_BLUEBUBBLES_ADMIN"

# Boot the freshly-built macOS guests now that their disks exist: re-load each runner (booted out
# before the build) so RunAtLoad + KeepAlive starts and supervises it. The CA fetch below needs
# metal up + agent-vault provisioned.
for node in metal bluebubbles; do
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.yclaw.tart-$node.plist" 2>/dev/null \
    || log "  (could not load com.yclaw.tart-$node; ./scripts/setup.sh rewrites it on next run)"
  launchctl kickstart -k "gui/$(id -u)/com.yclaw.tart-$node" 2>/dev/null || true
done

# --- 6b. authorize THIS host on metal's pf gate ------------------------------
# metal's pf anchor (darwin/metal.nix) admits ONLY hermes + explicitly-allowed host IPs to its five
# service ports; every other tailnet node is dropped. hermes does not exist yet, and this host is an
# arbitrary existing tailnet member (not yclaw-named), so metal cannot resolve it — authorize it by
# writing this host's own tailnet IP into metal's allow-list over the SSH path (which the gate never
# blocks), then kick the anchor refresh so it applies before the CA fetch below. Idempotent: the file
# is overwritten each run, so no stale host IP accumulates. metal SSH must be up first (it is the
# admin path), so wait on it.
HOST_TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
[[ -n "$HOST_TS_IP" ]] || die "could not determine this host's tailnet IP (tailscale ip -4) to authorize host->metal access"
# metal activates on its FIRST BOOT (com.yclaw.metal-activate runs darwin-rebuild switch once its
# secret share is mounted), so it only joins the tailnet after that ~5-10 min activation — wait
# generously (180 × 5s = 15 min) for it to become SSH-reachable.
log "Authorizing this host ($HOST_TS_IP) on metal's pf gate (waiting for metal's first-boot activation + SSH, up to 15 min) ..."
# Pass the whole script as ONE argument (ts_run enforces this): `tailscale ssh host -- sh -c "a && b"`
# is mangled because tailscale ssh word-splits its remote args, so the remote runs `sh -c <first-word>`
# (e.g. `sh -c mkdir`) and the rest is misparsed — it silently fails to write the file yet still exits 0.
# As a single string the remote login shell runs the full `&&` chain and returns its real exit code.
metal_authorize_cmd="mkdir -p /etc/pf.anchors && umask 077 && printf '%s\n' '$HOST_TS_IP' > /etc/pf.anchors/metal-allowed-hosts && launchctl kickstart -k system/org.nixos.metal-pf-refresh"
wait_for "authorize this host on metal's pf gate" 180 5 ts_run root@metal "$metal_authorize_cmd" \
  || die "could not authorize this host on metal's pf gate over tailscale ssh — is metal up?"

# --- 7. stage the container's agent-vault CA + proxy token -------------------

# Container-native hermes: stage the metal-derived MITM CA (public) + proxy token, no image build.
log "Fetching agent-vault MITM CA from metal (waiting for metal:14321, up to 15 min) ..."
CA_PEM="$(wait_http_body http://metal:14321/v1/mitm/ca.pem 'BEGIN CERTIFICATE')" \
  || die "could not fetch the agent-vault CA from http://metal:14321/v1/mitm/ca.pem — is metal up and agent-vault running?"
( umask 077; printf '%s' "$CA_PEM" > "$NODE_CONFIG_DIR/agent-vault-ca.pem" )
chmod 644 "$NODE_CONFIG_DIR/agent-vault-ca.pem"
log "Staged agent-vault MITM CA (mode 644) into $NODE_CONFIG_DIR."

# Mint hermes's agent-vault proxy token and stage it into the node-config share. The token is
# SERVER-generated by agent-vault (never caller-specified), so it cannot live in hermes's sops
# bundle (encrypted before metal exists) — it must be minted from metal AFTER metal is up. metal's
# provision oneshot already created the `hermes` injection-only agent (agent create … :proxy);
# `agent rotate --token-only` is idempotent (deletes old sessions, mints fresh) and prints ONLY the
# raw token. It is a proxy-role token: it can cause credential injection on matched hosts but can
# never read/reveal a raw key. seedNodeConfig (nixos/common.nix) copies it to the hermes VM and
# renders the HTTPS_PROXY URL (http://<token>:hermes@metal:14322) — so it MUST be staged before
# hermes boots. (L1.)
log "Minting hermes agent-vault proxy token from metal (metal-mint-hermes-token) ..."
HERMES_AV_TOKEN="$(ts_run root@metal /run/current-system/sw/bin/metal-mint-hermes-token)"
case "$HERMES_AV_TOKEN" in
  av_agt_*) ;;
  *) die "agent-vault did not return a proxy token (got: '${HERMES_AV_TOKEN:0:12}…') — is metal up and the hermes agent provisioned?" ;;
esac
( umask 077; printf '%s' "$HERMES_AV_TOKEN" > "$NODE_CONFIG_DIR/agent-vault-token" )
chmod 600 "$NODE_CONFIG_DIR/agent-vault-token"
log "Staged agent-vault proxy token (mode 600) into $NODE_CONFIG_DIR."

# --- 8b. container bring-up (gated: image load + supervisor touch pf) --------

# hermes is container-native: no tart VM, no hermes-onboard — bring-up is a manual, root-assisted step.
log "hermes is container-native — no tart VM to create, no hermes-onboard to run."
log "Finish the container bring-up manually (root-assisted; not part of the unattended run):"
log "  1. Build + load the hermes-agent:latest image (build + skopeo + 'container image load', one script):"
log "     ./scripts/build-container-image.sh hermes-container-image hermes-agent:latest"
log "  2. ./scripts/setup.sh host-container   # stages secrets, builds proxy, authors supervisor + egress pf (GATED)"
log "  3. Load the supervisor + egress pf per the two launchctl lines setup.sh prints."

# --- 8c. download the Qwen model into the shared HF hub cache ----------------

# Host serves this model now (metal relays); `hf download` idempotent, model public (no token).
QWEN_ID="$(rg -o 'qwen = "[^"]+"' nixos/models.nix | sed -E 's/qwen = "(.*)"/\1/')"
log "Downloading model $QWEN_ID into the shared HF hub cache (${HF_HOME:-$HOME/.cache/huggingface}/hub) ..."
hf download "$QWEN_ID"

# --- 9. human gates ----------------------------------------------------------

cat <<EOF

================================================================================
  HUMAN GATES — credential ceremonies the providers keep human (Apple-ID 2FA, OAuth consent).
  Bootstrap finished every autonomous step. Run the onboarding TUI to clear the gates:

      just onboard

  It drives them in order, idempotently (already-done gates are skipped), in a zellij session:
    0. Tailscale SSH check  — approve the re-auth URL it surfaces.
    A. hermes identity      — USER.md + SOUL.md + the Honcho peer.
    B. CLIProxyAPI Codex    — one-time ChatGPT login (paste the failed redirect URL back).
    C. CLIProxyAPI Gemini   — one-time personal-Google login (callback is port-forwarded; no paste).
    D. agent-vault Google OAuth — approve one consent URL on this Mac.
    E. Apple-ID iMessage    — sign in + 2FA over VNC, then BlueBubbles setup + harden.
  Then it runs \`just validate\` + \`just smoke\`.
================================================================================
EOF

log "Done."
