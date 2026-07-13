#!/usr/bin/env bash
# De-Nix'd host bring-up: the runtime role that darwin/host.nix used to play, as a plain
# idempotent shell script. The host runs NO Nix — just Homebrew `tart` + `gum`, the existing
# Tailscale daemon, the `~/.yclaw/state` virtiofs source, three launchd VM runners, and the host AI
# serving stack (the rapid-mlx activator + mlx-audio STT, §5 below).
#
# Re-runnable: brew installs are no-ops when present, mkdir -p is idempotent, and each
# LaunchAgent is rewritten then re-bootstrapped (bootout-before-bootstrap) so a changed plist
# takes effect. `setup.sh host-serving` re-runs ONLY §5 (the serving stack) — the full run's §3
# bootout-before-bootstrap restarts the LIVE tart VM runners. `setup.sh host-pf` (root-gated,
# NOT part of the full run — the apply is deliberately operator-gated, like the hand-applied
# tailnet ACL it backstops) installs §6: the host pf anchor (com.apple/000.yclaw.host) + its
# refresh daemon.
#
# ── darwin/host.nix responsibility mapping ───────────────────────────────────────────────────
# DELETED (gone with the host services, which now run inside the `metal` VM):
#   • nix.linux-builder (the aarch64-linux build VM)        — host no longer builds anything
#   • launchd agents mlx-qwen / parakeet-stt / cliproxyapi  — retired; live inside metal
#   • environment.etc."cli-proxy-api/config.yaml"           — cliproxy config lives in metal
#   • the app-firewall allowlist (socketfilterfw add/unblock for cli-proxy-api + MLX python)
#                                                           — cliproxy stays in metal; the MLX-python
#                                                             half RETURNS in §5 (host serving stack)
#   • all nix-darwin scaffolding (stateVersion, primaryUser, trusted-users, pam.sudo_local,
#     homebrew module)                                      — replaced by this script
#   • the tart-vault runner                                 — vault VM retired; its agent-vault
#                                                             role now runs inside metal
# MOVED here (was nix-darwin, now plain shell):
#   • Homebrew tart + gum install (cirruslabs/cli tap)      — ensure_brew + brew install below
#   • the tart VM runners (launchd.user.agents.tart-*)      — write_agent + bootstrap below
# PRESERVED (left untouched by this script):
#   • the mise-built tailscaled 1.98.5 system daemon with `tailscale ssh` — detected, never
#     clobbered; `brew install tailscale` runs ONLY when no tailscaled exists
#   • the pf VNC anchor                                     — OFF by default (no VNC on the host; the
#     §5 model ports get their own pf gate, §6 `setup.sh host-pf`); see ENABLE_VNC_ANCHOR below
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

HOME_DIR="$HOME"
STATE_DIR="$HOME_DIR/.yclaw/state"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
TART_BIN="/opt/homebrew/bin/tart"
LOGS_DIR="$HOME_DIR/Library/Logs/Tart"
# The host serving stack (§5): the activator + wrappers install under ~/.yclaw/bin, and their
# LaunchAgents log under ~/Library/Logs/yclaw (distinct from the Tart runner logs above).
BIN_DIR="$HOME_DIR/.yclaw/bin"
MODEL_LOGS_DIR="$HOME_DIR/Library/Logs/yclaw"

# The host's REGULAR Hugging Face hub cache (NOT the state tree). metal mounts this as the
# `hfhub` share and serves models (rapid-mlx + STT) from it, so host and VM share ONE model cache and
# `hf download` on the host lands where the VM reads. Only the `hub/` subdir is shared — the
# sibling `token` file stays on the host and never enters the VM.
HF_HUB_DIR="${HF_HOME:-$HOME_DIR/.cache/huggingface}/hub"

# pf VNC anchor: OFF by default. The host runs no VNC-exposed model services anymore, so there
# is nothing to gate. Set ENABLE_VNC_ANCHOR=1 only if a VNC service is reintroduced on the host.
ENABLE_VNC_ANCHOR="${ENABLE_VNC_ANCHOR:-0}"

# --- helpers -----------------------------------------------------------------

# Write one tart LaunchAgent plist and (re)load it. bootout-before-bootstrap so a changed plist
# replaces the running agent instead of erroring on "service already loaded".
write_agent() {
  local node="$1"; shift
  local label="com.yclaw.tart-$node"
  local plist="$LAUNCH_AGENTS_DIR/$label.plist"
  local args=("$@")

  local program_args=""
  local a
  for a in "$TART_BIN" "${args[@]}"; do
    program_args+="    <string>$a</string>"$'\n'
  done

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
$program_args  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOGS_DIR/$node.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGS_DIR/$node.error.log</string>
</dict>
</plist>
PLIST

  reload_launch_agent "$label" "$plist"
  log "Loaded LaunchAgent $label."
}

# Write one host serving-stack LaunchAgent plist and (re)load it. Same bootout-before-bootstrap shape
# as write_agent, but the program is a wrapper script (not tart) and the plist carries an
# EnvironmentVariables dict, ProcessType=Interactive, and (rapid-mlx) an ExitTimeOut long enough for
# the activator's graceful child stop before launchd SIGKILLs it.
# Args: <label> <program> <log-basename> <exit-timeout|""> [KEY=VALUE ...]
write_model_agent() {
  local label="$1" program="$2" log_base="$3" exit_timeout="$4"; shift 4
  local plist="$LAUNCH_AGENTS_DIR/$label.plist"

  local env_xml="" kv
  for kv in "$@"; do
    env_xml+="      <key>${kv%%=*}</key>"$'\n'
    env_xml+="      <string>${kv#*=}</string>"$'\n'
  done

  local exit_xml=""
  if [[ -n "$exit_timeout" ]]; then
    exit_xml="  <key>ExitTimeOut</key>"$'\n'"  <integer>$exit_timeout</integer>"$'\n'
  fi

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$program</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
${env_xml}  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
${exit_xml}  <key>StandardOutPath</key>
  <string>$MODEL_LOGS_DIR/$log_base.log</string>
  <key>StandardErrorPath</key>
  <string>$MODEL_LOGS_DIR/$log_base.error.log</string>
</dict>
</plist>
PLIST

  reload_launch_agent "$label" "$plist"
  log "Loaded LaunchAgent $label."
}

# --- 5. Host model serving stack (rapid-mlx activator + mlx-audio STT) --------

# The AI serving stack darwin/host.nix once ran, brought back to the bare host in front of the metal
# copies (the metal->host migration; metal keeps serving until the Phase-5 relay flip). rapid-mlx runs
# behind model-activator.py — a probe-safe idle-unload proxy that binds the tailnet IPv4:8000, answers
# /health + /v1/models locally while the 35B is unloaded, and spawns/reaps a 127.0.0.1:18000 child on
# demand. mlx-audio serves granite-speech STT on :8765. Both are gui LaunchAgents (RunAtLoad+KeepAlive).
# Model ids come from nixos/models.nix (the SoT shared with metal.nix), baked into the wrappers at
# install time; the serve flags mirror metal.nix's rapidMlxWrapper/sttWrapper verbatim.
#
# Factored into a function: the full linear bring-up invokes it LAST (below §4), and
# `setup.sh host-serving` (dispatch below) invokes it ALONE — §3's bootout-before-bootstrap
# restarts the LIVE tart VM runners on every pass, so a serving-stack refresh must skip §§0-4.
setup_host_serving() {
  # Model ids — read from the single source of truth (nixos/models.nix), like bootstrap.sh does.
  QWEN_ID="$(sed -n 's/.*qwen = "\([^"]*\)".*/\1/p' "$REPO_ROOT/nixos/models.nix")"
  STT_ID="$(sed -n 's/.*stt = "\([^"]*\)".*/\1/p' "$REPO_ROOT/nixos/models.nix")"
  [[ -n "$QWEN_ID" && -n "$STT_ID" ]] || die "could not read qwen/stt ids from nixos/models.nix"

  # 5f. de-Nix cleanup: the retired host cli-proxy-api config (cliproxy lives in metal now). It is
  # root-owned under /etc, so it needs privilege setup.sh does not hold as the login user — remove it if
  # we can, else print the one-liner. Idempotent (skips when already gone).
  if [[ -e /etc/cli-proxy-api ]]; then
    if rm -rf /etc/cli-proxy-api 2>/dev/null; then
      log "Removed retired /etc/cli-proxy-api."
    else
      warn "retired /etc/cli-proxy-api present but not removable as $(id -un); run: sudo rm -rf /etc/cli-proxy-api"
    fi
  fi

  # The three host.nix-era LaunchAgents (mlx-qwen/parakeet-stt/cliproxyapi) are retired — the host runs
  # rapid-mlx + mlx-audio via the com.yclaw.* agents below, and cliproxy lives inside metal. Boot out any
  # that are still loaded and delete their plists (and the .disabled/.bak siblings a prior manual disable
  # left) so a fresh login cannot RunAtLoad a stale server onto :8080/:8765. Idempotent.
  for label in org.nixos.mlx-qwen org.nixos.parakeet-stt org.nixos.cliproxyapi; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist" \
          "$HOME/Library/LaunchAgents/$label.plist.disabled" \
          "$HOME/Library/LaunchAgents/$label.plist.bak-prelat"
  done

  # 5a. rapid-mlx venv (python@3.14 keg, matching metal.nix) + the activator's runtime deps. Build only
  # when absent — mirrors metal.nix's `-x .../bin/rapid-mlx` idempotency check. Every package is pinned
  # to the exact version the verified venv resolved, so a rebuild reproduces the audited install.
  RAPID_VENV="$STATE_DIR/rapid-mlx/venv"
  if [[ ! -x "$RAPID_VENV/bin/rapid-mlx" ]]; then
    log "Building rapid-mlx venv at $RAPID_VENV ..."
    mkdir -p "$(dirname "$RAPID_VENV")"
    /opt/homebrew/opt/python@3.14/bin/python3.14 -m venv "$RAPID_VENV"
    "$RAPID_VENV/bin/python" -m pip install --upgrade pip
    "$RAPID_VENV/bin/python" -m pip install 'rapid-mlx==0.10.9' 'starlette==1.3.1' 'uvicorn==0.51.0' 'httpx==0.28.1'
  fi

  # 5b. mlx-audio venv, mirroring metal.nix's sttWrapper package set (built from /usr/bin/python3, the
  # CommandLineTools python; setuptools kept <81 for pkg_resources compat, pinned at the resolved
  # version). Every package is pinned to the exact version the verified venv resolved.
  STT_VENV="$STATE_DIR/mlx-audio/host-venv"
  if [[ ! -x "$STT_VENV/bin/python" ]]; then
    log "Building mlx-audio venv at $STT_VENV ..."
    mkdir -p "$(dirname "$STT_VENV")"
    /usr/bin/python3 -m venv "$STT_VENV"
    "$STT_VENV/bin/python" -m pip install --upgrade pip
    "$STT_VENV/bin/python" -m pip install 'mlx-audio==0.2.9' 'uvicorn==0.39.0' 'fastapi==0.128.8' 'python-multipart==0.0.20' 'setuptools==58.0.4'
  fi

  # 5c. Models into the shared HF hub cache. The STT model is downloaded here (idempotent — hf skips
  # present files); the Qwen weights are the human `hf download` gate bootstrap.sh runs, so warn (never
  # fail) if they are absent — a host-only setup.sh run then surfaces the gap without blocking.
  log "Downloading STT model $STT_ID into $HF_HUB_DIR (idempotent) ..."
  hf download "$STT_ID"
  qwen_cache_dir="$HF_HUB_DIR/models--$(printf '%s' "$QWEN_ID" | sed 's#/#--#g')"
  if [[ ! -d "$qwen_cache_dir" ]]; then
    warn "Qwen model absent at $qwen_cache_dir — rapid-mlx cannot serve until you run: hf download $QWEN_ID"
  fi

  # 5d. Install the serving-stack files into ~/.yclaw/bin. model-activator.py + stt-server.py + wait.sh
  # are copied verbatim from the repo; the two wrappers are copied through sed to bake the model ids.
  log "Installing serving-stack files into $BIN_DIR ..."
  mkdir -p "$BIN_DIR" "$MODEL_LOGS_DIR"
  cp "$REPO_ROOT/scripts/host/model-activator.py" "$BIN_DIR/model-activator.py"
  cp "$REPO_ROOT/darwin/stt-server.py" "$BIN_DIR/stt-server.py"
  cp "$REPO_ROOT/scripts/lib/wait.sh" "$BIN_DIR/wait.sh"
  sed "s|@@QWEN_MODEL@@|$QWEN_ID|g" "$REPO_ROOT/scripts/host/rapid-mlx-wrapper.sh" > "$BIN_DIR/rapid-mlx-wrapper.sh"
  sed "s|@@STT_MODEL@@|$STT_ID|g" "$REPO_ROOT/scripts/host/mlx-audio-wrapper.sh" > "$BIN_DIR/mlx-audio-wrapper.sh"
  chmod +x "$BIN_DIR/rapid-mlx-wrapper.sh" "$BIN_DIR/mlx-audio-wrapper.sh"

  # 5g. Application-firewall allowlist for the two venv pythons — ONLY when the app firewall is on. The
  # firewall silently drops inbound to unlisted binaries, so the tailnet cannot reach the serving ports
  # until the actual listeners are unblocked. socketfilterfw resolves each venv-python symlink to its
  # framework interpreter (the real listener), the same target metal.nix allowlists. Best-effort.
  FW=/usr/libexec/ApplicationFirewall/socketfilterfw
  if "$FW" --getglobalstate 2>/dev/null | grep -qi enabled; then
    log "App firewall is on — allowlisting the serving-stack venv pythons ..."
    for py in "$RAPID_VENV/bin/python" "$STT_VENV/bin/python"; do
      if [[ -e "$py" ]]; then
        "$FW" --add "$py" >/dev/null 2>&1 || true
        "$FW" --unblockapp "$py" >/dev/null 2>&1 || true
      fi
    done
  else
    log "App firewall is off — skipping the serving-stack allowlist."
  fi

  # 5e. LaunchAgents. rapid-mlx gets ExitTimeOut=180 so launchd's SIGTERM->SIGKILL window covers the
  # activator's graceful child stop (SIGTERM + up to 120s wait; graceful shutdown saves the prefix cache
  # and dodges the 20GB wired-Metal teardown pathology). Both run ProcessType=Interactive (no App-Nap
  # throttling) with HF_HUB_CACHE from the plist env; rapid-mlx also carries IDLE_SECONDS.
  write_model_agent com.yclaw.rapid-mlx "$BIN_DIR/rapid-mlx-wrapper.sh" rapid-mlx 180 \
    "IDLE_SECONDS=1800" "HF_HUB_CACHE=$HF_HUB_DIR"
  write_model_agent com.yclaw.mlx-audio "$BIN_DIR/mlx-audio-wrapper.sh" mlx-audio "" \
    "HF_HUB_CACHE=$HF_HUB_DIR"
}

# --- 6. Host pf lockdown (optional, root, NOT in the full run) -----------------

# Install the host's fleet-lockdown pf anchor + its refresh LaunchDaemon: ONLY metal may reach
# the host's model ports (rapid-mlx :8000, mlx-audio STT :8765) and no fleet VM reaches anything
# else on the host — over the tailnet or via the vmnet side-door (Darwin's weak-host delivery
# answers a bridge-ingress packet for ANY host address: the gateway 192.168.64.1, the LAN IP,
# even the tailnet IP over a forced VM route — all past the tailnet ACL) —
# the pf half of the Phase-4 lockdown (the tailnet-ACL half is hand-applied; see
# tailnet/policy.hujson). Mirrors bluebubbles-setup.sh's install_bb_pf_refresh: bake the tick
# script (scripts/host/host-pf.sh) beside verbatim wait.sh + pf.sh copies under
# /usr/local/lib/yclaw, run it once synchronously (the anchor is in force when this returns, not
# 300s later), then install the /Library/LaunchDaemons KeepAlive sleep-loop daemon (StartInterval
# silently stops firing on Tahoe) that re-keys the anchor to the fleet's current IPs every 300s.
#
# The anchor attaches at com.apple/000.yclaw.host (host-pf.sh's header has the full rationale;
# 000 sorts ahead of Apple's own wildcard children, whose quick passes would otherwise end
# evaluation first):
# the stock pf.conf's `anchor "com.apple/*"` wildcard evaluates it from the FIRST targeted load —
# a root-level anchor would stay orphaned until a boot-time /etc/pf.conf reload, and a live full
# reload is off the table because it flushes the dynamically-inserted Internet-Sharing/vmnet
# calls. That wildcard also precedes /etc/pf.conf's `anchor "vnc"` (whose <vnc_allowed> table
# quick-passes 192.168.0.0/16 + the tailnet to Screen Sharing 5900-5902 — Apple's file is left
# untouched), so the fleet block wins the quick race against the VNC allow.
#
# The tailscale CLI is a mise install in the login user's HOME (and /usr/local/bin/tailscaled is
# a symlink into that same user-writable tree) — a root daemon must never exec user-writable
# bits, so copy the resolved binary to root-owned /usr/local/lib/yclaw/tailscale and bake THAT
# path into the tick; re-running host-pf refreshes the copy. TAILSCALE stays the seam for
# FINDING the source binary (it lives in the login user's HOME, invisible to sudo's reset PATH) —
# die with the exact remedy otherwise.
#
# APPLY CHECKLIST (host remediation, not fixable in this repo): /usr/local/bin/tailscaled — the
# binary the root system daemon EXECS — is itself a symlink into that same user-writable mise
# tree; repoint it at a root-owned copy. This script only hardens the CLI copy it bakes.
setup_host_pf() {
  [ "$(id -u)" -eq 0 ] || die "host-pf writes /etc/pf.anchors + /Library/LaunchDaemons — run: sudo TAILSCALE=\"\$(command -v tailscale)\" bash scripts/setup.sh host-pf"

  local ts_bin="${TAILSCALE:-}"
  [ -n "$ts_bin" ] || ts_bin="$(command -v tailscale || true)"
  { [ -n "$ts_bin" ] && [ -x "$ts_bin" ]; } || die "tailscale CLI not found (sudo resets PATH) — run: sudo TAILSCALE=\"\$(command -v tailscale)\" bash scripts/setup.sh host-pf"

  local lib_dir="/usr/local/lib/yclaw" ports wg_port
  ports="{ $(manifest_get '.machines.host.services["rapid-mlx"].port'), $(manifest_get '.machines.host.services["mlx-audio"].port') }"
  wg_port="$(manifest_get '.machines.host.wireguard_port')"

  install -d -m 755 "$lib_dir"
  install -m 644 "$REPO_ROOT/scripts/lib/wait.sh" "$lib_dir/wait.sh"
  install -m 644 "$REPO_ROOT/scripts/lib/pf.sh" "$lib_dir/pf.sh"
  install -o root -g wheel -m 755 "$ts_bin" "$lib_dir/tailscale"
  "$lib_dir/tailscale" version 2>/dev/null | grep -q '^[0-9]' \
    || die "$lib_dir/tailscale (copied from $ts_bin) is not a runnable tailscale CLI (mise shim? wrong arch?) — re-run with TAILSCALE=<path to the real binary>"
  sed -e "s|@@TAILSCALE@@|$lib_dir/tailscale|g" -e "s|@@PF_PORTS@@|$ports|g" -e "s|@@WG_PORT@@|$wg_port|g" \
    "$REPO_ROOT/scripts/host/host-pf.sh" > "$lib_dir/host-pf.sh"
  chmod 755 "$lib_dir/host-pf.sh"

  # One-time 999 -> 000 re-namespace (wildcard children evaluate alphabetically; Apple's own
  # could quick-pass ahead of a 999 sibling): flush the retired kernel anchor and drop its
  # boot-time wiring. No-ops once migrated (the flush errors on a nonexistent anchor).
  pfctl -a com.apple/999.yclaw.host -F rules 2>/dev/null || true
  if grep -q '999\.yclaw\.host' /etc/pf.conf; then
    sed -i '' '/999\.yclaw\.host/d' /etc/pf.conf
  fi
  rm -f /etc/pf.anchors/com.apple.999.yclaw.host

  "$lib_dir/host-pf.sh" 10 || die "first host-pf tick failed — anchor NOT in force (see above)"

  local label="com.yclaw.host-pf-refresh"
  local plist="/Library/LaunchDaemons/$label.plist"
  # Boot-window backoff: at RunAtLoad the fleet bridge may not exist yet (tart creates it with
  # the first VM boot) and tailscaled may still be settling — a flat `|| true; sleep 300` loop
  # would sit unenforced for up to 5 min per miss while launchd reports the job healthy. Retry
  # at 5s doubling to a 30s cap until the FIRST successful tick, then the 300s cadence; later
  # failures stay || true (fail-closed: the last-good ruleset remains in force, and the tick's
  # host-pf.last-ok marker goes stale for a doctor check to catch).
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>d=5; until $lib_dir/host-pf.sh 60; do sleep \$d; d=\$((d*2)); if [ \$d -gt 30 ]; then d=30; fi; done; while true; do sleep 300; $lib_dir/host-pf.sh 60 || true; done</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/host-pf-refresh.log</string>
  <key>StandardErrorPath</key><string>/var/log/host-pf-refresh.error.log</string>
</dict>
</plist>
PLIST
  chown root:wheel "$plist"
  chmod 644 "$plist"
  bootout_drain system "$label"
  launchctl bootstrap system "$plist"

  # APPLY-TIME VERIFICATION (operator, after this returns) — judge by OUTPUT, never exit code
  # (tailscale ssh always reports rc 0). HOST4 = the host's tailnet IPv4 (`tailscale ip -4`);
  # LAN = the host's LAN address (`ipconfig getifaddr en0`). The model ports listen ONLY on
  # HOST4, so a curl at 192.168.64.1:<model-port> fails even with pf disabled and proves nothing.
  #   1. PASS  — model plane intact over the tailnet (decrypted 100.x traffic on utunN, policed by
  #      the fleet-IP rules, not the bridge; the WG carve-out only admits the encrypted transport):
  #        tailscale ssh metal -- curl -sS --max-time 5 http://HOST4:8000/v1/models  -> model list
  #   2. BLOCK — weak-host delivery of the tailnet IP via the vmnet gateway:
  #        tailscale ssh hermes -- sudo ip route replace HOST4/32 via 192.168.64.1
  #        tailscale ssh hermes -- curl -sS --max-time 5 http://HOST4:8000/v1/models -> timeout
  #        tailscale ssh hermes -- sudo ip route del HOST4/32
  #   3. BLOCK — LAN-IP side-door to any 0.0.0.0-bound host listener, from metal AND hermes:
  #        tailscale ssh metal  -- curl -sS --max-time 5 http://LAN:PORT/            -> timeout
  #        tailscale ssh hermes -- curl -sS --max-time 5 http://LAN:PORT/            -> timeout
  #   4. COUNTERS — the `block drop ... from any to self` rule incremented across 2-3:
  #        pfctl -a com.apple/000.yclaw.host -v -sr
  #   5. RESIDUAL — the WG carve-out trusts the port pin, but --port is a preference, not a
  #      reservation: on a bind collision tailscaled silently falls back to a random port, and
  #      the carve-out then admits fleet datagrams to whatever process DOES own the pinned port.
  #      Confirm ownership before relying on the carve-out:
  #        sudo lsof -nP -iUDP:41641   -> the owning command must be tailscaled
}

# --- arg dispatch --------------------------------------------------------------

case "${1:-}" in
  host-serving)
    setup_host_serving
    log "Host serving stack com.yclaw.{rapid-mlx,mlx-audio} loaded."
    exit 0
    ;;
  host-pf)
    setup_host_pf
    log "Host pf lockdown installed: anchor com.apple/000.yclaw.host + LaunchDaemon com.yclaw.host-pf-refresh."
    log "Run the APPLY-TIME VERIFICATION block at the end of setup_host_pf (model plane PASS; vmnet + LAN side-doors BLOCKED)."
    exit 0
    ;;
  "") ;;
  *) die "usage: setup.sh [host-serving|host-pf]" ;;
esac

# --- 0. Homebrew + tart + gum ------------------------------------------------

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then return; fi
  log "Installing Homebrew ..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

ensure_brew
command -v brew >/dev/null 2>&1 || die "Homebrew not on PATH after install."

log "Ensuring tart + gum (tap cirruslabs/cli) ..."
brew tap cirruslabs/cli
brew install cirruslabs/cli/tart gum
[[ -x "$TART_BIN" ]] || die "tart not at $TART_BIN after brew install."

# packer builds the macOS guest images (metal + bluebubbles) in `just bootstrap`.
log "Ensuring packer (tap hashicorp/tap) ..."
brew tap hashicorp/tap
brew install hashicorp/tap/packer
command -v packer >/dev/null 2>&1 || die "packer not on PATH after brew install."

# --- 1. Tailscale (detect-then-install; never clobber the mise daemon) -------

# The host already runs a mise-built tailscaled 1.98.5 (system daemon, `tailscale ssh` live).
# Re-pointing it at the older Homebrew binary would DOWNGRADE a working setup, so install the
# Homebrew tailscale ONLY when no tailscaled exists at all (fresh host).
if pgrep -qx tailscaled || command -v tailscaled >/dev/null 2>&1; then
  log "Existing tailscaled detected — leaving it untouched (not installing Homebrew tailscale)."
else
  log "No tailscaled found — installing Homebrew tailscale ..."
  brew install tailscale
fi

# --- 2. ~/.yclaw/state + per-VM subdirs --------------------------------------

# State subdirs the VMs read/write over the virtiofs shares (metal mounts narrow per-need shares,
# hermes mounts its own hosts/hermes bundle + hermes/ runtime state) come from machines.json.
log "Creating $STATE_DIR and per-VM subdirs ..."
mkdir -p "$STATE_DIR"
state_subdirs="$(manifest_list '.host_paths.state_subdirs_mounts')"
while IFS= read -r sub; do
  mkdir -p "$STATE_DIR/$sub"
done <<< "$state_subdirs"
chmod 700 "$STATE_DIR/hosts/hermes" "$STATE_DIR/hosts/metal"
mkdir -p "$LOGS_DIR" "$LAUNCH_AGENTS_DIR"
# The shared HF hub cache lives in the host's regular cache, not the state tree — create it so the
# metal LaunchAgent can mount the `hfhub` share even before any model has been downloaded.
mkdir -p "$HF_HUB_DIR"

# hermes node-config share source: the dir the tart-hermes runner mounts (--dir=sops:...:ro) so
# common.nix's seedNodeConfig can read key.txt + secrets.sops.yaml (+ node.env, agent-vault-ca.pem)
# on first boot. `just bootstrap` populates it; create it here so the runner can mount it even
# before a full bootstrap has written its contents.
NODE_CONFIG_DIR="$HOME_DIR/$(manifest_get '.host_paths.node_config_dir_rel')"
mkdir -p "$NODE_CONFIG_DIR"
chmod 700 "$NODE_CONFIG_DIR"

# --- 3. LaunchAgents for the VM runners --------------------------------------

# tart auto-mounts the `name:path` --dir form to /Volumes/My Shared Files/<name> inside macOS
# guests (verified); the `tag=` form does NOT auto-mount. metal gets NARROW per-need shares — its
# own secrets bundle (hosts/metal, read-only) plus only the runtime dirs it owns — instead of the
# whole state tree, so it can NEVER see hosts/hermes/ or state/hermes/ (hermes's age key + state).
# metal.nix's preActivation + sops.defaultSopsFile point under /Volumes/My Shared Files/metalsecrets.
#
# metal runs HEADLESS (--no-graphics): it holds ONLY the credential + AI services and NO
# iMessage, so it needs no host-side GUI window. rapid-mlx's Metal GPU works headless from the
# UserName=admin system daemons — no auto-login or aqua session required (verified; packer passes
# VM_AUTOLOGIN=drop for metal). The repo is shared
# read-only at /Volumes/My Shared Files/repo so the in-guest nix-darwin can rebuild itself
# (`darwin-rebuild switch --flake "/Volumes/My Shared Files/repo#metal"`, see darwin/metal.nix).
write_agent metal \
  run metal \
  --no-graphics \
  "--dir=metalsecrets:$STATE_DIR/hosts/metal:ro" \
  "--dir=agentvault:$STATE_DIR/agent-vault" \
  "--dir=hfhub:$HF_HUB_DIR" \
  "--dir=mlxaudio:$STATE_DIR/mlx-audio" \
  "--dir=cliproxy:$STATE_DIR/cli-proxy-api" \
  "--dir=repo:$HOME_DIR/Code/yclaw:ro"

# bluebubbles is the SIP-off iMessage node — its OWN tailnet node, holds NO credentials, so no
# state share. Runs HEADLESS + suspendable: in-guest auto-login provides the aqua session that
# Messages.app and Screen Sharing need, and the one-time GUI gates (Apple-ID 2FA, Full Disk
# Access, the Private API toggle) are driven over the guest's VNC, not a host-side tart window.
write_agent bluebubbles \
  run bluebubbles \
  --no-graphics \
  --suspendable

# hermes is a Linux guest: --no-graphics, and the serial console MUST be drained or a headless
# boot hangs once the virtio console ring fills. The `sops` share (ro) seeds the age key +
# secrets for first-boot node-config seeding; the `hermesstate` share (rw) externalizes the
# agent's persistent state (/var/lib/hermes — honcho memory, sessions) onto ~/.yclaw/state so it
# survives a VM rebuild and is covered by `just backup`. The `repo` share (ro) mounts this checkout
# read-only so the in-VM nixos-rebuild can rebuild itself (`nixos-rebuild switch --flake
# /var/lib/yclaw-repo#hermes`). (/var/lib/tailscale is NOT externalized — a mount there collides with
# tailscaled's StateDirectory; hermes is a PERSISTENT tailnet node whose on-disk key survives a reboot
# anyway, and only a disk-replace re-mints. See nixos/hermes.nix.)
#
# Unlike metal (a macOS guest, which auto-mounts the `name:path` form at /Volumes/My Shared
# Files/<name>), a Linux guest mounts each share by its EXPLICIT virtiofs tag — so these MUST use
# the `path:[ro,]tag=<tag>` form. The `name:path` form would leave them on tart's default
# `com.apple.virtio-fs.automount` tag, and common.nix's seedNodeConfig (tag `sops`) + nixos/hermes.nix's
# fstab (tags `hermesstate`/`repo`) would find no such device and the matching mount would fail.
write_agent hermes \
  run hermes \
  --no-graphics \
  --serial-path=/dev/null \
  "--dir=$NODE_CONFIG_DIR:ro,tag=sops" \
  "--dir=$STATE_DIR/hermes:tag=hermesstate" \
  "--dir=$HOME_DIR/Code/yclaw:ro,tag=repo"

# --- 3b. Nightly metal bounce -------------------------------------------------

# macOS guests have no memory balloon, so metal's host-side RSS ratchets to its high-water mark
# until the VM restarts. Nightly 05:00 stop; KeepAlive on com.yclaw.tart-metal relaunches it.
BOUNCE_LABEL="com.yclaw.metal-nightly-bounce"
bounce_plist="$LAUNCH_AGENTS_DIR/$BOUNCE_LABEL.plist"
cat > "$bounce_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BOUNCE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TART_BIN</string>
    <string>stop</string>
    <string>metal</string>
    <string>--timeout</string>
    <string>120</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>5</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOGS_DIR/metal-nightly-bounce.log</string>
  <key>StandardErrorPath</key>
  <string>$LOGS_DIR/metal-nightly-bounce.error.log</string>
</dict>
</plist>
PLIST
reload_launch_agent "$BOUNCE_LABEL" "$bounce_plist"
log "Loaded LaunchAgent $BOUNCE_LABEL (nightly metal bounce at 05:00)."

# --- 4. pf VNC anchor (optional, OFF by default) -----------------------------

# Ports ONLY the targeted `pfctl -a vnc` reload from darwin/host.nix:189-204. NEVER
# `pfctl -f /etc/pf.conf`: a full reload flushes the vmnet / Internet-Sharing NAT anchors
# (shared_v4 / shared_v6 / network_isolation) the VMs need for internet + tailnet egress.
if [[ "$ENABLE_VNC_ANCHOR" == "1" ]]; then
  log "Loading pf VNC anchor (ENABLE_VNC_ANCHOR=1) ..."
  vnc_rules="$(mktemp)"
  cat > "$vnc_rules" <<'EOF'
table <vnc_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
block in quick proto { tcp udp } from any to any port 5900:5902
EOF
  # install_pf_anchor does a targeted `pfctl -a vnc -f` load only (NEVER `pfctl -f /etc/pf.conf`,
  # which flushes the vmnet / Internet-Sharing NAT anchors the VMs need), and is called WITHOUT
  # --wire-pfconf so the anchor stays out of /etc/pf.conf — this host deliberately does not
  # boot-wire the VNC anchor. pf ops need root, so run install_pf_anchor in a sudo shell that
  # sources the self-contained pf.sh.
  sudo bash -c 'source "$1"; install_pf_anchor vnc "$2"' _ "$REPO_ROOT/scripts/lib/pf.sh" "$vnc_rules"
  rm -f "$vnc_rules"
fi

# --- 5. Host model serving stack — setup_host_serving, defined above §0 -------

setup_host_serving

log "Host setup complete. VM runners com.yclaw.tart-{metal,bluebubbles,hermes} + serving stack com.yclaw.{rapid-mlx,mlx-audio} loaded."
