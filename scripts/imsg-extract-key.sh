#!/usr/bin/env bash
# One-time, in Terminal.app on the physical host: extract the Mac's iMessage hardware
# key into the yclaw keychain. Apple-ID-agnostic; corten logs in later, on Linux.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
cd "$REPO_ROOT"

need curl shasum unzip xattr gum security

YCLAW_KEYCHAIN="$HOME/Library/Keychains/yclaw.keychain-db"
CORTEN_SERVICE="yclaw-corten-hardware-key"

# The extractor lives in corten-matrix's repo tree, not on a release; pinned to the
# immutable commit its README links (byte-identical to HEAD as of 2026-07-18).
EXTRACTOR_URL='https://github.com/lrhodin/corten-matrix/raw/d9fed308b33a03019fd4273a6921a0a5bf818564/tools/extract-key-cli.zip'
EXTRACTOR_ZIP_SHA256='41ff44ee8db56affbcba16b88496a76f9b021b449cb1321485c1e9e40418384e'
EXTRACTOR_BIN_SHA256='078e56dd2151fb694b63c2654abdd569e97a0c2e4a3b641503288af0849156a0'

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 212 \
  'yclaw · corten iMessage hardware-key extraction (one-time)' \
  'Reads hardware identifiers only — NO Apple ID signs in here, no iCloud state is touched.' \
  'The yclaw Apple ID + 2FA come later, at corten login on the Linux guest.' \
  'The key lands only in the yclaw keychain — never a plaintext file.'

# A VM's virtualized identity is the documented Apple-ban vector — physical hardware only.
[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" != "1" ] \
  || die "running inside a VM — extract on the physical host only."

# Guard BEFORE any keychain access: onboard must never mint a fresh keychain (mirrors onboard.sh).
[ -f "$YCLAW_KEYCHAIN" ] || die "no yclaw keychain at $YCLAW_KEYCHAIN — run \`just bootstrap\` first."

# Fail fast in a session that can't read the login keychain — before extraction, not after.
LOGIN_UNLOCK_SERVICE="$(manifest_get '.host_paths.keychain.login_unlock')"
security find-generic-password -a "$USER" -s "$LOGIN_UNLOCK_SERVICE" -w >/dev/null 2>&1 \
  || die "cannot read $LOGIN_UNLOCK_SERVICE from the login keychain — run this in Terminal.app on the host (Aqua session); if it IS Terminal.app, unlock first: security unlock-keychain ~/Library/Keychains/login.keychain-db"

if uv run yclaw secret has corten-hardware-key; then
  log "hardware key already in the yclaw keychain ($CORTEN_SERVICE) — nothing to do."
  log "re-extract: security delete-generic-password -s '$CORTEN_SERVICE' '$YCLAW_KEYCHAIN', then re-run."
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

log "downloading extract-key-cli (pinned corten-matrix commit d9fed30) ..."
curl -fsSL -o "$workdir/extract-key-cli.zip" "$EXTRACTOR_URL"
echo "$EXTRACTOR_ZIP_SHA256  $workdir/extract-key-cli.zip" | shasum -a 256 -c - >/dev/null \
  || die "extract-key-cli.zip sha256 mismatch — refusing to run an unverified extractor."
unzip -oq "$workdir/extract-key-cli.zip" -d "$workdir"
extractor="$workdir/extract-key-cli/extract-key"
echo "$EXTRACTOR_BIN_SHA256  $extractor" | shasum -a 256 -c - >/dev/null \
  || die "extract-key binary sha256 mismatch — refusing to run an unverified extractor."
chmod +x "$extractor"
# Ad-hoc signed, not notarized: strip any quarantine flag so Gatekeeper cannot block launch.
xattr -cr "$workdir/extract-key-cli"

log "running the extractor (reads IOKit/NVRAM identifiers; may fetch _enc enrichment) ..."
out="$("$extractor")"
printf '%s\n' "$out"

# The key is the trailing long base64 line; every decorative extractor line carries spaces,
# so the last space-free base64-alphabet line >= 40 chars is it.
key="$(printf '%s\n' "$out" | awk '/^[A-Za-z0-9+\/=]+$/ && length($0) >= 40 { k = $0 } END { print k }')"
[ -n "$key" ] || die "no base64 key found in the extractor output above."
printf '%s' "$key" | base64 -D >/dev/null 2>&1 || die "parsed key is not valid base64: $key"

gum style --foreground 212 "  parsed key ❯ $key"
gum confirm "Store this key in the yclaw keychain? (it must match the key the extractor printed above)" \
  || die "not confirmed — nothing stored."

printf '%s' "$key" | uv run yclaw secret set corten-hardware-key --value -

gum style --border rounded --padding "1 2" --margin "1 0" --border-foreground 84 \
  "✓ hardware key → yclaw keychain ($CORTEN_SERVICE)" \
  '✓ no plaintext file was written; the extractor temp dir is removed on exit' \
  '' \
  'Read back:' \
  '  uv run yclaw secret read corten-hardware-key'
