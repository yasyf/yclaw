#!/usr/bin/env bash
# scripts/lib/ssh.sh — `tailscale ssh` wrappers. Requires common.sh (die) and manifest.sh
# (manifest_get / manifest_has / manifest_list) to be sourced first. bash 3.2 compatible.
#
# `tailscale ssh <target> -- <args>` word-splits its remote args and re-parses them in the remote
# login shell, so a compound `a && b` must arrive as ONE argument — ts_run enforces that.

# ts_run <target> <command-string> — run exactly one remote command string.
ts_run() {
  [ "$#" -eq 2 ] || die "ts_run: compound remote commands must be ONE string (got $# arg(s))"
  tailscale ssh "$1" -- "$2"
}

# guest_prelude <machine> — emit `VAR='...'` context lines for a piped guest script: the node name
# plus, when the node has one, its debloat label lists (space-joined).
guest_prelude() {
  local m="$1"
  printf "YCLAW_NODE=%s\n" "$m"
  if manifest_has ".debloat.\"$m\""; then
    printf "YCLAW_DEBLOAT_SYSTEM='%s'\n" "$(manifest_get ".debloat.\"$m\".system | join(\" \")")"
    printf "YCLAW_DEBLOAT_GUI='%s'\n"    "$(manifest_get ".debloat.\"$m\".gui | join(\" \")")"
  fi
}

# guest_pipe <target> <script-path> [args...] — pipe wait.sh + pf.sh + the per-node prelude + the
# script to `/bin/bash -s -- args...` on <target> over tailscale ssh. Generalizes the
# `tailscale ssh root@bluebubbles -- bash -s harden < bluebubbles-setup.sh` idiom.
guest_pipe() {
  local target="$1" script="$2"
  shift 2
  local node="${target##*@}" libdir
  libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$script" ] || die "guest_pipe: script not found: $script"
  { cat "$libdir/wait.sh" "$libdir/pf.sh"; guest_prelude "$node"; cat "$script"; } \
    | tailscale ssh "$target" -- /bin/bash -s -- "$@"
}
