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
