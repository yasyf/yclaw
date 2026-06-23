#!/usr/bin/env bash
# Build the aarch64-linux hermes raw-efi image WITHOUT Nix on the de-Nix'd host.
#
# CANONICAL PATH IS CI. .github/workflows/build-images.yml builds this image natively on a
# GitHub `ubuntu-24.04-arm` runner (which exposes /dev/kvm), runs the genericity guard, and
# publishes `hermes-<ver>.img.zst` as a release asset on every `v*` tag (plus weekly + on
# nixos/** pushes). The de-Nix'd host PULLS that published image — it does NOT build locally
# in the normal flow.
#
# This script is the LOCAL fallback for iterating on the image without cutting a tag. The host
# runs no Nix, so the build happens inside a throwaway tart LINUX VM launched with `--nested`:
# nixpkgs' make-disk-image runs qemu with a hard `-enable-kvm` (no TCG fallback), so the image
# step needs a real /dev/kvm, and `--nested` is the only way to get one on Apple Silicon (M3+).
# Docker Desktop / OrbStack do NOT expose nested-virt kvm to their Linux VMs on Apple Silicon
# (verified Jun 2026), so the old `nixos/nix` container path is gone.
#
# Output: ./result-hermes/nixos.img.
#
#   ./scripts/build-hermes-image.sh
set -euo pipefail

# YCLAW_BUILD_DIR points the build at a gitignored copy of the repo (with the real
# agent-vault CA written into nixos/agent-vault-ca.pem) so the tracked tree stays clean;
# defaults to the repo root for plain `just build-hermes-image` iteration.
REPO="${YCLAW_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TART_BIN="${TART_BIN:-/opt/homebrew/bin/tart}"
BUILDER_VM="${BUILDER_VM:-hermes-image-builder}"
# Pinned by immutable digest (audit M7): a mutable :latest tag let a registry-side change
# silently mutate the builder OS. Still env-overridable for ad-hoc bumps. Resolved 2026-06-18 via:
#   docker manifest inspect --verbose ghcr.io/cirruslabs/ubuntu:latest | jq -r '.Descriptor.digest'
# Re-run that command and update the digest below on an intentional base bump.
BUILDER_IMAGE="${BUILDER_IMAGE:-ghcr.io/cirruslabs/ubuntu@sha256:e90dfc9e6dffb742809f32e61ee03daf5fa6ee30e24ee05c105beffa3b7c9540}"
BUILDER_DISK_GB="${BUILDER_DISK_GB:-40}"
SSH_USER="${BUILDER_SSH_USER:-admin}"
# admin/admin + StrictHostKeyChecking=no below are the cirruslabs base default on a THROWAWAY
# local NAT builder VM that holds no secrets (audit M7, documented residual, lower priority).
SSH_PASS="${BUILDER_SSH_PASS:-admin}" # cirruslabs Linux base-image default credentials
OUT_LINK="$REPO/result-hermes"

die() { echo "[build-hermes-image] FATAL: $*" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "local builder needs Apple Silicon (--nested kvm); use CI elsewhere."
[[ -x "$TART_BIN" ]] || die "tart not at $TART_BIN (brew install cirruslabs/cli/tart)."
command -v sshpass >/dev/null || die "sshpass not found (brew install sshpass) — needed to log in to the builder VM."

# 1. Clone the Linux builder VM from the cirruslabs base image (idempotent; clone auto-pulls).
#    The VM persists across runs so its /nix store warms; the repo is re-shared fresh each run.
if ! "$TART_BIN" list --format json | jq -re --arg n "$BUILDER_VM" '.[]? | select(.Name==$n)' >/dev/null; then
  echo "[build-hermes-image] cloning $BUILDER_IMAGE -> $BUILDER_VM ..."
  "$TART_BIN" clone "$BUILDER_IMAGE" "$BUILDER_VM"
  "$TART_BIN" set "$BUILDER_VM" --disk-size "$BUILDER_DISK_GB"
fi

# 2. Boot it headless WITH nested virt and the repo shared rw over virtiofs (tag `repo`).
echo "[build-hermes-image] starting $BUILDER_VM (--nested, repo shared rw) ..."
"$TART_BIN" run "$BUILDER_VM" --no-graphics --nested "--dir=repo:$REPO" &
trap '"$TART_BIN" stop "$BUILDER_VM" 2>/dev/null || true' EXIT

# 3. Wait for the guest to report an IP (DHCP on the tart NAT).
echo "[build-hermes-image] waiting for $BUILDER_VM IP ..."
ip=""
for _ in $(seq 1 60); do
  ip="$("$TART_BIN" ip "$BUILDER_VM" 2>/dev/null || true)"
  [[ -n "$ip" ]] && break
  sleep 5
done
[[ -n "$ip" ]] || die "$BUILDER_VM never reported an IP."

ssh_guest() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    "$SSH_USER@$ip" "$@"
}

echo "[build-hermes-image] waiting for sshd on $BUILDER_VM ..."
for _ in $(seq 1 60); do
  ssh_guest true 2>/dev/null && break
  sleep 5
done
ssh_guest true 2>/dev/null || die "sshd on $BUILDER_VM never came up."

# 4. In-guest: prove real kvm, install Nix, build the image, drop it into the shared repo dir.
# Verified against a running cirruslabs ubuntu builder: login is admin/admin, and tart exposes the
# --dir shares under the single virtiofs tag `com.apple.virtio-fs.automount` (the `repo` share is a
# subdir), mounted below.
echo "[build-hermes-image] building inside $BUILDER_VM ..."
ssh_guest "YCLAW_GH_TOKEN='${GITHUB_TOKEN:-}' bash -euo pipefail" <<'GUEST'
test -e /dev/kvm || { echo "FATAL: /dev/kvm missing — --nested did not expose nested virt." >&2; exit 1; }
if ! command -v nix >/dev/null; then
  # UNPINNED INSTALLER (audit M7): `curl … | sh` of the rolling Determinate installer; a
  # registry/CDN-side change is executed unverified. Hardened the transport (--proto '=https'
  # --tlsv1.2) but the installer itself is not version-pinned. To pin, swap to a tagged
  # nix-installer release, e.g. https://github.com/DeterminateSystems/nix-installer/releases —
  # download nix-installer-<arch>-linux for a fixed tag, verify its sha256, then run it. Runs
  # on the throwaway builder, so transport hardening is the floor, not the ceiling.
  curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
# A PERSISTED builder reboots between runs and may come up before the Nix daemon socket is
# activated (nix build then fails "cannot connect to socket … Connection refused"). Ensure it.
if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
  sudo systemctl start nix-daemon.socket 2>/dev/null || sudo systemctl start nix-daemon 2>/dev/null || true
  for _ in $(seq 1 30); do [ -S /nix/var/nix/daemon-socket/socket ] && break; sleep 1; done
fi
# Authenticate nix's github flake-input fetches: the unauthenticated GitHub API is 60/hr and the
# hermes closure exhausts it. Append the token (passed via the YCLAW_GH_TOKEN env) to this throwaway
# builder's SYSTEM nix.conf so the client honors it (access-tokens is only honored from trusted/
# system config, and the build runs as a non-root user). The token stays on the builder VM, never
# in the hermes image.
if [ -n "${YCLAW_GH_TOKEN:-}" ]; then
  echo "access-tokens = github.com=$YCLAW_GH_TOKEN" | sudo tee -a /etc/nix/nix.conf >/dev/null
fi
# tart exposes ALL --dir shares to a Linux guest under a SINGLE virtiofs tag
# `com.apple.virtio-fs.automount`, with each share as a subdir named by its --dir name (`repo`) —
# there is no per-share `repo` tag, so `mount -t virtiofs repo` fails ("bad superblock"). Mount the
# automount tag and use the repo subdir. (Verified against a running cirruslabs ubuntu builder.)
sudo mkdir -p /mnt/shares
mountpoint -q /mnt/shares || sudo mount -t virtiofs com.apple.virtio-fs.automount /mnt/shares
cd /mnt/shares/repo
nix --extra-experimental-features "nix-command flakes" \
  build .#packages.aarch64-linux.hermes-image --out-link /tmp/result-hermes --print-build-logs
sudo install -d -m 755 /mnt/shares/repo/result-hermes
sudo cp -L /tmp/result-hermes/nixos.img /mnt/shares/repo/result-hermes/nixos.img
GUEST

IMG="$OUT_LINK/nixos.img"
[[ -e "$IMG" ]] || die "build finished but $IMG is missing."
echo "[build-hermes-image] OK -> $IMG ($(du -h "$IMG" | cut -f1))"
