#!/usr/bin/env bash
# ~/.yclaw/bin/mlx-audio-wrapper.sh — host LaunchAgent entry for the mlx-audio STT server.
#
# Installed by scripts/setup.sh, which copies this file to ~/.yclaw/bin/ and sed-substitutes
# @@STT_MODEL@@ from nixos/models.nix. It execs the single-worker STT server (stt-server.py, shared
# verbatim with darwin/metal.nix's sttWrapper — the multi-threaded mlx_audio.server crashes
# granite-speech on per-thread MLX streams) bound to this node's tailnet IPv4:8765. The venv +
# granite-speech weights are provisioned by setup.sh; HF_HUB_CACHE rides in from the plist env.
set -euo pipefail

# wait.sh (wait_tailscale_ip) is installed as a sibling in ~/.yclaw/bin — source it inline, the same
# role darwin/metal.nix's embedded waitLib plays for its in-guest wrappers.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$BIN_DIR/wait.sh"

# launchd hands a gui agent no brew PATH; pin the tailscale CLI (wait.sh's binary seam).
# shellcheck disable=SC2034  # read by wait_tailscale_ip in the sourced wait.sh
TAILSCALE=/opt/homebrew/bin/tailscale

# Tailnet-only bind (never 0.0.0.0) — see the rapid-mlx wrapper. Fails LOUD on exhaustion.
STT_HOST="$(wait_tailscale_ip)"
export STT_HOST
export STT_MODEL="@@STT_MODEL@@"
export STT_PORT=8765

VENV="$HOME/.yclaw/state/mlx-audio/host-venv"
exec "$VENV/bin/python" "$BIN_DIR/stt-server.py"
