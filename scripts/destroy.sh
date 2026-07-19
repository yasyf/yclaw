#!/usr/bin/env bash
# Tear down every yclaw tart VM (boot out its launchd runner first so KeepAlive can't relaunch it
# mid-teardown), remove the runner plists, then delete the VMs' tailnet device registrations.
# Covers metal, hermes, bluebubbles, and the retired `vault` VM whose disk lingers at
# ~/.tart/vms/vault. Leaves host state/keychain alone — use scripts/nuke.sh for that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# scripts/setup.sh writes the runners as `com.yclaw.tart-<node>` (NOT the old nix-darwin
# `org.nixos.*` labels). Boot them out so KeepAlive can't relaunch the VM mid-teardown.
for node in metal bluebubbles; do
  launchctl bootout "gui/$(id -u)/com.yclaw.tart-${node}" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.yclaw.tart-${node}.plist"
done
launchctl bootout "gui/$(id -u)/com.yclaw.metal-nightly-bounce" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.yclaw.metal-nightly-bounce.plist"

# hermes is a container now, not a tart VM: boot out its supervisor + egress-pf daemon so neither
# recreates the container mid-teardown, then force-remove it.
launchctl bootout "gui/$(id -u)/com.yclaw.container-hermes" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.yclaw.container-hermes.plist"
# The egress-pf daemon is a system LaunchDaemon (root); best-effort sudo prompts interactively, like
# bluebubbles-setup.sh's privileged launchd steps.
sudo launchctl bootout "system/com.yclaw.container-pf-refresh" 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.yclaw.container-pf-refresh.plist 2>/dev/null || true
/opt/homebrew/bin/container rm -f hermes 2>/dev/null || true

# `vault` was retired into metal but its disk persists; delete it too.
for vm in metal hermes bluebubbles vault; do
  tart stop "$vm" 2>/dev/null || true
  tart delete "$vm" 2>/dev/null || true
done

# yclaw nodes are PERSISTENT tailnet nodes (they don't self-reap), so delete their device
# registrations too — else a later redeploy drifts MagicDNS to hermes-1/metal-1. Best-effort:
# skips cleanly if TAILSCALE_API_KEY is unset (scripts/nuke-tailnet.sh).
./scripts/nuke-tailnet.sh || true
