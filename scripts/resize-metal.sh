#!/usr/bin/env bash
# resize-metal.sh — shrink the metal guest to its post-Phase-6 footprint (2 vCPU / 16 GB) and
# drop the retired hfhub/mlxaudio shares. USER-run in Terminal.app; needs no sudo, no keychain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/manifest.sh
source "$REPO_ROOT/scripts/lib/manifest.sh"
# shellcheck source=scripts/lib/wait.sh
source "$REPO_ROOT/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/launchd.sh
source "$REPO_ROOT/scripts/lib/launchd.sh"

need tart launchctl tailscale

HOME_DIR="$HOME"
STATE_DIR="$HOME_DIR/.yclaw/state"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
TART_BIN="/opt/homebrew/bin/tart"
LOGS_DIR="$HOME_DIR/Library/Logs/Tart"

CPUS=2
MEM_MB=16384
LABEL="com.yclaw.tart-metal"

# Stop the runner so `tart set` can resize the stopped VM — bootout drops KeepAlive so it can't relaunch.
log "Booting out $LABEL so metal can be resized ..."
bootout_drain "gui/$(id -u)" "$LABEL"

log "Resizing metal to ${CPUS} vCPU / ${MEM_MB} MB ..."
"$TART_BIN" set metal --cpu "$CPUS" --memory "$MEM_MB"

# Rewrite the runner plist with the reduced --dir set (hfhub + mlxaudio dropped) and reload it. Keep
# this --dir set in sync with scripts/setup.sh's metal write_agent call.
log "Rewriting + reloading $LABEL with the reduced share set ..."
write_agent metal \
  run metal \
  --no-graphics \
  "--dir=metalsecrets:$STATE_DIR/hosts/metal:ro" \
  "--dir=agentvault:$STATE_DIR/agent-vault" \
  "--dir=cliproxy:$STATE_DIR/cli-proxy-api" \
  "--dir=repo:$HOME_DIR/Code/yclaw:ro"

launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

log "Waiting for metal to come back over tailscale ssh ..."
wait_for "metal reachable over tailscale ssh" 60 5 tailscale ssh root@metal -- true

# Drop ONLY the retired guest mlx-audio venv (the host's live host-venv/ stays). Its backing share is
# gone after the resize, so this is host-side cleanup; [ -d ]-guarded and idempotent.
GUEST_STT_VENV="$STATE_DIR/mlx-audio/venv"
if [ -d "$GUEST_STT_VENV" ]; then
  log "Removing the retired guest mlx-audio venv ($GUEST_STT_VENV) ..."
  rm -rf "$GUEST_STT_VENV"
fi

log "metal resized to ${CPUS} vCPU / ${MEM_MB} MB and back on the tailnet."
