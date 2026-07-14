#!/bin/bash
# scripts/host/host-pf.sh — one refresh tick of the host's fleet-lockdown pf anchor: resolve the
# three fleet VMs' current tailnet IPs (v4 + v6) plus the Tart vmnet bridge, then re-key the
# anchor so ONLY metal reaches the host's model ports (rapid-mlx + mlx-audio STT), no fleet VM
# reaches anything else on the host over the tailnet, and the vmnet side-door is shut: Darwin's
# weak-host model answers a bridge-ingress packet addressed to ANY host address — the bridge
# gateway 192.168.64.1, the LAN IP, even the tailnet IP over a forced VM route — past both the
# tailnet ACL and the tailnet-IP rules, and a root-capable guest can forge ANY source address, so
# the bridge blocks key `from any` (dests: self + multicast + broadcast) and the whole bridge
# group evaluates before the fleet rules. Personal devices and non-fleet traffic never match —
# every rule is keyed on the resolved fleet addresses or scoped to the fleet-only vmnet bridge,
# never a CGNAT-wide source. A single carve-out passes fleet->gateway UDP on the host's pinned tailscaled
# port (WG_PORT) so host<->fleet magicsock can land the sub-ms 192.168.64.x path instead of the
# LAN-reflexive hairpin or DERP; it admits ONLY encrypted WireGuard, so it never touches the model
# plane (pf polices the decrypted 100.x tunnel on utunN independently — see the carve-out comment).
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
VMNET_BCAST=192.168.64.255

# Pinned magicsock port (machines.json host.wireguard_port). Admits disco only — receiving it
# needs the disable-bind nodeAttrs grant in tailnet/policy.hujson (Darwin IP_BOUND_IF).
WG_PORT=@@WG_PORT@@

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
  echo "# Bridge group FIRST, fleet group second: a root-capable guest can put ANY source address on"
  echo "# the bridge — one outside $VMNET_NET slips a subnet-keyed block, and a forged metal tailnet"
  echo "# source would hit the fleet model-port pass — so every bridge-ingress packet is adjudicated"
  echo "# by these \`on $VMNET_IF\` rules (ingress blocks keyed \`from any\`) before a fleet-IP rule"
  echo "# can see it. The fleet rules police the DECRYPTED tunnel path (utunN), whose packets never"
  echo "# arrive on $VMNET_IF."
  echo "#"
  echo "# The pass out keeps host-initiated vmnet flows (packer image builds, \`yclaw vm ssh\`"
  echo "# pre-tailnet) alive: pf's implicit default pass creates NO state, so their replies to"
  echo "# $VMNET_HOST would otherwise die on the to-self block. DNS (53) and DHCP renews (67/68)"
  echo "# stay open against the host-side vmnet daemons, dest-scoped to the gateway."
  echo "pass out quick on $VMNET_IF to $VMNET_NET keep state"
  echo "pass in quick on $VMNET_IF proto udp from $VMNET_NET to $VMNET_HOST port { 53, 67, 68 }"
  echo "pass in quick on $VMNET_IF proto tcp from $VMNET_NET to $VMNET_HOST port 53"
  echo "# WG/disco to the pinned port: encrypted ciphertext only — pf polices the decrypted tunnel"
  echo "# (utunN, 100.x) separately. Receiving needs the disable-bind grant (tailnet/policy.hujson)."
  echo "pass in quick on $VMNET_IF proto udp from $VMNET_NET to $VMNET_HOST port $WG_PORT"
  echo "# A fresh guest's DHCP DISCOVER (0.0.0.0 -> 255.255.255.255) is the one legitimate broadcast,"
  echo "# passed explicitly now that broadcast dests are blocked below. Renewals are unicast to the"
  echo "# gateway (67/68 above); a REBIND broadcast from an assigned source stays blocked — worst"
  echo "# case the lease expires and the guest re-DISCOVERs from 0.0.0.0, which this rule passes."
  echo "pass in quick on $VMNET_IF proto udp from 0.0.0.0 to 255.255.255.255 port 67"
  echo "# Everything else inbound on the bridge dies here, whatever the source claims. \`self\` is"
  echo "# every address on every host interface, both families, re-expanded at each tick's load —"
  echo "# Darwin's weak-host model answers a bridge-ingress packet addressed to ANY of them: the"
  echo "# gateway $VMNET_HOST, the LAN IP, even the tailnet IP over a forced VM route. Multicast and"
  echo "# broadcast dests are NOT in \`self\` yet still reach 0.0.0.0/::-bound host listeners (mDNS/"
  echo "# SSDP responders; every UDP daemon on the subnet broadcast), so they get their own"
  echo "# dest-scoped blocks; vmnet v6 is link-local only — no DHCPv6/RAs to pass — and blocking"
  echo "# ff00::/8 (neighbor discovery included) costs nothing since every guest->host v6 dest is"
  echo "# denied anyway. NAT'd VM->internet traffic arrives on $VMNET_IF with a PUBLIC unicast"
  echo "# destination — never \`self\`, multicast, or broadcast — so the fleet's egress falls"
  echo "# through untouched."
  echo "block drop in quick on $VMNET_IF from any to self"
  echo "block drop in quick on $VMNET_IF inet from any to 224.0.0.0/4"
  echo "block drop in quick on $VMNET_IF from any to 255.255.255.255"
  echo "block drop in quick on $VMNET_IF from any to $VMNET_BCAST"
  echo "block drop in quick on $VMNET_IF inet6 from any to ff00::/8"
  echo "# Fleet tailnet rules — keyed on bare fleet IPs, both address families: pf cannot match"
  echo "# tailnet tags (that policy lives in tailnet/policy.hujson), and no \`on utunN\` scope — the"
  echo "# utun unit is dynamic across tailscaled restarts, the metal anchor (the prior art) keys on"
  echo "# bare IPs too, and an unscoped IP block is strictly tighter (a spoofed fleet source arriving"
  echo "# on vmnet toward a public dest dies here instead of reaching NAT). The pass out is"
  echo "# load-bearing: host-initiated flows to the fleet (tailscale ssh, yclaw probes, bootstrap)"
  echo "# get state entries, and pf consults state BEFORE rules, so fleet replies to those flows"
  echo "# never reach the block."
  echo "pass out quick to $FLEET keep state"
  echo "pass in quick proto tcp from { $METAL4, $METAL6 } to any port $PORTS"
  echo "block drop in quick from $FLEET to any"
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
  # left to expire — pfctl -k cannot address zone-scoped fe80 sources. The pair-kill also drops
  # any live fleet->gateway WireGuard UDP (:WG_PORT) states, which is harmless: WireGuard
  # re-handshakes statelessly and magicsock re-establishes the vmnet path within seconds.
  for src in "$METAL4" "$METAL6" "$HERMES4" "$HERMES6" "$BB4" "$BB6"; do
    pfctl -k "$src" || { echo "host-pf: FATAL state kill failed for $src" >&2; exit 1; }
  done
  for dst in $(ifconfig | awk '$1 == "inet" { print $2 }'); do
    pfctl -k "$VMNET_NET" -k "$dst" || { echo "host-pf: FATAL state kill failed for $VMNET_NET -> $dst" >&2; exit 1; }
  done
fi

date +%s > "$MARKER" || { echo "host-pf: FATAL cannot write enforcement marker $MARKER" >&2; exit 1; }

echo "host-pf: $ANCHOR keyed to metal={$METAL4, $METAL6} hermes=$HERMES4 bluebubbles=$BB4; metal -> host $PORTS allowed; $VMNET_IF ingress from any source blocked to self+multicast+broadcast (dhcp+dns+wg open)"
