#!/usr/bin/env bash
# Remove Nix + nix-darwin from the macOS host. Run BY HAND, LAST, after the de-Nix'd stack
# (scripts/setup.sh) is proven. This is destructive and reboots at the end.
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────┐
# │ HARD GATE — do NOT run until BOTH hold:                                                     │
# │   1. CI- or registry-pulled hermes works (the local nix.linux-builder is the ONLY image    │
# │      source until then; removing Nix removes the builder).                                  │
# │   2. A reboot-resmoke passes (host comes back, both VMs boot, services answer).             │
# │ Until both are green, KEEP NIX. There is no undo short of reinstalling.                     │
# └──────────────────────────────────────────────────────────────────────────────────────────┘
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/$UID_NUM"

# nix-darwin labels every user agent it owned `org.nixos.<name>`.
NIXOS_AGENTS=(
  org.nixos.tart-hermes
  org.nixos.tart-vault
  org.nixos.mlx-qwen
  org.nixos.parakeet-stt
  org.nixos.cliproxyapi
)

# --- helpers -----------------------------------------------------------------

log()  { printf '\033[1;34m[uninstall-nix]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[uninstall-nix]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[uninstall-nix] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  local reply
  read -rp "$1 [type 'yes' to continue] " reply
  [[ "$reply" == "yes" ]] || die "aborted by operator."
}

# --- 0. loud gate confirmation -----------------------------------------------

cat <<'BANNER'
================================================================================
  REMOVE NIX + NIX-DARWIN FROM THIS HOST
================================================================================
  This boots out the org.nixos.* launchd agents, runs the nix-darwin uninstaller,
  removes Nix entirely (the /nix store volume), strips the shell hooks, and REBOOTS.

  HARD GATE — only proceed if BOTH are true:
    1. CI- or registry-pulled hermes works (Nix removal kills the local builder).
    2. A reboot-resmoke passed (host + both VMs come back and answer).
================================================================================
BANNER
confirm "Have BOTH gate conditions been met and verified?"
confirm "This is destructive and will REBOOT at the end. Proceed?"

# --- 1. boot out the nix-darwin launchd agents -------------------------------

log "Booting out org.nixos.* launchd agents (KeepAlive can't relaunch once gone) ..."
for label in "${NIXOS_AGENTS[@]}"; do
  launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null \
    && log "  booted out $label" \
    || warn "  $label not loaded (skipping)"
done

# --- 2. uninstall nix-darwin FIRST -------------------------------------------

# Removes the org.nixos.* system daemons (incl. linux-builder), tears down /run/current-system,
# and restores the /etc backups nix-darwin took. Must run while Nix still exists.
log "Uninstalling nix-darwin (nix run nix-darwin#darwin-uninstaller) ..."
nix run nix-darwin#darwin-uninstaller

# --- 3. uninstall Nix --------------------------------------------------------

if [[ -e /nix/nix-installer ]] || command -v determinate-nixd >/dev/null 2>&1; then
  log "Determinate/nix-installer detected — sudo /nix/nix-installer uninstall ..."
  sudo /nix/nix-installer uninstall
else
  log "Official multi-user Nix removal ..."

  log "  stopping + removing the nix-daemon ..."
  sudo launchctl bootout system/org.nixos.nix-daemon 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/org.nixos.nix-daemon.plist
  sudo rm -f /Library/LaunchDaemons/org.nixos.darwin-store.plist

  log "  deleting the _nixbld build users + group ..."
  for n in $(seq 1 32); do
    sudo dscl . -delete "/Users/_nixbld$n" 2>/dev/null || true
  done
  sudo dscl . -delete /Groups/nixbld 2>/dev/null || true

  log "  restoring the /etc shell backups nix took ..."
  for f in bashrc zshrc bash.bashrc profile; do
    if [[ -e "/etc/$f.backup-before-nix" ]]; then
      sudo mv "/etc/$f.backup-before-nix" "/etc/$f"
      log "    restored /etc/$f"
    fi
  done
  sudo rm -rf /etc/nix

  log "  stripping the nix line from /etc/synthetic.conf ..."
  if [[ -e /etc/synthetic.conf ]]; then
    sudo sed -i '' '/^nix/d' /etc/synthetic.conf
    [[ -s /etc/synthetic.conf ]] || sudo rm -f /etc/synthetic.conf
  fi

  log "  deleting the Nix Store APFS volume + /nix ..."
  diskutil apfs deleteVolume "Nix Store" 2>/dev/null || warn "  no 'Nix Store' volume to delete"
  sudo rm -rf /nix
fi

# --- 4. shell hooks (host shell is fish; also check zsh) ---------------------

log "Removing nix shell hooks ..."
rm -f "$HOME"/.config/fish/conf.d/*nix*
# fish_add_path lines persist in the universal variable store; drop any nix entries.
if command -v fish >/dev/null 2>&1; then
  fish -c 'set -l p; for e in $fish_user_paths; string match -qv "*nix*" -- $e && set -a p $e; end; set -U fish_user_paths $p' \
    || warn "  could not prune fish_user_paths (no fish var store?)"
fi
for f in "$HOME/.zprofile" "$HOME/.zshrc"; do
  if [[ -e "$f" ]] && grep -q 'nix' "$f"; then
    warn "  $f still references nix — review by hand:"
    grep -n 'nix' "$f" || true
  fi
done

# --- 5. repo result symlink --------------------------------------------------

if [[ -L "$REPO_ROOT/result" ]]; then
  log "Removing repo result symlink (-> /nix/store) ..."
  rm -f "$REPO_ROOT/result"
fi

# --- 6. verify ---------------------------------------------------------------

log "Verifying removal ..."
fail=0
check() {
  if eval "$2"; then log "  OK: $1"; else warn "  FAIL: $1"; fail=1; fi
}
check "nix not on PATH"            '! command -v nix >/dev/null 2>&1'
check "/nix absent"               '! ls /nix >/dev/null 2>&1'
check "no nix mounts"             '! mount | grep -qi nix'
check "no _nixbld users"          '! dscl . -list /Users 2>/dev/null | grep -q _nixbld'
check "no nix in synthetic.conf"  '! { [ -e /etc/synthetic.conf ] && grep -q "^nix" /etc/synthetic.conf; }'
check "tart VMs present"          'tart list >/dev/null 2>&1 && tart list | grep -qE "metal|hermes"'
check "tailscale up"              'tailscale status >/dev/null 2>&1'

[[ "$fail" == 0 ]] || die "one or more verification checks failed — review the FAILs above before rebooting."

# --- 7. reboot ---------------------------------------------------------------

warn "All checks passed. The 'Nix Store' volume removal requires a reboot to fully clear /nix."
confirm "Reboot now?"
sudo reboot
