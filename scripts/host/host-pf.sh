#!/bin/bash
# scripts/host/host-pf.sh — one refresh tick of the host's fleet-lockdown pf anchor: resolve the
# three fleet VMs' current tailnet IPs (v4 + v6) plus the Tart vmnet bridge, then re-key the
# anchor so ONLY metal reaches the host's model ports (rapid-mlx + mlx-audio STT), no fleet VM
# reaches anything else on the host over the tailnet, and the vmnet side-door — any host-bound
# service reachable at the bridge gateway 192.168.64.1, past both the tailnet ACL and the
# tailnet-IP rules — is shut. Personal devices and non-fleet traffic never match — every rule is
# keyed on the resolved fleet addresses or the fleet's vmnet subnet, never a CGNAT-wide source.
#
# The anchor attaches at com.apple/999.yclaw.host — a CHILD of the stock /etc/pf.conf's
# `anchor "com.apple/*"` wildcard call — so the targeted load is EVALUATED immediately: on first
# install, and again within one tick of any OS-update reset of /etc/pf.conf. A root-level anchor
# would sit orphaned until a boot-time full reload (`pfctl -f /etc/pf.conf` live is off the
# table — it flushes the dynamically-inserted Internet-Sharing/vmnet calls, severing VM NAT).
# Main-ruleset order also puts the com.apple/* call BEFORE pf.conf's `anchor "vnc"`, whose
# <vnc_allowed> table quick-passes 192.168.0.0/16 + the tailnet to 5900-5902 — so this anchor's
# quick block beats the VNC allow for fleet sources. Apple's own children (200.AirDrop,
# 250.ApplicationFirewall) evaluate ahead of 999.* alphabetically; both are narrow, not blanket
# passes.
#
# A TEMPLATE, not run from the repo: `setup.sh host-pf` bakes @@TAILSCALE@@ (a root-owned CLI
# copy under /usr/local/lib/yclaw — a root daemon must never exec user-writable bits) and
# @@PF_PORTS@@ (the manifest's host rapid-mlx/mlx-audio ports) and installs it beside wait.sh +
# pf.sh under /usr/local/lib/yclaw, where the com.yclaw.host-pf-refresh LaunchDaemon (root, in
# /Library/LaunchDaemons: a RunAtLoad + KeepAlive sleep-loop — StartInterval silently stops
# firing on Tahoe) re-runs it every 300s.
# $1 = poll attempts for tailscaled to reach Running (default 10, 2s apart).
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
TAILSCALE=@@TAILSCALE@@
ANCHOR=com.apple/999.yclaw.host
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$YCLAW_LIB/wait.sh"
# shellcheck source=scripts/lib/pf.sh
. "$YCLAW_LIB/pf.sh"

PORTS="@@PF_PORTS@@"

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
  echo "# vmnet side-door: a fleet VM reaches ANY host-bound service at the bridge gateway"
  echo "# ($VMNET_HOST), past the tailnet ACL and the tailnet-IP rules above. Every rule is"
  echo "# dest-scoped to the host's own vmnet address: NAT'd VM->internet traffic arrives on"
  echo "# $VMNET_IF with a PUBLIC destination, so it falls through untouched (a blanket 'to any'"
  echo "# block on the bridge would sever the fleet's NAT egress). DHCP renews (67/68 — the"
  echo "# initial broadcast lease never matches: dst 255.255.255.255) and DNS (53) stay open;"
  echo "# the VMs lease and resolve against the host-side vmnet daemons."
  echo "pass in quick on $VMNET_IF proto udp from $VMNET_NET to $VMNET_HOST port { 53, 67, 68 }"
  echo "pass in quick on $VMNET_IF proto tcp from $VMNET_NET to $VMNET_HOST port 53"
  echo "block drop in quick on $VMNET_IF from $VMNET_NET to $VMNET_HOST"
} > "$RULES"

# Targeted `pfctl -a $ANCHOR -f` load (NEVER `pfctl -f /etc/pf.conf` on the host — a full reload
# flushes the vmnet/Internet-Sharing NAT anchors the VMs need); --wire-load-only appends the
# boot-time load line idempotently (the com.apple/* wildcard already CALLS the anchor — see the
# header, and a re-run self-heals an OS-update pf.conf reset); --enable re-asserts the refcounted
# `pfctl -E` every tick (macOS boots pf loaded-but-DISABLED), covering an out-of-band `pfctl -d`
# the way metal's engine watchdog does.
install_pf_anchor "$ANCHOR" "$RULES" --wire-load-only --enable
rc=$?
rm -f "$RULES"
[ "$rc" -eq 0 ] || exit "$rc"

# Loaded is not evaluated: this child ruleset only runs because the main ruleset's
# `anchor "com.apple/*"` call reaches it. The call ships in the stock /etc/pf.conf, but a custom
# pf.conf could drop it — then the anchor is a no-op and claiming enforcement would be a lie.
pfctl -sr 2>/dev/null | grep -qF 'anchor "com.apple/*"' \
  || { echo "host-pf: FATAL main ruleset lacks the com.apple/* wildcard call — $ANCHOR loaded but NOT evaluated" >&2; exit 1; }

echo "host-pf: $ANCHOR keyed to metal={$METAL4, $METAL6} hermes=$HERMES4 bluebubbles=$BB4; metal -> host $PORTS allowed; vmnet $VMNET_NET -> $VMNET_HOST blocked on $VMNET_IF (dhcp+dns open)"
