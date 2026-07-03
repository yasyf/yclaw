#!/usr/bin/env bash
# scripts/lib/common.sh — shared host-side primitives: leveled logging, a tool-presence
# check, and the build-mirror rsync. Pure function library: sourcing it defines functions and
# one log-prefix constant and does nothing else. bash 3.2 compatible.
#
# log/warn/die derive their bracket prefix from the SOURCING script's basename (e.g. a
# bootstrap.sh that sources this logs `[bootstrap]`), matching the per-script tags the repo used
# before this library existed.

YCLAW_LOG_PREFIX="${0##*/}"
YCLAW_LOG_PREFIX="${YCLAW_LOG_PREFIX%.sh}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$YCLAW_LOG_PREFIX" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$YCLAW_LOG_PREFIX" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FATAL:\033[0m %s\n' "$YCLAW_LOG_PREFIX" "$*" >&2; exit 1; }

# Assert every named command is on PATH; die listing ALL missing tools at once (one round-trip
# instead of failing on the first). `need age-keygen sops jq …`.
need() {
  local missing="" c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="${missing:+$missing }$c"
  done
  [ -z "$missing" ] || die "required tool(s) not on PATH: $missing"
}

# Mirror the tracked repo into a gitignored build copy at <dest> (the CA-injection staging dir
# used by bootstrap.sh + deploy-vm.sh). Byte-identical to the tree with the build cruft excluded;
# --delete keeps the mirror exact even when <dest> is reused. The source is resolved relative to
# this file so cwd never matters. Callers pre-empty <dest>, so --delete is a no-op there today but
# keeps the mirror correct if that ever stops.
sync_build_mirror() {
  local dest="$1" repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  rsync -a --delete \
    --exclude '.git' --exclude '.build' --exclude 'result' --exclude 'result-*' \
    "$repo/" "$dest/"
}
