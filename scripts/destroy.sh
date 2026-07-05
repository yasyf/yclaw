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
for node in metal hermes bluebubbles; do
  launchctl bootout "gui/$(id -u)/com.yclaw.tart-${node}" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.yclaw.tart-${node}.plist"
done
launchctl bootout "gui/$(id -u)/com.yclaw.metal-nightly-bounce" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.yclaw.metal-nightly-bounce.plist"

# `vault` was retired into metal but its disk persists; delete it too.
for vm in metal hermes bluebubbles vault; do
  tart stop "$vm" 2>/dev/null || true
  tart delete "$vm" 2>/dev/null || true
done

# yclaw nodes are PERSISTENT tailnet nodes (they don't self-reap), so delete their device
# registrations too — else a later redeploy drifts MagicDNS to hermes-1/metal-1. Best-effort:
# skips cleanly if TAILSCALE_API_KEY is unset (scripts/nuke-tailnet.sh).
./scripts/nuke-tailnet.sh || true
