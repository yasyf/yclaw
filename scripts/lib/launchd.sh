#!/usr/bin/env bash
# scripts/lib/launchd.sh — launchd (re)load helpers for the host's tart runners. Requires wait.sh
# (wait_for) and common.sh (die) to be sourced first. bash 3.2 compatible.

_launchd_absent() { ! launchctl print "$1" >/dev/null 2>&1; }

# Boot <label> out of <domain>, then wait (bounded) for it to leave the domain. `bootout` is async
# — it signals the tart VM and returns before the service drains; bootstrapping the same label
# while it is still stopping races launchd and fails "5: Input/output error" (scripts/setup.sh).
bootout_drain() {
  local domain="$1" label="$2"
  launchctl bootout "$domain/$label" 2>/dev/null || true
  wait_for "launchd $domain/$label to drain" 30 1 _launchd_absent "$domain/$label"
}

# Reload the gui-domain LaunchAgent <label> from <plist-path>: bootout-drain, then bootstrap.
reload_launch_agent() {
  local label="$1" plist="$2" domain
  domain="gui/$(id -u)"
  bootout_drain "$domain" "$label"
  launchctl bootstrap "$domain" "$plist"
}

# Write the tart LaunchAgent plist (com.yclaw.tart-<node>) and reload it. Needs $TART_BIN,
# $LAUNCH_AGENTS_DIR, $LOGS_DIR. Also used by resize-metal.sh — keep the metal --dir sets in sync.
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
