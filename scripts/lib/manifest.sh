#!/usr/bin/env bash
# scripts/lib/manifest.sh — read accessors over the canonical machines.json. Self-contained
# (its own _manifest_die); the manifest path resolves relative to this file, so cwd never matters.
# bash 3.2 compatible.

YCLAW_MACHINES_JSON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/machines.json"

_manifest_die() { printf 'FATAL: %s\n' "$*" >&2; return 1; }

# Print the single value at <jq-expr> (raw). Fails loud on a missing/null key (jq -e), emitting
# nothing on stdout in that case.
manifest_get() {
  local v
  v="$(jq -er "$1" "$YCLAW_MACHINES_JSON")" || { _manifest_die "machines.json: no value at '$1'"; return 1; }
  printf '%s\n' "$v"
}

# Print each element of the array at <jq-expr>, one per line.
manifest_list() {
  jq -er "($1)[]" "$YCLAW_MACHINES_JSON" \
    || _manifest_die "machines.json: no array at '$1'"
}

# True (0) if <jq-expr> resolves to a present, non-null value; false otherwise. No output.
manifest_has() {
  jq -e "$1" "$YCLAW_MACHINES_JSON" >/dev/null 2>&1
}
