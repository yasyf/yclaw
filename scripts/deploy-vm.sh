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
disk_gb="${DISK_GB:-64}"
# Gitignored build copy of the repo (mirrors bootstrap's BUILD_DIR). The hermes image bakes
# nixos/agent-vault-ca.pem, whose REAL value is fetched from metal below — so the build runs from
# this copy with the fetched CA written in, never dirtying the tracked tree.
build_dir="$repo_root/.build"

# Re-fetch the agent-vault MITM CA from metal (hermes trusts it via security.pki.certificateFiles →
# nixos/agent-vault-ca.pem). agent-vault generates it on metal, so it can only be fetched once metal
# is up; same up-to-15-min wait (180 × 5s) bootstrap §7 uses, since metal may still be activating.
echo "Fetching agent-vault MITM CA from metal (waiting for metal:14321, up to 15 min) ..."
ca_pem=""
for _ in $(seq 1 180); do
  ca_pem="$(curl -fsS --max-time 10 http://metal:14321/v1/mitm/ca.pem 2>/dev/null || true)"
  [[ "$ca_pem" == *"BEGIN CERTIFICATE"* ]] && break
  sleep 5
done
[[ "$ca_pem" == *"BEGIN CERTIFICATE"* ]] \
  || { echo "could not fetch the agent-vault CA from http://metal:14321/v1/mitm/ca.pem — is metal up and agent-vault running?" >&2; exit 1; }

# Stage the gitignored build copy with the REAL CA written in (exactly as bootstrap §7).
echo "Staging gitignored build copy at $build_dir ..."
rm -rf "$build_dir"
mkdir -p "$build_dir"
rsync -a --exclude '.git' --exclude '.build' --exclude 'result' --exclude 'result-*' "$repo_root/" "$build_dir/"
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

# Boot the node's launchd runner OUT before the clonefile: setup.sh loads it RunAtLoad + KeepAlive,
# so a running runner would boot the VM mid-clonefile and corrupt the disk (same reason bootstrap
# boots every node out before replacing). It's re-loaded once the new disk is in place.
label="com.yclaw.tart-${node}"
echo "Booting out launchd agent $label before disk-replace ..."
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

echo "Disk-replacing $node with the freshly built image (APFS clonefile) ..."
cp -c "$img" "$HOME/.tart/vms/$node/disk.img"
# The built image is mode 0444 and APFS clonefile preserves it, so the clone is read-only and the
# `tart set --disk-size` resize (and the VM's own writes) fail "permission denied". Make it writable.
chmod u+w "$HOME/.tart/vms/$node/disk.img"
tart set "$node" --disk-size "$disk_gb" # grow the record so NixOS autoResize extends the FS

# Re-load the runner now that the new disk is in place (RunAtLoad + KeepAlive starts it), then
# kickstart so the new disk boots immediately.
echo "Loading launchd agent $label ..."
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null \
  || echo "  (could not load $label — run \`just setup\` to rewrite the runner first)"
launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || true

echo "Deployed $node."
