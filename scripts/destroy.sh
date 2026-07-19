#!/usr/bin/env bash
# Tear down the yclaw tart VMs and containers (boot out their launchd runners first so KeepAlive
# can't relaunch them mid-teardown), remove the runner plists, then delete their tailnet device
# registrations. Leaves host state/keychain alone — use scripts/nuke.sh for that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
LIB="$REPO_ROOT/scripts/lib"
# shellcheck source=scripts/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=scripts/lib/wait.sh
. "$LIB/wait.sh"
# shellcheck source=scripts/lib/launchd.sh
. "$LIB/launchd.sh"
# shellcheck source=scripts/lib/manifest.sh
. "$LIB/manifest.sh"

# Node lists derive from machines.json, never a hardcoded literal.
TART_NODES="$(manifest_list '[.machines | to_entries[] | select(.value.tart_vm != null) | .key]')"
CONTAINER_NODES="$(manifest_list '[.machines | to_entries[] | select(.value.managed_by == "container") | .key]')"

# bootout is async: DRAIN each runner (best-effort) before the delete below races a relaunch.
for node in $TART_NODES; do
  label="$(manifest_get ".machines.host.services[\"tart-${node}\"].launchd.label")"
  bootout_drain "gui/$(id -u)" "$label" || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
bounce_label="$(manifest_get '.machines.host.services["metal-nightly-bounce"].launchd.label')"
bootout_drain "gui/$(id -u)" "$bounce_label" || true
rm -f "$HOME/Library/LaunchAgents/$bounce_label.plist"

# Container supervisors: DRAIN before removal — a supervisor tick mid-drain recreates the container.
for node in $CONTAINER_NODES; do
  label="$(manifest_get ".machines.host.services[\"container-${node}\"].launchd.label")"
  bootout_drain "gui/$(id -u)" "$label" || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
# The egress-pf daemon is a system LaunchDaemon (root); best-effort sudo prompts interactively, like
# bluebubbles-setup.sh's privileged launchd steps.
pf_label="$(manifest_get '.machines.host.services["container-pf-refresh"].launchd.label')"
sudo launchctl bootout "system/$pf_label" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$pf_label.plist" 2>/dev/null || true
for node in $CONTAINER_NODES; do
  "$CONTAINER_BIN" rm -f "$node" 2>/dev/null || true
done

for vm in $TART_NODES; do
  tart stop "$vm" 2>/dev/null || true
  tart delete "$vm" 2>/dev/null || true
done

# yclaw nodes are PERSISTENT tailnet nodes (they don't self-reap), so delete their device
# registrations too — else a later redeploy drifts MagicDNS to hermes-1/metal-1. Best-effort:
# skips cleanly if TAILSCALE_API_KEY is unset (scripts/nuke-tailnet.sh).
./scripts/nuke-tailnet.sh || true
