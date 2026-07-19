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

# The host's REGULAR Hugging Face hub cache (NOT the state tree): the host model plane (§5's
# rapid-mlx activator + STT) reads it, and `hf download` lands here. The `token` sibling never leaves $HOME.
HF_HUB_DIR="${HF_HOME:-$HOME_DIR/.cache/huggingface}/hub"

# pf VNC anchor: OFF by default. The host runs no VNC-exposed model services anymore, so there
# is nothing to gate. Set ENABLE_VNC_ANCHOR=1 only if a VNC service is reintroduced on the host.
ENABLE_VNC_ANCHOR="${ENABLE_VNC_ANCHOR:-0}"

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

# --- 5. Host model serving stack (rapid-mlx activator + stt) ------------------

# This host stack is now the fleet's ONLY model plane — metal just relays 8000/8765 to it.
setup_host_serving() {
  # Model ids — read from the single source of truth (nixos/models.nix), like bootstrap.sh does. The
  # STT variant is athome's [serve.stt] default, so only the Qwen id is baked into a wrapper here.
  QWEN_ID="$(sed -n 's/.*qwen = "\([^"]*\)".*/\1/p' "$REPO_ROOT/nixos/models.nix")"
  [[ -n "$QWEN_ID" ]] || die "could not read qwen id from nixos/models.nix"

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

  # Retire the bespoke mlx-audio STT before the stt activator loads: both bind :8765, so a live old
  # server EADDRINUSEs the activator into a KeepAlive crash loop. Granite HF weights stay cached.
  launchctl bootout "gui/$(id -u)/com.yclaw.mlx-audio" 2>/dev/null || true
  rm -f "$LAUNCH_AGENTS_DIR/com.yclaw.mlx-audio.plist"
  rm -rf "$STATE_DIR/mlx-audio"
  rm -f "$BIN_DIR/mlx-audio-wrapper.sh" "$BIN_DIR/stt-server.py"

  # 5a. rapid-mlx venv (python@3.14 keg, matching metal.nix) + the activator's runtime deps. Build only
  # when absent — mirrors metal.nix's `-x .../bin/rapid-mlx` idempotency check. Every package is pinned
  # to the exact version the verified venv resolved, so a rebuild reproduces the audited install.
  RAPID_VENV="$STATE_DIR/rapid-mlx/venv"
  if [[ ! -x "$RAPID_VENV/bin/rapid-mlx" || ! -x "$RAPID_VENV/bin/athome" ]]; then
    log "Building rapid-mlx venv at $RAPID_VENV ..."
    mkdir -p "$(dirname "$RAPID_VENV")"
    /opt/homebrew/opt/python@3.14/bin/python3.14 -m venv "$RAPID_VENV"
    "$RAPID_VENV/bin/python" -m pip install --upgrade pip
    "$RAPID_VENV/bin/python" -m pip install 'rapid-mlx==0.10.9' 'experiment-at-home[activator]==0.9.2' 'starlette==1.3.1' 'uvicorn==0.51.0' 'httpx==0.28.1' 'aiosqlite==0.22.1' 'loguru==0.7.3' 'pydantic==2.13.4' 'pydantic-core==2.46.4' 'pydantic-settings==2.14.2' 'annotated-types==0.7.0' 'typing-inspection==0.4.2' 'typing-extensions==4.16.0' 'python-dotenv==1.2.2' 'anyio==4.14.2' 'click==8.4.2' 'sniffio==1.3.1' 'idna==3.18' 'certifi==2026.6.17' 'httpcore==1.0.9' 'h11==0.16.0'
  fi

  # 5b. stt venv (python@3.14 keg, like the rapid-mlx venv) + athome's transcribe.cpp engine. Build
  # only when absent; transcribe-cpp/-native are exact-pinned (pre-1.0 ABI).
  STT_VENV="$STATE_DIR/stt/venv"
  if [[ ! -x "$STT_VENV/bin/athome" ]]; then
    log "Building stt venv at $STT_VENV ..."
    mkdir -p "$(dirname "$STT_VENV")"
    /opt/homebrew/opt/python@3.14/bin/python3.14 -m venv "$STT_VENV"
    "$STT_VENV/bin/python" -m pip install --upgrade pip
    # Provisional transitive pins; re-freeze against the published 0.10.0 resolution at first build.
    "$STT_VENV/bin/python" -m pip install 'experiment-at-home[stt,activator]==0.10.0' 'transcribe-cpp==0.1.3' 'transcribe-cpp-native==0.1.3' 'starlette==1.3.1' 'uvicorn==0.51.0' 'python-multipart==0.0.20' 'httpx==0.28.1' 'aiosqlite==0.22.1' 'loguru==0.7.3' 'pydantic==2.13.4' 'pydantic-core==2.46.4' 'pydantic-settings==2.14.2' 'annotated-types==0.7.0' 'typing-inspection==0.4.2' 'typing-extensions==4.16.0' 'python-dotenv==1.2.2' 'anyio==4.14.2' 'click==8.4.2' 'sniffio==1.3.1' 'idna==3.18' 'certifi==2026.6.17' 'httpcore==1.0.9' 'h11==0.16.0'
  fi

  # 5c. Weights into the shared HF hub cache. athome pre-fetches the STT variant (idempotent); the
  # Qwen weights are bootstrap.sh's human `hf download` gate, so warn (never fail) if absent below.
  log "Downloading STT weights via athome into $HF_HUB_DIR (idempotent) ..."
  HF_HUB_CACHE="$HF_HUB_DIR" "$STT_VENV/bin/athome" stt download
  qwen_cache_dir="$HF_HUB_DIR/models--$(printf '%s' "$QWEN_ID" | sed 's#/#--#g')"
  if [[ ! -d "$qwen_cache_dir" ]]; then
    warn "Qwen model absent at $qwen_cache_dir — rapid-mlx cannot serve until you run: hf download $QWEN_ID"
  fi

  # 5d. Install the serving-stack files into ~/.yclaw/bin. wait.sh + stt-wrapper.sh copied verbatim;
  # rapid-mlx-wrapper.sh goes through sed to bake the Qwen id (stt bakes no model).
  log "Installing serving-stack files into $BIN_DIR ..."
  mkdir -p "$BIN_DIR" "$MODEL_LOGS_DIR"
  rm -f "$BIN_DIR/model-activator.py"  # clear any stale copy a prior install left here
  cp "$REPO_ROOT/scripts/lib/wait.sh" "$BIN_DIR/wait.sh"
  cp "$REPO_ROOT/scripts/host/stt-wrapper.sh" "$BIN_DIR/stt-wrapper.sh"
  sed "s|@@QWEN_MODEL@@|$QWEN_ID|g" "$REPO_ROOT/scripts/host/rapid-mlx-wrapper.sh" > "$BIN_DIR/rapid-mlx-wrapper.sh"
  chmod +x "$BIN_DIR/rapid-mlx-wrapper.sh" "$BIN_DIR/stt-wrapper.sh"

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

  # 5e. LaunchAgents. Both run the activator: ExitTimeOut=180 covers launchd's graceful child-stop
  # window, ProcessType=Interactive dodges App-Nap, HF_HUB_CACHE + IDLE_S ride in from the plist env.
  write_model_agent com.yclaw.rapid-mlx "$BIN_DIR/rapid-mlx-wrapper.sh" rapid-mlx 180 \
    "ATHOME_SERVE_ACTIVATOR_IDLE_S=1800" "HF_HUB_CACHE=$HF_HUB_DIR"
  write_model_agent com.yclaw.stt "$BIN_DIR/stt-wrapper.sh" stt 180 \
    "ATHOME_SERVE_ACTIVATOR_IDLE_S=1800" "HF_HUB_CACHE=$HF_HUB_DIR"
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
  ports="{ $(manifest_get '.machines.host.services["rapid-mlx"].port'), $(manifest_get '.machines.host.services["stt"].port') }"
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

# --- 7. Container supervisors (optional, root-assisted, NOT in the full run) ---------------

install_container_supervisor_files() {
  local node="$1" baked="$2"
  local lib_dir="/usr/local/lib/yclaw" pf_label wg_port pf_stdout pf_stderr
  pf_label="$(manifest_get '.machines.host.services["container-pf-refresh"].launchd.label')"
  wg_port="$(manifest_get '.machines.host.wireguard_port')"
  pf_stdout="$(manifest_get '.machines.host.services["container-pf-refresh"].logs[0]')"
  pf_stderr="$(manifest_get '.machines.host.services["container-pf-refresh"].logs[1]')"

  sudo bash -s -- "$node" "$lib_dir" "$baked" "$REPO_ROOT/scripts/lib/wait.sh" \
      "$REPO_ROOT/scripts/lib/pf.sh" "$REPO_ROOT/scripts/host/container-pf.sh" \
      "$pf_label" "$wg_port" "$pf_stdout" "$pf_stderr" <<'SUDO'
set -eu
node="$1"; lib_dir="$2"; baked="$3"; wait_sh="$4"; pf_sh="$5"; container_pf="$6"
pf_label="$7"; wg_port="$8"; pf_stdout="$9"; pf_stderr="${10}"
install -d -m 755 "$lib_dir"
install -m 644 "$wait_sh" "$lib_dir/wait.sh"
install -m 644 "$pf_sh" "$lib_dir/pf.sh"
install -m 755 "$baked" "$lib_dir/container-$node.sh"
pf_baked="$(mktemp)"
sed -e "s|@@WG_PORT@@|$wg_port|g" "$container_pf" > "$pf_baked"
install -m 755 "$pf_baked" "$lib_dir/container-pf.sh"
rm -f "$pf_baked"
# Egress pf refresh LaunchDaemon (root; RunAtLoad + KeepAlive backoff sleep-loop — Tahoe kills
# StartInterval). Installed NOT loaded: bring-up touches the firewall, so it is gated on review.
plist="/Library/LaunchDaemons/$pf_label.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$pf_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>d=5; until $lib_dir/container-pf.sh 60; do sleep \$d; d=\$((d*2)); if [ \$d -gt 30 ]; then d=30; fi; done; while true; do sleep 300; $lib_dir/container-pf.sh 60 || true; done</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$pf_stdout</string>
  <key>StandardErrorPath</key><string>$pf_stderr</string>
</dict>
</plist>
PLIST
chown root:wheel "$plist"
chmod 644 "$plist"
SUDO
}

# Author the container-native hermes launch chain. Login user + sudo for privileged bits; gated.
setup_host_container() {
  need go
  local container_bin="/opt/homebrew/bin/container"
  local socktainer_bin="/opt/homebrew/opt/socktainer/bin/socktainer"
  local socktainer_sock="$HOME_DIR/.socktainer/container.sock"
  local config_toml="$HOME_DIR/.config/container/config.toml"
  local run_dir="$HOME_DIR/.yclaw/run/hermes-docker-proxy"
  local config_dir="$STATE_DIR/hosts/hermes"
  local ts_state_dir="$STATE_DIR/hermes-ts-state"
  local proxy_bin="$BIN_DIR/hermes-docker-proxy"
  local lib_dir="/usr/local/lib/yclaw"
  local group="hermes-agent" gid=1000
  local node_config_dir
  node_config_dir="$HOME_DIR/$(manifest_get '.host_paths.node_config_dir_rel')"

  [ -x "$container_bin" ]  || die "apple/container CLI not at $container_bin (brew install container)"
  [ -x "$socktainer_bin" ] || die "socktainer not at $socktainer_bin (brew install socktainer)"
  [ -f "$config_toml" ]    || die "$config_toml missing — its 192.168.72/24 subnet override must exist before the first 'container system start'"
  [ -d "$REPO_ROOT/pkgs/hermes-docker-proxy" ] || die "proxy source pkgs/hermes-docker-proxy absent"

  # Proxy binary: pure-stdlib CGO-free Go, built on the host (no nix).
  log "Building hermes-docker-proxy -> $proxy_bin ..."
  mkdir -p "$BIN_DIR" "$MODEL_LOGS_DIR"
  ( cd "$REPO_ROOT/pkgs/hermes-docker-proxy" && CGO_ENABLED=0 go build -o "$proxy_bin" . )
  [ -x "$proxy_bin" ] || die "go build did not produce $proxy_bin"

  # Stage the 4 container secrets/config into $config_dir (node.env + token from bootstrap's bundle).
  # $STATE_DIR/hermes is the agent state mount source — apple/container rejects a nonexistent bind,
  # so a clean deploy fails at `container run` without it (the entrypoint chowns it to 1000 in-guest).
  log "Staging hermes container secrets/config into $config_dir ..."
  install -d -m 700 "$config_dir" "$ts_state_dir" "$STATE_DIR/hermes"
  local f
  for f in key.txt secrets.sops.yaml; do
    [ -f "$config_dir/$f" ] || die "$config_dir/$f missing — run 'just bootstrap' first (per-host age key + sops bundle)"
  done
  [ -f "$node_config_dir/node.env" ]           || die "$node_config_dir/node.env missing — run 'just bootstrap' first"
  [ -f "$node_config_dir/agent-vault-token" ]  || die "$node_config_dir/agent-vault-token missing — run 'just bootstrap' first"
  [ -f "$node_config_dir/agent-vault-ca.pem" ] || die "$node_config_dir/agent-vault-ca.pem missing — run 'just bootstrap' first (agent-vault MITM CA for external egress)"
  install -m 644 "$node_config_dir/node.env"           "$config_dir/node.env"
  install -m 600 "$node_config_dir/agent-vault-token"  "$config_dir/agent-vault-token"
  install -m 644 "$node_config_dir/agent-vault-ca.pem" "$config_dir/agent-vault-ca.pem"

  # Bake the tick's @@TOKENS@@ (login user); privileged steps (group, lib dir, socket dir) via sudo.
  local baked; baked="$(mktemp)"
  sed -e "s|@@CONTAINER@@|$container_bin|g" \
      -e "s|@@SOCKTAINER@@|$socktainer_bin|g" \
      -e "s|@@SOCKTAINER_SOCK@@|$socktainer_sock|g" \
      -e "s|@@PROXY_BIN@@|$proxy_bin|g" \
      -e "s|@@STATE_DIR@@|$STATE_DIR|g" \
      -e "s|@@RUN_DIR@@|$run_dir|g" \
      -e "s|@@CONFIG_DIR@@|$config_dir|g" \
      -e "s|@@CONFIG_TOML@@|$config_toml|g" \
      -e "s|@@LOG_DIR@@|$MODEL_LOGS_DIR|g" \
      "$REPO_ROOT/scripts/host/container-hermes.sh" > "$baked"

  log "Creating gid-$gid group '$group' and socket dir $run_dir (sudo) ..."
  sudo bash -s -- "$group" "$gid" "$run_dir" "$(id -un)" <<'SUDO'
set -eu
group="$1"; gid="$2"; run_dir="$3"; owner="$4"
# gid-1000 group so the proxy's 0660 socket lands group-owned gid 1000 (the dropped agent's gid).
if ! dscl . -read "/Groups/$group" >/dev/null 2>&1; then
  dscl . -create "/Groups/$group"
  dscl . -create "/Groups/$group" PrimaryGroupID "$gid"
  dscl . -create "/Groups/$group" RealName "hermes agent container (uid/gid $gid)"
fi
# The socket's group is the access boundary, so a drifted gid or a squatter on the gid is a silent
# security misconfig — assert exact ownership rather than trust the name-idempotent create above.
have="$(dscl . -read "/Groups/$group" PrimaryGroupID 2>/dev/null | awk '{print $NF}')"
[ "$have" = "$gid" ] || { echo "FATAL group '$group' has gid '$have', not $gid" >&2; exit 1; }
for o in $(dscl . -list /Groups PrimaryGroupID | awk -v g="$gid" '$2==g {print $1}'); do
  [ "$o" = "$group" ] || { echo "FATAL gid $gid also owned by group '$o' (not '$group')" >&2; exit 1; }
done
# User-owned so the per-user proxy can bind; group + setgid so the socket inherits gid $gid.
install -d -o "$owner" -g "$group" -m 2750 "$run_dir"
SUDO

  log "Installing the hermes tick + shared egress pf daemon (sudo) ..."
  install_container_supervisor_files hermes "$baked"
  rm -f "$baked"

  write_container_agent hermes "$lib_dir/container-hermes.sh" 60

  local label pf_label
  label="$(manifest_get '.machines.host.services["container-hermes"].launchd.label')"
  pf_label="$(manifest_get '.machines.host.services["container-pf-refresh"].launchd.label')"
  log "Supervisor + egress pf authored. Bring-up is GATED (starts the chain AND touches pf) — after"
  log "review, load BOTH:"
  log "  launchctl bootstrap gui/\$(id -u) $LAUNCH_AGENTS_DIR/$label.plist"
  log "  sudo launchctl bootstrap system /Library/LaunchDaemons/$pf_label.plist"
}

setup_host_vault() {
  local container_bin="/opt/homebrew/bin/container"
  local config_toml="$HOME_DIR/.config/container/config.toml"
  local config_dir="$STATE_DIR/hosts/vault"
  local ts_state_dir="$STATE_DIR/vault-ts-state"
  local lib_dir="/usr/local/lib/yclaw"

  [ -x "$container_bin" ] || die "apple/container CLI not at $container_bin (brew install container)"
  [ -f "$config_toml" ] || die "$config_toml missing — its 192.168.72/24 subnet override must exist before the first 'container system start'"

  log "Staging vault container state and canonical per-host bundle in $config_dir ..."
  mkdir -p "$MODEL_LOGS_DIR" "$LAUNCH_AGENTS_DIR"
  install -d -m 700 "$config_dir" "$ts_state_dir" "$STATE_DIR/vault"
  local f
  for f in key.txt secrets.sops.yaml; do
    [ -f "$config_dir/$f" ] || die "$config_dir/$f missing — run 'just bootstrap' first (per-host age key + sops bundle)"
  done

  local baked; baked="$(mktemp)"
  sed -e "s|@@CONTAINER@@|$container_bin|g" \
      -e "s|@@STATE_DIR@@|$STATE_DIR|g" \
      -e "s|@@CONFIG_DIR@@|$config_dir|g" \
      -e "s|@@CONFIG_TOML@@|$config_toml|g" \
      -e "s|@@LOG_DIR@@|$MODEL_LOGS_DIR|g" \
      "$REPO_ROOT/scripts/host/container-vault.sh" > "$baked"

  log "Installing the vault tick + shared egress pf daemon (sudo) ..."
  install_container_supervisor_files vault "$baked"
  rm -f "$baked"

  write_container_agent vault "$lib_dir/container-vault.sh" 60

  local label pf_label
  label="$(manifest_get '.machines.host.services["container-vault"].launchd.label')"
  pf_label="$(manifest_get '.machines.host.services["container-pf-refresh"].launchd.label')"
  log "Vault supervisor + egress pf authored. Bring-up is GATED — after review, load BOTH:"
  log "  launchctl bootstrap gui/\$(id -u) $LAUNCH_AGENTS_DIR/$label.plist"
  log "  sudo launchctl bootstrap system /Library/LaunchDaemons/$pf_label.plist"
  log "Mint a hermes token with: $lib_dir/container-vault.sh mint-hermes-token"
}

# --- arg dispatch --------------------------------------------------------------

case "${1:-}" in
  host-serving)
    setup_host_serving
    log "Host serving stack com.yclaw.{rapid-mlx,stt} loaded."
    exit 0
    ;;
  host-pf)
    setup_host_pf
    log "Host pf lockdown installed: anchor com.apple/000.yclaw.host + LaunchDaemon com.yclaw.host-pf-refresh."
    log "Run the APPLY-TIME VERIFICATION block at the end of setup_host_pf (model plane PASS; vmnet + LAN side-doors BLOCKED)."
    exit 0
    ;;
  host-container)
    setup_host_container
    log "Container-native hermes supervisor authored (tick + com.yclaw.container-hermes plist; NOT loaded — bring-up gated)."
    exit 0
    ;;
  host-vault)
    setup_host_vault
    log "Container-native vault supervisor authored (tick + container-vault plist; NOT loaded — bring-up gated)."
    exit 0
    ;;
  "") ;;
  *) die "usage: setup.sh [host-serving|host-pf|host-container|host-vault]" ;;
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

# hermes node-config staging source: `just bootstrap` populates it; setup_host_container reads
# node.env + agent-vault-token from here to stage the hermes container.
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
  "--dir=cliproxy:$STATE_DIR/cli-proxy-api" \
  "--dir=repo:$HOME_DIR/Code/yclaw:ro" # keep this --dir set in sync with scripts/resize-metal.sh

# bluebubbles is the SIP-off iMessage node — its OWN tailnet node, holds NO credentials, so no
# state share. Runs HEADLESS + suspendable: in-guest auto-login provides the aqua session that
# Messages.app and Screen Sharing need, and the one-time GUI gates (Apple-ID 2FA, Full Disk
# Access, the Private API toggle) are driven over the guest's VNC, not a host-side tart window.
write_agent bluebubbles \
  run bluebubbles \
  --no-graphics \
  --suspendable

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

log "Host setup complete. VM runners com.yclaw.tart-{metal,bluebubbles} + serving stack com.yclaw.{rapid-mlx,stt} loaded."
