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
# The GH token and optional GENERICITY_BLOCKLIST ride leading stdin lines the remote reads in
# order, never the ps-readable remote argv; printf is a builtin, so no local process list either.
case "${GENERICITY_BLOCKLIST:-}" in
  *$'\n'*) die "GENERICITY_BLOCKLIST must be a single line (it rides one stdin line to the builder)" ;;
esac
{
  printf '%s\n' "${GITHUB_TOKEN:-}"
  printf '%s\n' "${GENERICITY_BLOCKLIST:-}"
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

# --- genericity guard (ported from the retired .github/workflows/build-images.yml) ---
# Abort the build if an author-specific secret leaked into the built image. Two scans with a
# deliberate pattern split: closure store-path NAMES are short labels carrying no key bodies, so
# scan 1 uses the broad pattern with no false-positive risk; scan 2 greps the raw BYTES of the
# uncompressed docker-archive (the oci-archive may gzip its layers — a plaintext grep there would
# silently miss), where AGE requires its full 58-char body so the hermes-agent redaction ruleset's
# own regex SOURCE text doesn't self-trip, AKIA[0-9A-Z]{16} is dropped (16 uppercase alnums recur
# by chance in any large binary and nothing here uses AWS), and BEGIN...PRIVATE KEY is dropped (the
# closure bakes hundreds of test-vector PEM keys a line grep can't tell from a real leak). The
# allowlist strips exact all-x doc placeholders; a real token is never whole-line-equal to them.
# GENERICITY_BLOCKLIST (optional; the operator's own host facts as an ERE alternation, threaded
# from the host over stdin like the GH token) appends to both patterns.
allowlist=.github/genericity-allowlist.txt
[ -f "$allowlist" ] || { echo "::error::genericity guard: $allowlist missing — refusing to skip the scan" >&2; exit 1; }
name_pattern='tskey-(auth|api)-[A-Za-z0-9]|sk-[A-Za-z0-9]{20}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|AGE-SECRET-KEY-1|BEGIN [A-Z ]*PRIVATE KEY'
img_pattern='tskey-(auth|api)-[A-Za-z0-9]|sk-[A-Za-z0-9]{20}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9]{20}|AGE-SECRET-KEY-1[0-9A-Z]{58}'
if [ -n "${YCLAW_GENERICITY_BLOCKLIST:-}" ]; then
  grep -qE "$YCLAW_GENERICITY_BLOCKLIST" /dev/null || [ $? -eq 1 ] \
    || { echo "::error::genericity guard: GENERICITY_BLOCKLIST is not a valid ERE — refusing to scan without it" >&2; exit 1; }
  name_pattern="$name_pattern|$YCLAW_GENERICITY_BLOCKLIST"
  img_pattern="$img_pattern|$YCLAW_GENERICITY_BLOCKLIST"
fi
closure_paths="$(nix --extra-experimental-features "nix-command flakes" path-info -r "$result_link")"
closure_hits="$(printf '%s\n' "$closure_paths" | grep -E "$name_pattern" || true)"
[ -z "$closure_hits" ] || {
  echo "::error::genericity guard: author-specific string in a closure store-path name:" >&2
  echo "$closure_hits" >&2
  exit 1
}
image_bytes="$(LC_ALL=C grep -aoE "$img_pattern" "$docker_archive")" || [ $? -eq 1 ] \
  || { echo "::error::genericity guard: image-bytes scan errored (grep exit >1) — refusing to pass" >&2; exit 1; }
image_hits="$(printf '%s' "$image_bytes" | sort -u | grep -vFxf "$allowlist")" || [ $? -eq 1 ] \
  || { echo "::error::genericity guard: allowlist filter errored (grep exit >1) — refusing to pass" >&2; exit 1; }
[ -z "$image_hits" ] || {
  echo "::error::genericity guard: secret-shaped bytes baked into the image:" >&2
  echo "$image_hits" >&2
  exit 1
}
echo "genericity guard: clean (closure names + raw image bytes)"
# --- end genericity guard ---

nix --extra-experimental-features "nix-command flakes" \
  shell nixpkgs#skopeo -c skopeo --insecure-policy copy \
  "docker-archive:$docker_archive" "oci-archive:$oci_archive:$image_tag"
cp "$oci_archive" "/mnt/shares/repo/result-container-images/$artifact_name"
rm -f "$docker_archive" "$oci_archive"
GUEST
} | ssh_guest "IFS= read -r YCLAW_GH_TOKEN; IFS= read -r YCLAW_GENERICITY_BLOCKLIST; export YCLAW_GH_TOKEN YCLAW_GENERICITY_BLOCKLIST; bash -s -- $flake_attr_q $image_tag_q $artifact_name_q"

[[ -s "$OCI_ARCHIVE" ]] || die "build finished but $OCI_ARCHIVE is missing or empty"
log "Loading $IMAGE_TAG from $OCI_ARCHIVE ..."
"$CONTAINER_BIN" image load --input "$OCI_ARCHIVE"
log "Loaded $IMAGE_TAG; rollback archive retained at $OCI_ARCHIVE"
