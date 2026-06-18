#!/usr/bin/env bash
# Deploy ONE Linux VM (hermes): rebuild its raw-efi image and disk-replace it
# into the tart VM, then nudge the launchd agent so the fresh disk boots.
# This is the per-node counterpart to the full `just bootstrap`. Run on the host.
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
disk_gb="${DISK_GB:-64}"
image_attr="${node}-image"

# TODO(human): the aarch64-linux build host is undecided (BLOCKER) —
#   this `nix build` needs a reachable aarch64-linux builder (nix.linux-builder VM,
#   a remote builder, or the VM itself). Wire it into nix.conf first, or the build fails.
echo "Building $image_attr ..."
img="$(nix build --no-link --print-out-paths "${repo_root}#packages.aarch64-linux.${image_attr}")/nixos.img"
# TODO(human): confirm the raw-efi result filename is nixos.img.
[[ -f "$img" ]] || {
  echo "expected raw-efi image at $img — check the nixos-generators result layout." >&2
  exit 1
}

if ! tart list --format json 2>/dev/null | jq -re --arg n "$node" '.[]? | select(.Name==$n)' >/dev/null; then
  echo "Creating tart Linux scaffold for $node (${disk_gb} GB) ..."
  tart create --linux "$node" --disk-size "$disk_gb"
fi

echo "Disk-replacing $node with $image_attr (APFS clonefile) ..."
cp -c "$img" "$HOME/.tart/vms/$node/disk.img"
tart set "$node" --disk-size "$disk_gb" # grow the record so NixOS autoResize extends the FS

# scripts/setup.sh labels the agent `com.yclaw.tart-<node>`; kickstart it to boot the new disk.
label="com.yclaw.tart-${node}"
echo "Reloading launchd agent $label ..."
launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null \
  || echo "  (agent $label not loaded — run \`just deploy host\` to bootstrap it first)"

echo "Deployed $node."
