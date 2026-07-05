#!/usr/bin/env bash
# De-Nix'd host bring-up: the runtime role that darwin/host.nix used to play, as a plain
# idempotent shell script. The host runs NO Nix — just Homebrew `tart` + `gum`, the existing
# Tailscale daemon, the `~/.yclaw/state` virtiofs source, and three launchd VM runners.
#
# Re-runnable: brew installs are no-ops when present, mkdir -p is idempotent, and each
# LaunchAgent is rewritten then re-bootstrapped (bootout-before-bootstrap) so a changed plist
# takes effect.
#
# ── darwin/host.nix responsibility mapping ───────────────────────────────────────────────────
# DELETED (gone with the host services, which now run inside the `metal` VM):
#   • nix.linux-builder (the aarch64-linux build VM)        — host no longer builds anything
#   • launchd agents mlx-qwen / parakeet-stt / cliproxyapi  — retired; live inside metal
#   • environment.etc."cli-proxy-api/config.yaml"           — cliproxy config lives in metal
#   • the app-firewall allowlist (socketfilterfw add/unblock for cli-proxy-api + MLX python)
#                                                           — no host model services to unblock
#   • all nix-darwin scaffolding (stateVersion, primaryUser, trusted-users, pam.sudo_local,
#     homebrew module)                                      — replaced by this script
#   • the tart-vault runner                                 — vault VM retired; its agent-vault
#                                                             role now runs inside metal
# MOVED here (was nix-darwin, now plain shell):
#   • Homebrew tart + gum install (cirruslabs/cli tap)      — ensure_brew + brew install below
#   • the tart VM runners (launchd.user.agents.tart-*)      — write_agent + bootstrap below
# PRESERVED (left untouched by this script):
#   • the mise-built tailscaled 1.98.5 system daemon with `tailscale ssh` — detected, never
#     clobbered; `brew install tailscale` runs ONLY when no tailscaled exists
#   • the pf VNC anchor                                     — OFF by default (no host model
#     services to gate); see ENABLE_VNC_ANCHOR below
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=scripts/lib/wait.sh
source "$REPO_ROOT/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/launchd.sh
source "$REPO_ROOT/scripts/lib/launchd.sh"

HOME_DIR="$HOME"
STATE_DIR="$HOME_DIR/.yclaw/state"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
TART_BIN="/opt/homebrew/bin/tart"
LOGS_DIR="$HOME_DIR/Library/Logs/Tart"

# The host's REGULAR Hugging Face hub cache (NOT the state tree). metal mounts this as the
# `hfhub` share and serves models (omlx + STT) from it, so host and VM share ONE model cache and
# `hf download` on the host lands where the VM reads. Only the `hub/` subdir is shared — the
# sibling `token` file stays on the host and never enters the VM.
HF_HUB_DIR="${HF_HOME:-$HOME_DIR/.cache/huggingface}/hub"

# pf VNC anchor: OFF by default. The host runs no VNC-exposed model services anymore, so there
# is nothing to gate. Set ENABLE_VNC_ANCHOR=1 only if a VNC service is reintroduced on the host.
ENABLE_VNC_ANCHOR="${ENABLE_VNC_ANCHOR:-0}"

# --- helpers -----------------------------------------------------------------

# Write one tart LaunchAgent plist and (re)load it. bootout-before-bootstrap so a changed plist
# replaces the running agent instead of erroring on "service already loaded".
write_agent() {
  local node="$1"; shift
  local label="com.yclaw.tart-$node"
  local plist="$LAUNCH_AGENTS_DIR/$label.plist"
  local args=("$@")

  local program_args=""
  local a
  for a in "$TART_BIN" "${args[@]}"; do
    program_args+="    <string>$a</string>"$'\n'
  done

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
$program_args  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOGS_DIR/$node.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGS_DIR/$node.error.log</string>
</dict>
</plist>
PLIST

  reload_launch_agent "$label" "$plist"
  log "Loaded LaunchAgent $label."
}

# --- 0. Homebrew + tart + gum ------------------------------------------------

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then return; fi
  log "Installing Homebrew ..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

ensure_brew
command -v brew >/dev/null 2>&1 || die "Homebrew not on PATH after install."

log "Ensuring tart + gum (tap cirruslabs/cli) ..."
brew tap cirruslabs/cli
brew install cirruslabs/cli/tart gum
[[ -x "$TART_BIN" ]] || die "tart not at $TART_BIN after brew install."

# packer builds the macOS guest images (metal + bluebubbles) in `just bootstrap`.
log "Ensuring packer (tap hashicorp/tap) ..."
brew tap hashicorp/tap
brew install hashicorp/tap/packer
command -v packer >/dev/null 2>&1 || die "packer not on PATH after brew install."

# --- 1. Tailscale (detect-then-install; never clobber the mise daemon) -------

# The host already runs a mise-built tailscaled 1.98.5 (system daemon, `tailscale ssh` live).
# Re-pointing it at the older Homebrew binary would DOWNGRADE a working setup, so install the
# Homebrew tailscale ONLY when no tailscaled exists at all (fresh host).
if pgrep -qx tailscaled || command -v tailscaled >/dev/null 2>&1; then
  log "Existing tailscaled detected — leaving it untouched (not installing Homebrew tailscale)."
else
  log "No tailscaled found — installing Homebrew tailscale ..."
  brew install tailscale
fi

# --- 2. ~/.yclaw/state + per-VM subdirs --------------------------------------

# State subdirs the VMs read/write over the virtiofs shares (metal mounts narrow per-need shares,
# hermes mounts its own hosts/hermes bundle + hermes/ runtime state) come from machines.json.
log "Creating $STATE_DIR and per-VM subdirs ..."
mkdir -p "$STATE_DIR"
state_subdirs="$(manifest_list '.host_paths.state_subdirs_mounts')"
while IFS= read -r sub; do
  mkdir -p "$STATE_DIR/$sub"
done <<< "$state_subdirs"
chmod 700 "$STATE_DIR/hosts/hermes" "$STATE_DIR/hosts/metal"
mkdir -p "$LOGS_DIR" "$LAUNCH_AGENTS_DIR"
# The shared HF hub cache lives in the host's regular cache, not the state tree — create it so the
# metal LaunchAgent can mount the `hfhub` share even before any model has been downloaded.
mkdir -p "$HF_HUB_DIR"

# hermes node-config share source: the dir the tart-hermes runner mounts (--dir=sops:...:ro) so
# common.nix's seedNodeConfig can read key.txt + secrets.sops.yaml (+ node.env, agent-vault-ca.pem)
# on first boot. `just bootstrap` populates it; create it here so the runner can mount it even
# before a full bootstrap has written its contents.
NODE_CONFIG_DIR="$HOME_DIR/$(manifest_get '.host_paths.node_config_dir_rel')"
mkdir -p "$NODE_CONFIG_DIR"
chmod 700 "$NODE_CONFIG_DIR"

# --- 3. LaunchAgents for the VM runners --------------------------------------

# tart auto-mounts the `name:path` --dir form to /Volumes/My Shared Files/<name> inside macOS
# guests (verified); the `tag=` form does NOT auto-mount. metal gets NARROW per-need shares — its
# own secrets bundle (hosts/metal, read-only) plus only the runtime dirs it owns — instead of the
# whole state tree, so it can NEVER see hosts/hermes/ or state/hermes/ (hermes's age key + state).
# metal.nix's preActivation + sops.defaultSopsFile point under /Volumes/My Shared Files/metalsecrets.
#
# metal runs HEADLESS (--no-graphics): it holds ONLY the credential + AI services and NO
# iMessage, so it needs no host-side GUI window. omlx's Metal GPU works headless from the
# UserName=admin system daemons — no auto-login or aqua session required (verified; packer passes
# VM_AUTOLOGIN=drop for metal). The repo is shared
# read-only at /Volumes/My Shared Files/repo so the in-guest nix-darwin can rebuild itself
# (`darwin-rebuild switch --flake "/Volumes/My Shared Files/repo#metal"`, see darwin/metal.nix).
write_agent metal \
  run metal \
  --no-graphics \
  "--dir=metalsecrets:$STATE_DIR/hosts/metal:ro" \
  "--dir=agentvault:$STATE_DIR/agent-vault" \
  "--dir=hfhub:$HF_HUB_DIR" \
  "--dir=mlxaudio:$STATE_DIR/mlx-audio" \
  "--dir=cliproxy:$STATE_DIR/cli-proxy-api" \
  "--dir=repo:$HOME_DIR/Code/yclaw:ro"

# bluebubbles is the SIP-off iMessage node — its OWN tailnet node, holds NO credentials, so no
# state share. Runs HEADLESS + suspendable: in-guest auto-login provides the aqua session that
# Messages.app and Screen Sharing need, and the one-time GUI gates (Apple-ID 2FA, Full Disk
# Access, the Private API toggle) are driven over the guest's VNC, not a host-side tart window.
write_agent bluebubbles \
  run bluebubbles \
  --no-graphics \
  --suspendable

# hermes is a Linux guest: --no-graphics, and the serial console MUST be drained or a headless
# boot hangs once the virtio console ring fills. The `sops` share (ro) seeds the age key +
# secrets for first-boot node-config seeding; the `hermesstate` share (rw) externalizes the
# agent's persistent state (/var/lib/hermes — honcho memory, sessions) onto ~/.yclaw/state so it
# survives a VM rebuild and is covered by `just backup`. The `repo` share (ro) mounts this checkout
# read-only so the in-VM nixos-rebuild can rebuild itself (`nixos-rebuild switch --flake
# /var/lib/yclaw-repo#hermes`). (/var/lib/tailscale is NOT externalized — a mount there collides with
# tailscaled's StateDirectory; hermes is a PERSISTENT tailnet node whose on-disk key survives a reboot
# anyway, and only a disk-replace re-mints. See nixos/hermes.nix.)
#
# Unlike metal (a macOS guest, which auto-mounts the `name:path` form at /Volumes/My Shared
# Files/<name>), a Linux guest mounts each share by its EXPLICIT virtiofs tag — so these MUST use
# the `path:[ro,]tag=<tag>` form. The `name:path` form would leave them on tart's default
# `com.apple.virtio-fs.automount` tag, and common.nix's seedNodeConfig (tag `sops`) + nixos/hermes.nix's
# fstab (tags `hermesstate`/`repo`) would find no such device and the matching mount would fail.
write_agent hermes \
  run hermes \
  --no-graphics \
  --serial-path=/dev/null \
  "--dir=$NODE_CONFIG_DIR:ro,tag=sops" \
  "--dir=$STATE_DIR/hermes:tag=hermesstate" \
  "--dir=$HOME_DIR/Code/yclaw:ro,tag=repo"

# --- 3b. Nightly metal bounce -------------------------------------------------

# macOS guests have no memory balloon, so metal's host-side RSS ratchets to its high-water mark
# until the VM restarts. Nightly 05:00 stop; KeepAlive on com.yclaw.tart-metal relaunches it.
BOUNCE_LABEL="com.yclaw.metal-nightly-bounce"
bounce_plist="$LAUNCH_AGENTS_DIR/$BOUNCE_LABEL.plist"
cat > "$bounce_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BOUNCE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TART_BIN</string>
    <string>stop</string>
    <string>metal</string>
    <string>--timeout</string>
    <string>120</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>5</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOGS_DIR/metal-nightly-bounce.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGS_DIR/metal-nightly-bounce.error.log</string>
</dict>
</plist>
PLIST
reload_launch_agent "$BOUNCE_LABEL" "$bounce_plist"
log "Loaded LaunchAgent $BOUNCE_LABEL (nightly metal bounce at 05:00)."

# --- 4. pf VNC anchor (optional, OFF by default) -----------------------------

# Ports ONLY the targeted `pfctl -a vnc` reload from darwin/host.nix:189-204. NEVER
# `pfctl -f /etc/pf.conf`: a full reload flushes the vmnet / Internet-Sharing NAT anchors
# (shared_v4 / shared_v6 / network_isolation) the VMs need for internet + tailnet egress.
if [[ "$ENABLE_VNC_ANCHOR" == "1" ]]; then
  log "Loading pf VNC anchor (ENABLE_VNC_ANCHOR=1) ..."
  vnc_rules="$(mktemp)"
  cat > "$vnc_rules" <<'EOF'
table <vnc_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
block in quick proto { tcp udp } from any to any port 5900:5902
EOF
  # install_pf_anchor does a targeted `pfctl -a vnc -f` load only (NEVER `pfctl -f /etc/pf.conf`,
  # which flushes the vmnet / Internet-Sharing NAT anchors the VMs need), and is called WITHOUT
  # --wire-pfconf so the anchor stays out of /etc/pf.conf — this host deliberately does not
  # boot-wire the VNC anchor. pf ops need root, so run install_pf_anchor in a sudo shell that
  # sources the self-contained pf.sh.
  sudo bash -c 'source "$1"; install_pf_anchor vnc "$2"' _ "$REPO_ROOT/scripts/lib/pf.sh" "$vnc_rules"
  rm -f "$vnc_rules"
fi

log "Host setup complete. VM runners loaded as com.yclaw.tart-metal / com.yclaw.tart-bluebubbles / com.yclaw.tart-hermes."
