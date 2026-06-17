#!/usr/bin/env bash
# Build the aarch64-linux hermes raw-efi image WITHOUT Nix on the host, using a
# linux/arm64 `nixos/nix` Docker container. This replaces the nix-darwin
# `linux-builder` so the host can be de-Nix'd (scripts/uninstall-nix.sh) and still
# rebuild the hermes image on demand (the CI workflow does the same build remotely).
#
# A named volume (yclaw-nix-store) persists the container's /nix across runs so the
# closure is cached and only changed paths rebuild. Output: ./result-hermes/nixos.img.
#
#   ./scripts/build-hermes-image.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${NIX_DOCKER_IMAGE:-nixos/nix:latest}"
STORE_VOLUME="${NIX_STORE_VOLUME:-yclaw-nix-store}"
OUT_LINK="$REPO/result-hermes"

command -v docker >/dev/null || { echo "FATAL: docker not found." >&2; exit 1; }
docker version >/dev/null 2>&1 || { echo "FATAL: docker daemon not running." >&2; exit 1; }

echo "[build-hermes-image] building .#packages.aarch64-linux.hermes-image in $IMAGE ..."
docker run --rm --platform linux/arm64 \
  -v "$REPO":/repo \
  -v "$STORE_VOLUME":/nix \
  -w /repo \
  "$IMAGE" \
  sh -euc '
    git config --global --add safe.directory /repo
    nix --extra-experimental-features "nix-command flakes" \
      build .#packages.aarch64-linux.hermes-image --out-link /repo/result-hermes --print-build-logs
  '

IMG="$OUT_LINK/nixos.img"
[ -e "$IMG" ] || { echo "FATAL: build finished but $IMG is missing." >&2; exit 1; }
echo "[build-hermes-image] OK -> $IMG ($(du -h "$IMG" | cut -f1))"
