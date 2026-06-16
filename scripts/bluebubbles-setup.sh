#!/bin/bash
set -euo pipefail

# bluebubbles-setup.sh — idempotent, run ON the bluebubbles macOS VM.
# Brings up the BlueBubbles server + Private API helper, exposes it on the
# tailnet, points its webhook at hermes, and locks VNC to tailnet/LAN via pf.
# One-time human gates (recovery-mode SIP off, Apple-ID 2FA, app GUI grants)
# are flagged `HUMAN:` and the script continues with what is scriptable.

BB_PASSWORD="@@BLUEBUBBLES_PASSWORD@@"
AUTHORIZED_HANDLES="@@AUTHORIZED_HANDLES@@"
TAILNET_DOMAIN="@@TAILNET_DOMAIN@@"
WEBHOOK_URL="https://hermes.${TAILNET_DOMAIN}"
BB_PORT="1234"
BB_CONFIG_DIR="${HOME}/Library/Application Support/bluebubbles-server"
BB_CONFIG="${BB_CONFIG_DIR}/config.json"

# 1. SIP must be off (see scripts/sip-disable.md) — fail loud if still enabled.
if ! csrutil status | grep -q 'disabled'; then
  echo "FATAL: SIP is still enabled. BlueBubbles' Private API helper cannot load." >&2
  echo "       Boot recovery mode and run csrutil disable (see scripts/sip-disable.md)." >&2
  csrutil status >&2
  exit 1
fi

# 2. BlueBubbles server + Private API (SIP-off iMessage extension).
# The .app install and Apple-ID sign-in are GUI/2FA steps that cannot be scripted;
# everything below (cask install attempt, config, helper toggle) IS scriptable.
# HUMAN: Sign in to iCloud with the dedicated Apple ID (@@APPLE_ID@@ / @@APPLE_ID_PW@@)
# HUMAN: and complete the BlueBubbles first-run GUI: grant Full Disk Access and
# HUMAN: Accessibility to BlueBubbles.app, then enable "Private API" in its UI so
# HUMAN: the helper bundle installs into Messages.app (requires the SIP-off state above).
if ! brew list --cask bluebubbles-server >/dev/null 2>&1; then
  brew install --cask bluebubbles-server || \
    echo "HUMAN: 'brew install --cask bluebubbles-server' failed — install BlueBubbles.app by hand from https://bluebubbles.app then re-run." >&2
fi

# Write the server config idempotently: fixed REST port, server password, the
# authorized-sender allowlist, and the hermes webhook. BlueBubbles reads this on
# launch; a running server also re-reads on restart.
mkdir -p "${BB_CONFIG_DIR}"
cat > "${BB_CONFIG}" <<EOF
{
  "password": "${BB_PASSWORD}",
  "socket_port": ${BB_PORT},
  "enable_private_api": true,
  "auto_start": true,
  "authorized_handles": "${AUTHORIZED_HANDLES}",
  "webhooks": [
    { "url": "${WEBHOOK_URL}", "events": ["new-message", "updated-message"] }
  ]
}
EOF
# TODO(human): confirm BlueBubbles' actual config.json key names + path on the
# pinned server version — the catalog fixes the values (port 1234, password,
# webhook host hermes.<tailnet>, authorized-sender allowlist) but the exact JSON
# schema (keys, webhook event names, allowlist field) is unverified here.

# Start the server (idempotent: open is a no-op if already running).
open -ga "BlueBubbles" 2>/dev/null || \
  echo "HUMAN: BlueBubbles.app not yet installed — start it manually after the GUI install above." >&2

# 3. Expose BlueBubbles on the tailnet at https://bluebubbles.<tailnet>:443 -> :1234.
# Idempotent: only (re)serve if 1234 is not already mapped on 443.
if ! tailscale serve status 2>/dev/null | grep -q "${BB_PORT}"; then
  tailscale serve --bg --https=443 "${BB_PORT}"
fi

# 4. (config + webhook handled in §2 above via ${BB_CONFIG}.)

# 5. VNC: Screen Sharing + pf anchor (locked to tailnet CGNAT + RFC1918).
# Reproduced VERBATIM from openclaw.md / tart-nixos-darwin.md §4.2 — do NOT "fix".

# Enable Screen Sharing
sudo launchctl enable system/com.apple.screensharing
sudo launchctl bootstrap system \
  /System/Library/LaunchDaemons/com.apple.screensharing.plist

# pf anchor: allow VNC only from Tailscale + private networks
PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
sudo mkdir -p /etc/pf.anchors

sudo tee "$PF_ANCHOR_FILE" > /dev/null <<'EOF'
table <vnc_allowed> { \
  100.64.0.0/10, \
  192.168.0.0/16, \
  10.0.0.0/8, \
  172.16.0.0/12 \
}
pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
block in quick proto { tcp udp } from any to any port 5900:5902
EOF

# Wire the anchor into pf.conf if not already present
if ! grep -q 'anchor "vnc"' /etc/pf.conf; then
  sudo bash -c 'cat >> /etc/pf.conf <<CONF

anchor "vnc"
load anchor "vnc" from "/etc/pf.anchors/vnc"
CONF'
fi

sudo pfctl -f /etc/pf.conf
