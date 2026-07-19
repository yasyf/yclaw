#!/usr/bin/env bash
# scripts/redeploy.sh — in-place, STATE-PRESERVING redeploy of an already-bootstrapped fleet, with
# zero human input. The heavyweight disk-replace path (`just bootstrap` / scripts/deploy-vm.sh) owns
# first-boot AND reboot-class changes; THIS script reuses the live VMs and only re-applies config:
#   host        → ./scripts/setup.sh (idempotent host bring-up; the `deploy host` path is setup.sh)
#   metal       → metal-redeploy over tailscale ssh (darwin-rebuild switch on the metal guest)
#   hermes      → nixos-rebuild switch over tailscale ssh, GATED by a dry-activate: if a STATEFUL
#                 virtiofs mount (var-lib-hermes) would be started/stopped/restarted,
#                 that is a reboot-class change `switch` cannot apply live — Apple's Virtualization.framework
#                 virtiofs CANNOT re-enumerate a tag once it is unmounted mid-session (`virtio-fs: tag <X>
#                 not found`), so the remount lands `failed` and hermes-agent's RequiresMountsFor blocks
#                 (observed 2026-06-18). So it ABORTS to the disk-replace fallback instead of switching.
#   bluebubbles → re-run bluebubbles-setup.sh's `reconfigure` over ssh, feeding the server password
#                 (READ, never minted, from the yclaw keychain) + the allowlist (host node.env).
#   all         → metal, then hermes, then bluebubbles; stop on the first failure.
#
# It NEVER sources collect_secrets nor mints/regenerates a secret or age key — the only keychain touch
# is a READ of the existing BlueBubbles server password. scripts/bootstrap.sh owns all secret creation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=scripts/lib/wait.sh
source "$REPO_ROOT/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/ssh.sh
source "$REPO_ROOT/scripts/lib/ssh.sh"

# bootstrap.sh's hermes node-config share source; node.env holds the non-secret BLUEBUBBLES_ALLOWED_USERS.
NODE_CONFIG_DIR="$HOME/$(manifest_get '.host_paths.node_config_dir_rel')"
# hermes runs as an Apple `container` named `hermes`, supervised by com.yclaw.container-hermes.
HERMES_CONTAINER="/opt/homebrew/bin/container"
HERMES_CONTAINER_NAME="hermes"

redeploy_host() {
  log "Redeploying host (./scripts/setup.sh) ..."
  exec ./scripts/setup.sh
}

redeploy_metal() {
  log "Redeploying metal (darwin-rebuild switch via metal-redeploy) ..."
  # Absolute store path: root's tailscale-ssh PATH has no nix dirs (same rule as the
  # metal-mint-hermes-token call in bootstrap.sh).
  ts_run root@metal /run/current-system/sw/bin/metal-redeploy
}

# A running container == a running agent: the entrypoint exec's the agent as the container's main
# process, so a crash stops the container.
_hermes_container_running() {
  "$HERMES_CONTAINER" list --format json 2>/dev/null | grep -q "\"id\":\"$HERMES_CONTAINER_NAME\""
}

redeploy_hermes() {
  log "Redeploying hermes (Apple container reload via com.yclaw.container-hermes) ..."
  # Remove the container; the supervisor tick recreates it (~60s) from the loaded image and re-runs
  # the entrypoint. `|| true`: an already-absent container must not abort the wait below.
  "$HERMES_CONTAINER" rm -f "$HERMES_CONTAINER_NAME" >/dev/null 2>&1 || true
  wait_for "hermes container '$HERMES_CONTAINER_NAME' recreated and running" 60 5 _hermes_container_running \
    || die "hermes container did not return to running — is com.yclaw.container-hermes loaded? (setup.sh host-container, then load its plist)"
  log "hermes container '$HERMES_CONTAINER_NAME' is running."
}

redeploy_bluebubbles() {
  local bb_password kc="$HOME/Library/Keychains/yclaw.keychain-db"
  log "Redeploying bluebubbles (config reconfigure over ssh) ..."
  # Server password: READ (never mint) from the dedicated yclaw keychain. It must already exist
  # (bootstrap owns its creation) — fail loud BEFORE the read, which redeploy must never mint.
  [ -f "$kc" ] || die "no yclaw keychain at $kc — run \`just bootstrap\` first (redeploy never mints secrets)."
  bb_password="$(uv run yclaw secret read bluebubbles-server-pass)"
  # Allowlist (NON-secret): source the host node.env bootstrap.sh assembled — it defines
  # BLUEBUBBLES_ALLOWED_USERS verbatim (the documented `source a node.env` path in bluebubbles-setup.sh's
  # header). set -u makes a missing value fail loud; a missing file makes `.` fail loud.
  . "$NODE_CONFIG_DIR/node.env"
  # Mirror bb-harden's piping (justfile): feed bluebubbles-setup.sh's `reconfigure` over guest_pipe —
  # wait.sh/pf.sh + the debloat prelude are piped ahead of the script, and the config inputs ride the
  # stdin stream as `export` lines (GUEST_PIPE_ENV), NOT argv — so the server password + allowlist stay
  # out of `ps` on host and guest (the guest holds no keychain / state share). BB_ALLOWED_HOST_IP (this
  # host's own tailnet IP, authorizing it on bluebubbles' pf gate — mirrors bootstrap.sh's
  # metal-allowed-hosts write) MUST be resolved HOST-side: the guest's own `tailscale ip -4` is
  # bluebubbles' address, not the operator's. reconfigure reads them from its environment. The names are
  # `local` so dynamic scope reaches guest_pipe without leaking; the `local` assignment also masks a
  # transient `tailscale` failure (empty => the guest leaves its allowlist untouched).
  local BLUEBUBBLES_PASSWORD="$bb_password"
  local BB_ALLOWED_HOST_IP="$(tailscale ip -4 | head -1)"
  local GUEST_PIPE_ENV="BLUEBUBBLES_PASSWORD BLUEBUBBLES_ALLOWED_USERS BB_ALLOWED_HOST_IP"
  guest_pipe root@bluebubbles scripts/bluebubbles-setup.sh reconfigure
}

case "${1:-}" in
  host)        redeploy_host ;;
  metal)       redeploy_metal ;;
  hermes)      redeploy_hermes ;;
  bluebubbles) redeploy_bluebubbles ;;
  all)         redeploy_metal; redeploy_hermes; redeploy_bluebubbles ;;
  *)           echo "usage: redeploy.sh <host|metal|hermes|bluebubbles|all>" >&2; exit 1 ;;
esac
