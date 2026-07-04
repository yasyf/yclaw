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
# shellcheck source=scripts/lib/ssh.sh
source "$REPO_ROOT/scripts/lib/ssh.sh"

# bootstrap.sh's hermes node-config share source; node.env holds the non-secret BLUEBUBBLES_ALLOWED_USERS.
NODE_CONFIG_DIR="$HOME/$(manifest_get '.host_paths.node_config_dir_rel')"
# tailscale ssh joins remote args and re-parses them in the remote login shell, whose PATH is minimal —
# so a custom NixOS command needs its absolute store path (mirrors bootstrap.sh's metal-mint-hermes-token).
HERMES_FLAKE="/var/lib/yclaw-repo#hermes"
HERMES_NIXOS_REBUILD="/run/current-system/sw/bin/nixos-rebuild"

redeploy_host() {
  log "Redeploying host (./scripts/setup.sh) ..."
  exec ./scripts/setup.sh
}

redeploy_metal() {
  log "Redeploying metal (darwin-rebuild switch via metal-redeploy) ..."
  ts_run root@metal metal-redeploy
}

redeploy_hermes() {
  local dry rc hits
  log "Redeploying hermes (dry-activate gate → nixos-rebuild switch) ..."
  # nix's libgit2 rejects the repo flake on the RO virtiofs share (host-owned, not root) unless root
  # marks /var/lib/yclaw-repo a git safe.directory — needed by BOTH dry-activate and switch below.
  # hermes's /root is ephemeral (wiped on a disk-replace fallback) and the guest has no git CLI, so
  # (re)assert it each run by writing root's global gitconfig directly, idempotently.
  ts_run root@hermes 'grep -qsF /var/lib/yclaw-repo /root/.gitconfig || printf "[safe]\n\tdirectory = /var/lib/yclaw-repo\n" >> /root/.gitconfig'
  # The flake ref carries a `#` — single-quote it INSIDE the one remote-command string so the remote
  # login shell does not read `#hermes` as a comment (the tailscale ssh re-parse gotcha, bootstrap.sh).
  # dry-activate previews the unit actions without touching the system; capture stdout+stderr the same
  # set +e / rc / set -e way bootstrap.sh's genericity guard captures rg.
  set +e
  dry="$(ts_run root@hermes "$HERMES_NIXOS_REBUILD dry-activate --flake '$HERMES_FLAKE'" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$dry" >&2
    die "hermes dry-activate failed (rc=$rc) — not switching."
  fi
  # ABORT to the disk-replace fallback if either STATEFUL mount would be started/stopped/restarted —
  # ANY active touch unmounts-or-(re)mounts a virtiofs tag mid-session, which Apple's virtiofs cannot
  # survive. The `would (start|stop|restart) ` anchor skips dry-activate's "would NOT …" negative lines;
  # a healthy code deploy leaves the mounts unchanged, so they appear in none of these lists.
  hits="$(printf '%s\n' "$dry" \
    | grep -E 'would (start|stop|restart) ' \
    | grep -E 'var-lib-hermes\.mount' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    die "hermes switch would stop/restart a stateful virtiofs mount (above) — a reboot-class change. Use the disk-replace fallback: ./scripts/deploy-vm.sh hermes"
  fi
  ts_run root@hermes "$HERMES_NIXOS_REBUILD switch --flake '$HERMES_FLAKE'"
}

redeploy_bluebubbles() {
  local bb_password
  log "Redeploying bluebubbles (config reconfigure over ssh) ..."
  # Server password: READ (never mint) from the dedicated yclaw keychain — the same unlock-then-read
  # path bootstrap.sh's build_macos_image uses. Sourcing secrets.sh only pulls in _yclaw_keychain_unlock
  # + the KC_SERVICE_* / YCLAW_KEYCHAIN names; collect_secrets is NEVER called, so nothing is minted.
  source "$REPO_ROOT/scripts/lib/secrets.sh"
  # The keychain must already exist (bootstrap owns its creation) — fail loud BEFORE kc_read (whose
  # _yclaw_keychain_unlock create branch would otherwise mint a fresh keychain + unlock password,
  # which redeploy must not do). kc_read unlocks, reads, and re-locks the yclaw keychain itself.
  [ -f "$YCLAW_KEYCHAIN" ] || die "no yclaw keychain at $YCLAW_KEYCHAIN — run \`just bootstrap\` first (redeploy never mints secrets)."
  bb_password="$(kc_read "$KC_SERVICE_BLUEBUBBLES_SERVER")"
  # Allowlist (NON-secret): source the host node.env bootstrap.sh assembled — it defines
  # BLUEBUBBLES_ALLOWED_USERS verbatim (the documented `source a node.env` path in bluebubbles-setup.sh's
  # header). set -u makes a missing value fail loud; a missing file makes `.` fail loud.
  . "$NODE_CONFIG_DIR/node.env"
  # Mirror bb-harden's piping (justfile): feed bluebubbles-setup.sh over ssh, here its `reconfigure`
  # subcommand, with the two config inputs in the REMOTE env (the guest holds no keychain / state share).
  # The password is [A-Za-z0-9]{32} and the allowlist is space-free iMessage handles, so the remote
  # shell's word-split over the joined args is lossless (no quoting dance needed, unlike the hermes #).
  tailscale ssh root@bluebubbles -- \
    env BLUEBUBBLES_PASSWORD="$bb_password" BLUEBUBBLES_ALLOWED_USERS="$BLUEBUBBLES_ALLOWED_USERS" \
    bash -s reconfigure < scripts/bluebubbles-setup.sh
}

case "${1:-}" in
  host)        redeploy_host ;;
  metal)       redeploy_metal ;;
  hermes)      redeploy_hermes ;;
  bluebubbles) redeploy_bluebubbles ;;
  all)         redeploy_metal; redeploy_hermes; redeploy_bluebubbles ;;
  *)           echo "usage: redeploy.sh <host|metal|hermes|bluebubbles|all>" >&2; exit 1 ;;
esac
