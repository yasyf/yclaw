#!/usr/bin/env bash
# ~/.yclaw/bin/rapid-mlx-wrapper.sh — host LaunchAgent entry for the rapid-mlx serving stack.
#
# Installed by scripts/setup.sh, which copies this file to ~/.yclaw/bin/ and sed-substitutes
# @@QWEN_MODEL@@ from nixos/models.nix (the single source of truth for the model id). It execs the
# probe-safe idle-unload proxy (model-activator.py): the activator binds this node's tailnet IPv4:8000
# and lazily manages a rapid-mlx child on 127.0.0.1:18000, unloading it after IDLE_SECONDS idle.
#
# The child serve flags mirror darwin/metal.nix's rapidMlxWrapper verbatim, except the listener: the
# activator binds 127.0.0.1:18000 itself and hands the pre-bound socket down at spawn (rapid-mlx
# --listen-fd socket activation), so no other local process can squat the child address. The venv +
# weights are provisioned by setup.sh; HF_HUB_CACHE + IDLE_SECONDS ride in from the LaunchAgent plist env.
set -euo pipefail

# wait.sh (wait_tailscale_ip) is installed as a sibling in ~/.yclaw/bin — source it inline, the same
# role darwin/metal.nix's embedded waitLib plays for its in-guest wrappers.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$BIN_DIR/wait.sh"

# launchd hands a gui agent no brew PATH; pin the tailscale CLI (wait.sh's binary seam). The version
# skew warning against the mise-built daemon is stderr-only, which wait_tailscale_ip discards.
# shellcheck disable=SC2034  # read by wait_tailscale_ip in the sourced wait.sh
TAILSCALE=/opt/homebrew/bin/tailscale

# Bind the activator to THIS node's tailnet (CGNAT 100.64.0.0/10) IPv4, never 0.0.0.0 — the port stays
# reachable only over the tailnet even before the host pf gate lands. wait_tailscale_ip fails LOUD on
# exhaustion; set -e aborts and KeepAlive retries once tailscaled has assigned an address.
HOST_IP="$(wait_tailscale_ip)"
export HOST_IP
export PORT=8000
export CHILD_PORT=18000

VENV="$HOME/.yclaw/state/rapid-mlx/venv"
# The rapid-mlx child command the activator spawns via shlex.split — an ABSOLUTE venv path (no ~, no
# env expansion happens there). {LISTEN_FD} is the activator's substitution token for the fd of the
# pre-bound 127.0.0.1:18000 listener it passes down. int8 KV over the int4 default buys tool-call
# fidelity; --pflash off because pflash lossily compresses prompts and breaks tool calls (darwin/metal.nix).
export RAPID_MLX_CMD="$VENV/bin/rapid-mlx serve @@QWEN_MODEL@@ --listen-fd {LISTEN_FD} --max-num-seqs 1 --kv-cache-dtype int8 --pflash off --default-temperature 0.6 --default-top-p 0.95 --default-top-k 20 --default-repetition-penalty 1.05"

exec "$VENV/bin/python" "$BIN_DIR/model-activator.py"
