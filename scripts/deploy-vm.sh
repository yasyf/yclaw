#!/usr/bin/env bash
# Disk-replace FALLBACK for ONE Linux VM (hermes), reserved for REBOOT-CLASS changes —
# kernel / initrd / bootloader / stateVersion — that an in-guest switch can't apply live.
# It rebuilds hermes's raw-efi image (with the REAL agent-vault CA baked in) and clonefiles
# the fresh disk into the tart VM, then reloads the launchd runner so the new disk boots.
#
# PRIMARY hermes redeploy is in-guest `nixos-rebuild switch` via scripts/redeploy.sh — use that
# for everything that doesn't touch the boot chain; this script only for the reboot-class subset
# above. Run on the de-Nix'd host: the image builds inside the nested Linux builder VM
# (scripts/build-hermes-image.sh), never via host nix.
set -euo pipefail

node="${1:-}"
case "$node" in
  hermes) ;;
  *)
    echo "usage: deploy-vm.sh <hermes>" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=scripts/lib/common.sh
source "$repo_root/scripts/lib/common.sh"
# shellcheck source=scripts/lib/wait.sh
source "$repo_root/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/launchd.sh
source "$repo_root/scripts/lib/launchd.sh"
disk_gb="${DISK_GB:-64}"
# Gitignored build copy of the repo (mirrors bootstrap's BUILD_DIR). The hermes image bakes
# nixos/agent-vault-ca.pem, whose REAL value is fetched from metal below — so the build runs from
# this copy with the fetched CA written in, never dirtying the tracked tree.
build_dir="$repo_root/.build"

# Re-fetch the agent-vault MITM CA from metal (hermes trusts it via security.pki.certificateFiles →
# nixos/agent-vault-ca.pem). agent-vault generates it on metal, so it can only be fetched once metal
# is up; same up-to-15-min wait (180 × 5s) bootstrap §7 uses, since metal may still be activating.
echo "Fetching agent-vault MITM CA from metal (waiting for metal:14321, up to 15 min) ..."
ca_pem="$(wait_http_body http://metal:14321/v1/mitm/ca.pem 'BEGIN CERTIFICATE')" \
  || { echo "could not fetch the agent-vault CA from http://metal:14321/v1/mitm/ca.pem — is metal up and agent-vault running?" >&2; exit 1; }

# Stage the gitignored build copy with the REAL CA written in (exactly as bootstrap §7).
echo "Staging gitignored build copy at $build_dir ..."
rm -rf "$build_dir"
mkdir -p "$build_dir"
sync_build_mirror "$build_dir"
printf '%s' "$ca_pem" > "$build_dir/nixos/agent-vault-ca.pem"

# Build the raw-efi image inside the nested Linux builder VM (scripts/build-hermes-image.sh).
# GITHUB_TOKEN authenticates the build's nix flake-input fetches (unauthenticated GitHub API is
# 60/hr — one hermes closure exhausts it); YCLAW_BUILD_DIR points the build at the staged copy.
echo "Building hermes image from the build copy ..."
GITHUB_TOKEN="$(gh auth token)" YCLAW_BUILD_DIR="$build_dir" ./scripts/build-hermes-image.sh

img="$build_dir/result-hermes/nixos.img"
[[ -f "$img" ]] || { echo "hermes build finished but $img is missing." >&2; exit 1; }

if ! tart list --format json 2>/dev/null | jq -re --arg n "$node" '.[]? | select(.Name==$n)' >/dev/null; then
  echo "Creating tart Linux scaffold for $node (${disk_gb} GB) ..."
  tart create --linux "$node" --disk-size "$disk_gb"
fi

# hermes is a PERSISTENT tailnet node (scripts/lib/secrets.sh `_ts_mint_key`): an ordinary reboot
# reconnects from its on-disk node key with no re-mint. This disk-replace is the exception — it throws
# away the whole VM disk (and its node key), so the fresh image boots with empty tailscale state and
# must join FRESH via a NEW auth key. Re-mint one into hermes's sops bundle + node-config share BEFORE
# the replace, so the new image's first-boot seedNodeConfig installs it. (In-guest `nixos-rebuild
# switch` via scripts/redeploy.sh never disconnects hermes, so it needs none of this — this is the
# heavyweight disk-replace fallback.)
echo "Re-minting hermes's tailnet auth key (the disk-replace gives the new image empty state) ..."
"${repo_root}/scripts/remint-hermes-authkey.sh"

# Persistent nodes no longer self-reap, so the OLD hermes device would linger and steal the `hermes`
# MagicDNS name (the new node drifts to `hermes-1`, breaking `tailscale ssh hermes`). Delete it now,
# before the fresh image joins. Best-effort: skips cleanly if TAILSCALE_API_KEY is unset.
echo "Deleting the old hermes tailnet device (persistent nodes don't auto-reap) ..."
"${repo_root}/scripts/nuke-tailnet.sh" hermes || echo "  (could not delete old hermes device — check TAILSCALE_API_KEY in .env)"

# Boot the node's launchd runner OUT before the clonefile: setup.sh loads it RunAtLoad + KeepAlive,
# so a running runner would boot the VM mid-clonefile and corrupt the disk (same reason bootstrap
# boots every node out before replacing). It's re-loaded once the new disk is in place.
label="com.yclaw.tart-${node}"
echo "Booting out launchd agent $label before disk-replace ..."
bootout_drain "gui/$(id -u)" "$label"

echo "Disk-replacing $node with the freshly built image (APFS clonefile) ..."
cp -c "$img" "$HOME/.tart/vms/$node/disk.img"
# The built image is mode 0444 and APFS clonefile preserves it, so the clone is read-only and the
# `tart set --disk-size` resize (and the VM's own writes) fail "permission denied". Make it writable.
chmod u+w "$HOME/.tart/vms/$node/disk.img"
tart set "$node" --disk-size "$disk_gb" # grow the record so NixOS autoResize extends the FS

# Re-load the runner now that the new disk is in place (RunAtLoad + KeepAlive starts it), then
# kickstart so the new disk boots immediately.
echo "Loading launchd agent $label ..."
reload_launch_agent "$label" "$HOME/Library/LaunchAgents/$label.plist"
launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || true

echo "Deployed $node."
