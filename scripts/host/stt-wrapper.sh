#!/usr/bin/env bash
# ~/.yclaw/bin/stt-wrapper.sh — host LaunchAgent for the STT stack (installed verbatim by setup.sh).
# Execs `athome serve activator`: tailnet :8765, lazy `athome serve stt` child on :18765.
set -euo pipefail

# wait.sh (wait_tailscale_ip) rides as a sibling in ~/.yclaw/bin — source it inline.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$BIN_DIR/wait.sh"

# launchd hands a gui agent no brew PATH; pin the tailscale CLI (wait.sh's binary seam).
# shellcheck disable=SC2034  # read by wait_tailscale_ip in the sourced wait.sh
TAILSCALE=/opt/homebrew/bin/tailscale

# Tailnet-only bind (never 0.0.0.0) — see the rapid-mlx wrapper. Fails LOUD on exhaustion.
HOST_IP="$(wait_tailscale_ip)"
export ATHOME_SERVE_ACTIVATOR_HOST="$HOST_IP"
# Override the activator's default 8000/18000 so the child never squats rapid-mlx's 127.0.0.1:18000.
export ATHOME_SERVE_ACTIVATOR_PORT=8765
export ATHOME_SERVE_ACTIVATOR_CHILD_PORT=18765
# Only the transcription POST wakes the child; GET /v1/models + /health answer without a load.
export ATHOME_SERVE_ACTIVATOR_WAKE_PATHS='["/v1/audio/transcriptions"]'

VENV="$HOME/.yclaw/state/stt/venv"
# Absolute child command (shlex.split, no expansion); {LISTEN_FD} = the pre-bound :18765 listener fd.
export ATHOME_SERVE_ACTIVATOR_COMMAND="$VENV/bin/athome serve stt --fd {LISTEN_FD}"

exec "$VENV/bin/athome" serve activator
