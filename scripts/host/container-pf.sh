#!/bin/bash
# scripts/host/container-pf.sh — refresh tick of the container-hermes EGRESS anchor
# (com.apple/000.yclaw.container): denies the OCI agent container self+fleet+private and fences its
# public egress to tailscaled's transport. Design, ordering, and postures: cc-notes note 9623c9a.
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

# Sorts BEFORE host-pf's 000.yclaw.host under the com.apple/* wildcard so this TOTAL anchor
# adjudicates its bridge first (host-pf's model-port pass is not interface-scoped) — note 9623c9a.
ANCHOR=com.apple/000.yclaw.container
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/pf.sh
. "$YCLAW_LIB/pf.sh"

# config.toml subnet override (subnet = "192.168.72.1/24"); constants like host-pf's 64.x.
CNET=192.168.72.0/24
CGW=192.168.72.1
CBCAST=192.168.72.255

# Epoch of the last verified tick — launchd reports the loop healthy even when ticks fail, so marker
# staleness is the doctor signal.
MARKER="$YCLAW_LIB/container-pf.last-ok"

# Resolve the bridge carrying the gateway each tick (the number drifts across restarts). Absent =
# network not up yet — fail LOUD (backoff retries) rather than leave the bridge unpoliced.
CIF="$(ifconfig | awk -v ip="$CGW" \
  '/^[a-z0-9]+: flags=/ { sub(":", "", $1); ifc = $1 } $1 == "inet" && $2 == ip { print ifc; exit }')"
[ -n "$CIF" ] || { echo "container-pf: FATAL no interface carries $CGW (container network not up — apiserver/container-hermes not started?) — previous ruleset left in force" >&2; exit 1; }

RULES=$(mktemp) || { echo "container-pf: ERROR mktemp failed for pf rules" >&2; exit 1; }
{
  echo "# container-pf: TOTAL anchor for apple/container default bridge $CIF ($CNET) — every rule"
  echo "# \`in quick on $CIF\` so a NET_ADMIN guest cannot forge past it, terminal-deny closed."
  echo "# Rationale: cc-notes 9623c9a. First rule keeps host-initiated flows' replies alive."
  echo "pass out quick on $CIF to $CNET keep state"
  echo "# Only permitted self access: DNS + DHCP to the vmnet gateway (lease + bootstrap resolution"
  echo "# before the container's own MagicDNS)."
  echo "pass in quick on $CIF proto udp from $CNET to $CGW port { 53, 67, 68 }"
  echo "pass in quick on $CIF proto tcp from $CNET to $CGW port 53"
  echo "pass in quick on $CIF proto udp from 0.0.0.0 to 255.255.255.255 port 67"
  echo "# tier-1 lateral-movement deny (\`from any\` = forged source too); \`self\` closes the"
  echo "# rapid-mlx/mlx-audio leak, CGNAT 100.64/10 = every tailnet IP as cleartext. MUST precede"
  echo "# tier-2's \`to any\` passes, which would otherwise readmit self/private on the open ports."
  echo "block drop in quick on $CIF from any to self"
  echo "block drop in quick on $CIF inet  from any to 224.0.0.0/4"
  echo "block drop in quick on $CIF from any to 255.255.255.255"
  echo "block drop in quick on $CIF from any to $CBCAST"
  echo "block drop in quick on $CIF inet6 from any to ff00::/8"
  echo "block drop in quick on $CIF inet  from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }"
  echo "block drop in quick on $CIF inet6 from any to { fc00::/7, fe80::/10 }"
  echo "# tier-2 MODERATE: self+private denied above, so \`to any\` is public-only. Permit the"
  echo "# container's tailscaled transport (DNS, WG/disco UDP, DERP/control 443); the terminal deny"
  echo "# drops every other port and any forged source."
  echo "pass in quick on $CIF proto udp from $CNET to any port 53"
  echo "pass in quick on $CIF proto tcp from $CNET to any port 53"
  echo "pass in quick on $CIF proto udp from $CNET to any"
  echo "pass in quick on $CIF proto tcp from $CNET to any port 443"
  echo "block drop in quick on $CIF from any to any"
} > "$RULES"

# Targeted anchor load only (NEVER `pfctl -f /etc/pf.conf` — flushes the vmnet NAT the fleet needs);
# --wire-load-only appends the boot load line idempotently, --enable re-asserts pf un-refcounted.
install_pf_anchor "$ANCHOR" "$RULES" --wire-load-only --enable
rc=$?
rm -f "$RULES"
[ "$rc" -eq 0 ] || exit "$rc"

# Loaded is not evaluated: this child runs only via the main `anchor "com.apple/*"` call. Exact-line
# match — pfctl -sr renders the stock call as `anchor "com.apple/*" all`.
pfctl -sr 2>/dev/null | grep -qxF 'anchor "com.apple/*" all' \
  || { echo "container-pf: FATAL main ruleset lacks the com.apple/* wildcard call — $ANCHOR loaded but NOT evaluated" >&2; exit 1; }

date +%s > "$MARKER" || { echo "container-pf: FATAL cannot write enforcement marker $MARKER" >&2; exit 1; }
echo "container-pf: $ANCHOR keyed to bridge $CIF ($CNET); container denied self+fleet+private+CGNAT; egress limited to DNS+WG+443 (tier-2 moderate)"
