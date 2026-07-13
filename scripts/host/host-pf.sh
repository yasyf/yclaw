#!/bin/bash
# scripts/host/host-pf.sh — one refresh tick of the `com.yclaw.host` pf anchor: resolve the three
# fleet VMs' current tailnet IPs (v4 + v6) and re-key the anchor so ONLY metal reaches the host's
# model ports (rapid-mlx + mlx-audio STT) and NO fleet VM reaches anything else on the host.
# Personal devices and non-fleet traffic never match — every rule is keyed on the resolved fleet
# addresses, never a CGNAT-wide source.
#
# A TEMPLATE, not run from the repo: `setup.sh host-pf` bakes @@TAILSCALE@@ + @@PF_PORTS@@ (the
# manifest's host rapid-mlx/mlx-audio ports) and installs it beside wait.sh + pf.sh under
# /usr/local/lib/yclaw, where the com.yclaw.host-pf-refresh LaunchDaemon (root, in
# /Library/LaunchDaemons: a RunAtLoad + KeepAlive sleep-loop — StartInterval silently stops
# firing on Tahoe) re-runs it every 300s.
# $1 = poll attempts for tailscaled to reach Running (default 10, 2s apart).
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
TAILSCALE=@@TAILSCALE@@
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$YCLAW_LIB/wait.sh"
# shellcheck source=scripts/lib/pf.sh
. "$YCLAW_LIB/pf.sh"

PORTS="@@PF_PORTS@@"

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
} > "$RULES"

# Targeted `pfctl -a com.yclaw.host -f` load (NEVER `pfctl -f /etc/pf.conf` on the host — a full
# reload flushes the vmnet/Internet-Sharing NAT anchors the VMs need); --wire-pfconf appends the
# boot-time anchor/load lines idempotently; --enable re-asserts the refcounted `pfctl -E` every
# tick (macOS boots pf loaded-but-DISABLED), covering an out-of-band `pfctl -d` the way metal's
# engine watchdog does.
install_pf_anchor com.yclaw.host "$RULES" --wire-pfconf --enable
rc=$?
rm -f "$RULES"
[ "$rc" -eq 0 ] && echo "host-pf: com.yclaw.host keyed to metal={$METAL4, $METAL6} hermes=$HERMES4 bluebubbles=$BB4; metal -> host $PORTS allowed"
exit "$rc"
