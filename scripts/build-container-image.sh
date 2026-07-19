#!/usr/bin/env bash
# Build and load an aarch64-linux container image without Nix on the de-Nix'd host.
set -euo pipefail

REPO="${YCLAW_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TART_BIN="${TART_BIN:-/opt/homebrew/bin/tart}"
CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
BUILDER_VM="${BUILDER_VM:-hermes-image-builder}"
BUILDER_IMAGE="${BUILDER_IMAGE:-ghcr.io/cirruslabs/ubuntu@sha256:e90dfc9e6dffb742809f32e61ee03daf5fa6ee30e24ee05c105beffa3b7c9540}"
BUILDER_DISK_GB="${BUILDER_DISK_GB:-140}"
BUILDER_MEMORY_GB="${BUILDER_MEMORY_GB:-16}"
BUILDER_CPU="${BUILDER_CPU:-8}"
SSH_USER="${BUILDER_SSH_USER:-admin}"
SSH_PASS="${BUILDER_SSH_PASS:-admin}"

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"

need jq ssh sshpass

[ "$#" -eq 2 ] || die "usage: build-container-image.sh <flake-attr> <image-tag>"
FLAKE_ATTR="$1"
IMAGE_TAG="$2"
case "$FLAKE_ATTR" in *[!A-Za-z0-9._+-]*) die "invalid flake attribute: $FLAKE_ATTR" ;; esac
case "$IMAGE_TAG" in *[!A-Za-z0-9._/:@+-]*) die "invalid image tag: $IMAGE_TAG" ;; esac

[[ "$(uname -m)" == "arm64" ]] || die "local builder needs an Apple Silicon tart VM"
[[ -x "$TART_BIN" ]] || die "tart not at $TART_BIN (brew install cirruslabs/cli/tart)"
[[ -x "$CONTAINER_BIN" ]] || die "apple/container CLI not at $CONTAINER_BIN (brew install container)"

ARTIFACT_DIR="$REPO/result-container-images"
ARTIFACT_NAME="$FLAKE_ATTR-$(date -u +%Y%m%dT%H%M%SZ).oci.tar"
OCI_ARCHIVE="$ARTIFACT_DIR/$ARTIFACT_NAME"
mkdir -p "$ARTIFACT_DIR"

if ! "$TART_BIN" list --format json | jq -re --arg n "$BUILDER_VM" '.[]? | select(.Name==$n)' >/dev/null; then
  log "Cloning $BUILDER_IMAGE -> $BUILDER_VM ..."
  "$TART_BIN" clone "$BUILDER_IMAGE" "$BUILDER_VM"
fi
"$TART_BIN" set "$BUILDER_VM" --disk-size "$BUILDER_DISK_GB" \
  --memory "$((BUILDER_MEMORY_GB * 1024))" --cpu "$BUILDER_CPU"

log "Starting $BUILDER_VM with the repo shared read/write ..."
"$TART_BIN" run "$BUILDER_VM" --no-graphics "--dir=repo:$REPO" &
trap '"$TART_BIN" stop "$BUILDER_VM" 2>/dev/null || true' EXIT

ip=""
_builder_has_ip() { ip="$("$TART_BIN" ip "$BUILDER_VM" 2>/dev/null)"; [ -n "$ip" ]; }
wait_for "$BUILDER_VM to report an IP" 60 5 _builder_has_ip \
  || die "$BUILDER_VM never reported an IP"

ssh_guest() {
  sshpass -p "$SSH_PASS" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    "$SSH_USER@$ip" "$@"
}

wait_for "sshd on $BUILDER_VM" 60 5 ssh_guest true \
  || die "sshd on $BUILDER_VM never came up"

printf -v flake_attr_q '%q' "$FLAKE_ATTR"
printf -v image_tag_q '%q' "$IMAGE_TAG"
printf -v artifact_name_q '%q' "$ARTIFACT_NAME"

log "Building $FLAKE_ATTR and converting it to OCI inside $BUILDER_VM ..."
# The GH token rides a leading stdin line the remote reads, never the remote command argv (which is
# ps-readable); printf is a bash builtin, so it doesn't surface in a local process list either.
{
  printf '%s\n' "${GITHUB_TOKEN:-}"
  cat <<'GUEST'
set -euo pipefail
flake_attr="$1"
image_tag="$2"
artifact_name="$3"

if ! command -v nix >/dev/null; then
  # Pinned installer (audit M7): a fixed tagged nix-installer verified by sha256, instead of piping
  # the rolling `install.determinate.systems/nix` script — a registry/CDN-side change would
  # otherwise execute unverified on this builder (which also carries the repo share + the GH token).
  # Bump: pick a tag from https://github.com/DeterminateSystems/nix-installer/releases, download
  # nix-installer-aarch64-linux, sha256 it, and update both lines below. Builder is always aarch64.
  ni_ver=v3.21.7
  ni_sha=afa197be4d4dd48b57ffc2de7d32d1fbc464a22b45477f2b8e8e25562f5c9869
  ni_bin=/tmp/nix-installer
  curl --proto '=https' --tlsv1.2 -fsSL -o "$ni_bin" \
    "https://github.com/DeterminateSystems/nix-installer/releases/download/$ni_ver/nix-installer-aarch64-linux"
  echo "$ni_sha  $ni_bin" | sha256sum -c - || { echo "nix-installer sha256 mismatch — refusing" >&2; exit 1; }
  chmod +x "$ni_bin"
  "$ni_bin" install --no-confirm
  rm -f "$ni_bin"
fi
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
  sudo systemctl start nix-daemon.socket 2>/dev/null || sudo systemctl start nix-daemon 2>/dev/null || true
  for _ in $(seq 1 30); do [ -S /nix/var/nix/daemon-socket/socket ] && break; sleep 1; done
fi
if [ -n "${YCLAW_GH_TOKEN:-}" ]; then
  # Transient token: the GitHub flake-fetch token is honored only from trusted/system config and
  # this build runs as a non-root user, so it must live in the system nix.conf — but only for THIS
  # build. Strip any prior copy (a reused builder must not accumulate tokens), append, and remove it
  # on exit so it never persists on the builder VM that also holds the repo share.
  sudo sed -i '/^access-tokens = github.com=/d' /etc/nix/nix.conf 2>/dev/null || true
  trap 'sudo sed -i "/^access-tokens = github.com=/d" /etc/nix/nix.conf 2>/dev/null || true' EXIT
  echo "access-tokens = github.com=$YCLAW_GH_TOKEN" | sudo tee -a /etc/nix/nix.conf >/dev/null
fi

sudo mkdir -p /mnt/shares
mountpoint -q /mnt/shares \
  || sudo mount -t virtiofs com.apple.virtio-fs.automount /mnt/shares
cd /mnt/shares/repo

result_link=/tmp/result-container-image
docker_archive="/tmp/$flake_attr.docker-archive.tar"
oci_archive="/tmp/$artifact_name"
rm -f "$docker_archive" "$oci_archive"
nix --extra-experimental-features "nix-command flakes" \
  build ".#packages.aarch64-linux.$flake_attr" --out-link "$result_link" --print-build-logs
"$result_link" > "$docker_archive"
nix --extra-experimental-features "nix-command flakes" \
  shell nixpkgs#skopeo -c skopeo --insecure-policy copy \
  "docker-archive:$docker_archive" "oci-archive:$oci_archive:$image_tag"
cp "$oci_archive" "/mnt/shares/repo/result-container-images/$artifact_name"
rm -f "$docker_archive" "$oci_archive"
GUEST
} | ssh_guest "IFS= read -r YCLAW_GH_TOKEN; export YCLAW_GH_TOKEN; bash -s -- $flake_attr_q $image_tag_q $artifact_name_q"

[[ -s "$OCI_ARCHIVE" ]] || die "build finished but $OCI_ARCHIVE is missing or empty"
log "Loading $IMAGE_TAG from $OCI_ARCHIVE ..."
"$CONTAINER_BIN" image load --input "$OCI_ARCHIVE"
log "Loaded $IMAGE_TAG; rollback archive retained at $OCI_ARCHIVE"
