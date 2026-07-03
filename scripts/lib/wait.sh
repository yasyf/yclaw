#!/usr/bin/env bash
# scripts/lib/wait.sh — bounded polling helpers. SELF-CONTAINED by design: it is sourced on the
# host, embedded into nix service wrappers, and piped verbatim into guests over `tailscale ssh`,
# so it sources nothing (its own _wait_log) and stays bash 3.2 compatible. Every wait fails LOUD
# on exhaustion and is safe under `set -e` (the polled command runs in an `if` condition, exempt
# from -e; the function returns the failing status so the caller aborts).
#
# TAILSCALE is a binary seam: nix wrappers and launchd contexts have no PATH, so set
# TAILSCALE=/opt/homebrew/bin/tailscale before use there; on the host the default resolves via PATH.

TAILSCALE="${TAILSCALE:-tailscale}"

_wait_log() { printf '%s\n' "$*" >&2; }

# Poll <cmd...> up to <attempts> times, sleeping <interval>s between tries. Return 0 on the first
# success; on exhaustion log FATAL and return the last failing status.
wait_for() {
  local desc="$1" attempts="$2" interval="$3"
  shift 3
  local i=0 status=0
  while [ "$i" -lt "$attempts" ]; do
    if "$@"; then return 0; fi
    status=$?
    i=$((i + 1))
    if [ "$i" -lt "$attempts" ]; then sleep "$interval"; fi
  done
  _wait_log "FATAL: $desc did not succeed after $attempts attempts (last status $status)"
  return "$status"
}

wait_path_exists() {
  wait_for "path exists: $1" "${2:-180}" 1 test -e "$1"
}

wait_file_nonempty() {
  wait_for "file non-empty: $1" "${2:-180}" 1 test -s "$1"
}

wait_http_ok() {
  wait_for "http 2xx: $1" "${2:-60}" "${3:-5}" curl -fsS --max-time 10 -o /dev/null "$1"
}

# Poll <url> until its body contains <needle>; print the body to stdout on success. Replaces the
# CA-fetch loops in bootstrap.sh / deploy-vm.sh (default 180 x 5s = 15 min).
wait_http_body() {
  local url="$1" needle="$2" attempts="${3:-180}" interval="${4:-5}"
  local i=0 body=""
  while [ "$i" -lt "$attempts" ]; do
    body="$(curl -fsS --max-time 10 "$url" 2>/dev/null)" || body=""
    case "$body" in
      *"$needle"*) printf '%s' "$body"; return 0 ;;
    esac
    i=$((i + 1))
    if [ "$i" -lt "$attempts" ]; then sleep "$interval"; fi
  done
  _wait_log "FATAL: $url never returned a body containing '$needle' after $attempts attempts"
  return 1
}

wait_tailscale_running() {
  local attempts="${1:-30}" i=0
  while [ "$i" -lt "$attempts" ]; do
    if "$TAILSCALE" status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'; then
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -lt "$attempts" ]; then sleep 2; fi
  done
  _wait_log "FATAL: tailscaled did not reach BackendState=Running after $attempts attempts"
  return 1
}

# Print this node's (no peer) or <peer>'s tailnet IPv4, waiting for tailscaled to assign one. The
# `|| true` inside the poll is load-bearing: a failed `tailscale ip` must not trip the caller's
# `set -e` mid-loop (darwin/metal.nix:92-93).
wait_tailscale_ip() {
  local peer="${1:-}" attempts="${2:-120}" i=0 ip=""
  while [ "$i" -lt "$attempts" ]; do
    if [ -n "$peer" ]; then
      ip="$("$TAILSCALE" ip -4 "$peer" 2>/dev/null | head -1)" || true
    else
      ip="$("$TAILSCALE" ip -4 2>/dev/null | head -1)" || true
    fi
    if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    i=$((i + 1))
    if [ "$i" -lt "$attempts" ]; then sleep 1; fi
  done
  _wait_log "FATAL: no tailnet IPv4 from '$TAILSCALE ip -4 ${peer:-<self>}' after $attempts attempts"
  return 1
}
