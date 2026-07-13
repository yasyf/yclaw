#!/bin/bash
# scripts/host/host-pf.sh — one refresh tick of the host's fleet-lockdown pf anchor: resolve the
# three fleet VMs' current tailnet IPs (v4 + v6) plus the Tart vmnet bridge, then re-key the
# anchor so ONLY metal reaches the host's model ports (rapid-mlx + mlx-audio STT), no fleet VM
# reaches anything else on the host over the tailnet, and the vmnet side-door is shut: Darwin's
# weak-host model answers a bridge-ingress packet addressed to ANY host address — the bridge
# gateway 192.168.64.1, the LAN IP, even the tailnet IP over a forced VM route — past both the
# tailnet ACL and the tailnet-IP rules. Personal devices and non-fleet traffic never match —
# every rule is keyed on the resolved fleet addresses or the fleet's vmnet subnet, never a
# CGNAT-wide source. The fleet's tailnet ingress to the host rides WAN/DERP (no direct host<->
# fleet WireGuard path exists), so no tailscaled UDP pass is needed and the bridge rules never
# touch the model plane.
#
# The anchor attaches at com.apple/000.yclaw.host — a CHILD of the stock /etc/pf.conf's
# `anchor "com.apple/*"` wildcard call — so the targeted load is EVALUATED immediately: on first
# install, and again within one tick of any OS-update reset of /etc/pf.conf. A root-level anchor
# would sit orphaned until a boot-time full reload (`pfctl -f /etc/pf.conf` live is off the
# table — it flushes the dynamically-inserted Internet-Sharing/vmnet calls, severing VM NAT).
# Main-ruleset order also puts the com.apple/* call BEFORE pf.conf's `anchor "vnc"`, whose
# <vnc_allowed> table quick-passes 192.168.0.0/16 + the tailnet to 5900-5902 — so this anchor's
# quick block beats the VNC allow for fleet sources. Wildcard children evaluate ALPHABETICALLY,
# and Apple's own (200.AirDrop, 250.ApplicationFirewall) may carry quick passes that would end
# evaluation before a later sibling — 000 sorts ahead of every Apple child, so our verdicts win.
#
# A TEMPLATE, not run from the repo: `setup.sh host-pf` bakes @@TAILSCALE@@ (a root-owned CLI
# copy under /usr/local/lib/yclaw — a root daemon must never exec user-writable bits) and
# @@PF_PORTS@@ (the manifest's host rapid-mlx/mlx-audio ports) and installs it beside wait.sh +
# pf.sh under /usr/local/lib/yclaw, where the com.yclaw.host-pf-refresh LaunchDaemon (root, in
# /Library/LaunchDaemons: a RunAtLoad + KeepAlive sleep-loop — StartInterval silently stops
# firing on Tahoe) re-runs it every 300s once a short-backoff loop lands the first boot tick.
# $1 = poll attempts for tailscaled to reach Running (default 10, 2s apart).
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
TAILSCALE=@@TAILSCALE@@
ANCHOR=com.apple/000.yclaw.host
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$YCLAW_LIB/wait.sh"
# shellcheck source=scripts/lib/pf.sh
. "$YCLAW_LIB/pf.sh"

PORTS="@@PF_PORTS@@"

# Enforcement-health marker: epoch of the last fully-verified tick. launchd reports the refresh
# loop healthy even when every tick fails, so marker staleness (more than ~2 tick periods) is
# the signal a doctor check reads.
MARKER="$YCLAW_LIB/host-pf.last-ok"

# Tart's vmnet shared network keeps Apple's stable defaults (subnet 192.168.64.0/24, host
# gateway .1), but the BRIDGE NUMBER drifts across VM restarts — and lume's bridge100 plus the
# LAN sit on other subnets — so resolve which interface carries the gateway address each tick
# rather than hardcoding bridgeN.
VMNET_HOST=192.168.64.1
VMNET_NET=192.168.64.0/24

wait_tailscale_running "${1:-10}" \
  || { echo "host-pf: FATAL tailscaled not Running — previous ruleset left in force" >&2; exit 1; }

# Fail LOUD, never partial: a fleet VM this tick cannot resolve would otherwise render a ruleset
# with that VM unblocked (fail-OPEN), so any miss aborts the tick and leaves the previous ruleset
# in force. `tailscale ip` answers from the netmap — an offline-but-joined peer still resolves —
# so a miss means the node is genuinely absent from the tailnet, not merely down.
resolve_ip() {
  local ip
  ip="$("$TAILSCALE" ip "-$2" "$1" 2>/dev/null | head -1)" || ip=""
  [ -n "$ip" ] || { echo "host-pf: FATAL cannot resolve tailnet IPv$2 for '$1' — previous ruleset left in force" >&2; return 1; }
  printf '%s' "$ip"
}

METAL4="$(resolve_ip metal 4)" || exit 1
METAL6="$(resolve_ip metal 6)" || exit 1
HERMES4="$(resolve_ip hermes 4)" || exit 1
HERMES6="$(resolve_ip hermes 6)" || exit 1
BB4="$(resolve_ip bluebubbles 4)" || exit 1
BB6="$(resolve_ip bluebubbles 6)" || exit 1

FLEET="{ $METAL4, $METAL6, $HERMES4, $HERMES6, $BB4, $BB6 }"

# Same die-loud discipline as the tailnet resolution: no interface carrying the gateway IP means
# the fleet bridge is down or renumbered, and rendering onto a stale interface name would
# silently reopen the side-door once the bridge returns under another number.
VMNET_IF="$(ifconfig | awk -v ip="$VMNET_HOST" \
  '/^[a-z0-9]+: flags=/ { sub(":", "", $1); ifc = $1 } $1 == "inet" && $2 == ip { print ifc; exit }')"
[ -n "$VMNET_IF" ] || { echo "host-pf: FATAL no interface carries $VMNET_HOST (Tart vmnet bridge down?) — previous ruleset left in force" >&2; exit 1; }

RULES=$(mktemp) || { echo "host-pf: ERROR mktemp failed for pf rules" >&2; exit 1; }
{
  echo "# Generated at runtime by host-pf.sh (fleet VMs resolved live by tailnet hostname)."
  echo "# Keyed on bare fleet IPs, both address families: pf cannot match tailnet tags (that policy"
  echo "# lives in tailnet/policy.hujson), and no \`on utunN\` scope — the utun unit is dynamic across"
  echo "# tailscaled restarts, the metal anchor (the prior art) keys on bare IPs too, and an unscoped"
  echo "# IP block is strictly tighter (it also drops a spoofed fleet source arriving on vmnet)."
  echo "# The pass out is load-bearing: host-initiated flows to the fleet (tailscale ssh, yclaw"
  echo "# probes, bootstrap) get state entries, and pf consults state BEFORE rules, so fleet replies"
  echo "# to those flows never reach the block."
  echo "pass out quick to $FLEET keep state"
  echo "pass in quick proto tcp from { $METAL4, $METAL6 } to any port $PORTS"
  echo "block drop in quick from $FLEET to any"
  echo "# vmnet side-door: Darwin's weak-host model answers a bridge-ingress packet addressed to ANY"
  echo "# host address — the gateway $VMNET_HOST, the LAN IP, even the tailnet IP over a forced VM"
  echo "# route — so the block's dest is pf's \`self\` (every address on every host interface,"
  echo "# re-expanded at each tick's load), not just $VMNET_HOST. NAT'd VM->internet traffic arrives"
  echo "# on $VMNET_IF with a PUBLIC destination — never in \`self\` — so the fleet's egress falls"
  echo "# through untouched. DHCP renews (67/68; the initial DISCOVER is 0.0.0.0->255.255.255.255"
  echo "# and matches neither pass nor block — broadcast is not \`self\`) and DNS (53) stay open"
  echo "# against the host-side vmnet daemons, dest-scoped to the gateway. The pass out keeps"
  echo "# host-initiated vmnet flows (packer image builds, \`yclaw vm ssh\` pre-tailnet) alive: pf's"
  echo "# implicit default pass creates NO state, so their replies to $VMNET_HOST would otherwise"
  echo "# die on the block."
  echo "pass out quick on $VMNET_IF to $VMNET_NET keep state"
  echo "pass in quick on $VMNET_IF proto udp from $VMNET_NET to $VMNET_HOST port { 53, 67, 68 }"
  echo "pass in quick on $VMNET_IF proto tcp from $VMNET_NET to $VMNET_HOST port 53"
  echo "block drop in quick on $VMNET_IF from $VMNET_NET to self"
  echo "# An IPv4 source can never match an IPv6 packet, so the guests' link-local v6 needs its own"
  echo "# family's block against ::-bound host listeners (vmnet v6 is link-local only — no"
  echo "# DHCPv6/RAs to pass — and neighbor discovery rides multicast dests, which are not \`self\`)."
  echo "block drop in quick on $VMNET_IF inet6 from any to self"
} > "$RULES"

# pf consults the state table BEFORE rules, so a fleet->host connection admitted under the
# PREVIOUS ruleset keeps flowing after this load. Detect a moved enforcement boundary — rendered
# rules differ from the on-disk anchor, or the kernel anchor is empty/absent — before the load
# overwrites the on-disk copy; the matching states are killed after the load verifies. Gated on
# change because an every-tick kill would reset metal's legitimate model-plane connections
# every 300s.
ANCHOR_FILE="$(pf_anchor_file "$ANCHOR")"
NEED_KILL=0
cmp -s "$RULES" "$ANCHOR_FILE" 2>/dev/null || NEED_KILL=1
[ -n "$(pfctl -a "$ANCHOR" -sr 2>/dev/null)" ] || NEED_KILL=1

# Targeted `pfctl -a $ANCHOR -f` load (NEVER `pfctl -f /etc/pf.conf` on the host — a full reload
# flushes the vmnet/Internet-Sharing NAT anchors the VMs need); --wire-load-only appends the
# boot-time load line idempotently (the com.apple/* wildcard already CALLS the anchor — see the
# header, and a re-run self-heals an OS-update pf.conf reset); --enable re-asserts pf every tick
# (macOS boots pf loaded-but-DISABLED), covering an out-of-band `pfctl -d` the way metal's
# engine watchdog does — idempotently, so no `pfctl -E` refcount tokens pile up (pf.sh probes
# `pfctl -s info` first).
install_pf_anchor "$ANCHOR" "$RULES" --wire-load-only --enable
rc=$?
rm -f "$RULES"
[ "$rc" -eq 0 ] || exit "$rc"

# Loaded is not evaluated: this child ruleset only runs because the main ruleset's
# `anchor "com.apple/*"` call reaches it. Exact-line match (-x): pfctl -sr renders the stock
# unconditional call as `anchor "com.apple/*" all` — a substring grep would also accept the
# scrub-anchor line or a CONDITIONAL call that skips our packets, claiming enforcement that
# isn't there.
pfctl -sr 2>/dev/null | grep -qxF 'anchor "com.apple/*" all' \
  || { echo "host-pf: FATAL main ruleset lacks the unconditional com.apple/* wildcard filter call — $ANCHOR loaded but NOT evaluated" >&2; exit 1; }

if [ "$NEED_KILL" -eq 1 ]; then
  # `pfctl -k src` kills states ORIGINATING from src — host-initiated flows to the fleet keep
  # their host-origin states — and a fleet tailnet IP only ever originates fleet->host flows
  # here, so the single-arg form is already the narrow kill (metal's live model-plane states
  # drop too; they re-establish through the pass above). The vmnet kill must be pair-scoped
  # (`-k src -k dst`, one dst per host-interface IPv4): a bare -k on the subnet would also kill
  # the guests' NAT egress states toward public destinations. Guest link-local v6 states are
  # left to expire — pfctl -k cannot address zone-scoped fe80 sources.
  for src in "$METAL4" "$METAL6" "$HERMES4" "$HERMES6" "$BB4" "$BB6"; do
    pfctl -k "$src" || { echo "host-pf: FATAL state kill failed for $src" >&2; exit 1; }
  done
  for dst in $(ifconfig | awk '$1 == "inet" { print $2 }'); do
    pfctl -k "$VMNET_NET" -k "$dst" || { echo "host-pf: FATAL state kill failed for $VMNET_NET -> $dst" >&2; exit 1; }
  done
fi

date +%s > "$MARKER" || { echo "host-pf: FATAL cannot write enforcement marker $MARKER" >&2; exit 1; }

echo "host-pf: $ANCHOR keyed to metal={$METAL4, $METAL6} hermes=$HERMES4 bluebubbles=$BB4; metal -> host $PORTS allowed; vmnet $VMNET_NET -> self blocked on $VMNET_IF (dhcp+dns open)"
