#!/usr/bin/env bash
# scripts/lib/pf.sh — install a scoped pf anchor. SELF-CONTAINED (own _pf_log) so it can be piped
# into guests over `tailscale ssh` alongside wait.sh. Runs in a root context (guests are entered as
# root; darwin/metal.nix's richer anchor manager stays in nix). bash 3.2 compatible.
#
# The kernel load ALWAYS goes through the targeted `pfctl -a <name> -f`, NEVER a full
# `pfctl -f /etc/pf.conf` — a full reload flushes the dynamically-loaded vmnet/NAT anchors the VMs
# need (the hard-won rule from darwin/host.nix). The ruleset is loaded into the kernel FIRST and
# the on-disk anchor file (the boot-time `load anchor` source) is written only once pf accepts it.

_pf_log() { printf '%s\n' "$*" >&2; }

# install_pf_anchor <name> <rules-file> [--wire-pfconf] [--enable]
#   --wire-pfconf  append the `anchor`/`load anchor` lines to /etc/pf.conf idempotently
#   --enable       `pfctl -E` after loading
install_pf_anchor() {
  local name="$1" rules="$2"
  shift 2
  local wire=0 enable=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wire-pfconf) wire=1 ;;
      --enable)      enable=1 ;;
      *) _pf_log "FATAL: install_pf_anchor: unknown arg '$1'"; return 2 ;;
    esac
    shift
  done
  [ -n "$name" ] && [ -n "$rules" ] || { _pf_log "usage: install_pf_anchor <name> <rules-file> [--wire-pfconf] [--enable]"; return 2; }
  [ -s "$rules" ] || { _pf_log "FATAL: pf rules file missing or empty: $rules"; return 1; }

  local anchor_dir="/etc/pf.anchors" anchor_file="/etc/pf.anchors/$name" tmp
  mkdir -p "$anchor_dir"
  tmp="$(mktemp "$anchor_dir/.$name.XXXXXX")" || { _pf_log "FATAL: mktemp failed for pf anchor $name"; return 1; }
  cat "$rules" > "$tmp"

  if pfctl -a "$name" -f "$tmp"; then
    mv -f "$tmp" "$anchor_file"
  else
    rm -f "$tmp"
    _pf_log "FATAL: pfctl rejected the $name anchor — previous ruleset left in force"
    return 1
  fi

  if [ "$wire" -eq 1 ] && ! grep -q "anchor \"$name\"" /etc/pf.conf; then
    printf '\nanchor "%s"\nload anchor "%s" from "%s"\n' "$name" "$name" "$anchor_file" >> /etc/pf.conf
  fi

  if [ "$enable" -eq 1 ]; then
    pfctl -E 2>/dev/null || true
  fi
}
