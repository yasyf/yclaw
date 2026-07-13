#!/usr/bin/env bash
# scripts/lib/pf.sh — install a scoped pf anchor. SELF-CONTAINED (own _pf_log) so it can be piped
# into guests over `tailscale ssh` alongside wait.sh. Runs in a root context (guests are entered as
# root; darwin/metal.nix's richer anchor manager stays in nix). bash 3.2 compatible.
#
# The kernel load ALWAYS goes through the targeted `pfctl -a <name> -f`, NEVER a full
# `pfctl -f /etc/pf.conf` — a full reload flushes the dynamically-loaded vmnet/NAT anchors the VMs
# need (the hard-won rule from darwin/host.nix). The ruleset is loaded into the kernel FIRST and
# the on-disk anchor file (the boot-time `load anchor` source) is written only once pf accepts it.

# The /etc paths are the mock boundary: tests point these at a sandbox, production never sets them.
PF_ANCHOR_DIR="${PF_ANCHOR_DIR:-/etc/pf.anchors}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"

_pf_log() { printf '%s\n' "$*" >&2; }

# The on-disk file backing an anchor: a slashed child-anchor path flattens to a dotted filename,
# because /etc/pf.anchors already holds a FILE named com.apple — a subdirectory of that name is
# impossible.
pf_anchor_file() { printf '%s/%s' "$PF_ANCHOR_DIR" "$(printf '%s' "$1" | tr '/' '.')"; }

# install_pf_anchor <name> <rules-file> [--wire-pfconf|--wire-load-only] [--enable]
#   --wire-pfconf     append the `anchor`/`load anchor` lines to pf.conf idempotently
#   --wire-load-only  append ONLY the `load anchor` line — for a child anchor (com.apple/000.x)
#                     that an existing parent wildcard call already evaluates; an `anchor` call
#                     line would evaluate its ruleset a second time per packet
#   --enable          ensure pf is enabled (idempotent; failure propagates)
install_pf_anchor() {
  local name="$1" rules="$2"
  shift 2
  local wire="" enable=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wire-pfconf)    wire=full ;;
      --wire-load-only) wire=load ;;
      --enable)         enable=1 ;;
      *) _pf_log "FATAL: install_pf_anchor: unknown arg '$1'"; return 2 ;;
    esac
    shift
  done
  [ -n "$name" ] && [ -n "$rules" ] || { _pf_log "usage: install_pf_anchor <name> <rules-file> [--wire-pfconf|--wire-load-only] [--enable]"; return 2; }
  [ -s "$rules" ] || { _pf_log "FATAL: pf rules file missing or empty: $rules"; return 1; }

  local fname anchor_file tmp eout
  fname="$(printf '%s' "$name" | tr '/' '.')"
  anchor_file="$(pf_anchor_file "$name")"
  mkdir -p "$PF_ANCHOR_DIR"
  tmp="$(mktemp "$PF_ANCHOR_DIR/.$fname.XXXXXX")" || { _pf_log "FATAL: mktemp failed for pf anchor $name"; return 1; }
  cat "$rules" > "$tmp"

  if pfctl -a "$name" -f "$tmp"; then
    mv -f "$tmp" "$anchor_file" \
      || { rm -f "$tmp"; _pf_log "FATAL: cannot write $anchor_file — kernel has the new ruleset, the boot-time file does not"; return 1; }
  else
    rm -f "$tmp"
    _pf_log "FATAL: pfctl rejected the $name anchor — previous ruleset left in force"
    return 1
  fi

  if [ "$wire" = full ] && ! grep -qF "anchor \"$name\"" "$PF_CONF"; then
    printf '\nanchor "%s"\nload anchor "%s" from "%s"\n' "$name" "$name" "$anchor_file" >> "$PF_CONF" \
      || { _pf_log "FATAL: cannot append the $name anchor lines to $PF_CONF"; return 1; }
  elif [ "$wire" = load ] && ! grep -qF "load anchor \"$name\"" "$PF_CONF"; then
    printf '\nload anchor "%s" from "%s"\n' "$name" "$anchor_file" >> "$PF_CONF" \
      || { _pf_log "FATAL: cannot append the $name load line to $PF_CONF"; return 1; }
  fi

  if [ "$enable" -eq 1 ]; then
    # macOS boots pf loaded-but-DISABLED, but every `pfctl -E` acquires a fresh refcount token a
    # fire-and-forget tick would leak (288/day at a 300s cadence) — so probe first and enable
    # with the un-refcounted -e only when pf is actually off. Swallowing a failure here would
    # let a caller claim enforcement while pf is disabled.
    if ! pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      eout="$(pfctl -e 2>&1)" || { _pf_log "FATAL: pfctl -e failed — pf NOT enabled: $eout"; return 1; }
    fi
  fi
}
