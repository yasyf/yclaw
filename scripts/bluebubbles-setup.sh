#!/bin/bash
set -euo pipefail

# bluebubbles-setup.sh — idempotent, run ON the bluebubbles macOS VM (iMessage/BlueBubbles
# only; SIP off; its OWN tailnet node; holds NO credentials). Three subcommands:
#
#   setup   (default)  Bring up the BlueBubbles server + Private API helper, expose it on the
#                      tailnet, point its webhook at hermes, lock VNC to tailnet/LAN, and — because
#                      SIP is off — BEST-EFFORT auto-grant BlueBubbles the TCC permissions
#                      (Full Disk Access + Accessibility) the GUI would otherwise need. It then
#                      health-checks the server: if BlueBubbles + the Private API are up, it
#                      hardens automatically (disables Screen Sharing); if not, it leaves Screen
#                      Sharing up and prints the human GUI fallback. Apple-ID 2FA is the one step
#                      that stays human (Apple hardens it against scripting); do it first.
#
#   reconfigure        Re-apply ONLY the idempotent configuration `setup` lays down — config.json,
#                      the TCC grants, the tailnet serve, and both pf anchors — for a guest that is
#                      already up and signed in. SKIPS the Screen-Sharing enable/disable dance and
#                      every Apple-ID/iMessage step, and never rebuilds the disk image. Needs the
#                      same two env inputs (and same guard) as `setup`.
#
#   harden             Disable Screen Sharing + Remote Management (the post-bring-up step). Needs
#                      no credentials, so it is safe to invoke standalone (e.g. `just bb-harden`).
#
# This guest holds no host Keychain and no state share, so `setup`'s two config inputs arrive via
# the environment when the operator runs this script over SSH:
#   BLUEBUBBLES_PASSWORD   the BlueBubbles server password — on the host it lives in the dedicated
#                          yclaw keychain (scripts/lib/secrets.sh, service yclaw-bluebubbles-server-pass);
#                          export it before invoking, e.g.
#                            BLUEBUBBLES_PASSWORD=$(security find-generic-password -a "$USER" \
#                              -s yclaw-bluebubbles-server-pass -w ~/Library/Keychains/yclaw.keychain-db)
#   BLUEBUBBLES_ALLOWED_USERS  the iMessage allowlist — the same value seeded into the hermes
#                          node.env (BLUEBUBBLES_ALLOWED_USERS); export it, or `source` a node.env.
# Bare Tailscale MagicDNS resolves `hermes` on the tailnet, so the webhook needs no tailnet suffix.

WEBHOOK_URL="https://hermes"
BB_PORT="1234"
BB_CONFIG_DIR="${HOME}/Library/Application Support/bluebubbles-server"
BB_CONFIG="${BB_CONFIG_DIR}/config.json"
# Full Disk Access is a SYSTEM TCC permission; Accessibility is a per-USER one — they live in
# different databases, and writing Accessibility into the system DB does not take.
TCC_DB_SYSTEM="/Library/Application Support/com.apple.TCC/TCC.db"
TCC_DB_USER="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"

log()  { printf '\033[1;34m[bluebubbles]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bluebubbles] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bluebubbles] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# --- harden: disable Screen Sharing once bring-up is done (mirrors darwin/metal.nix) ----------
# Needs NO secrets, so the dispatch below reaches it without the setup env guards. `launchctl
# disable` writes the persistent override db (survives reboot); the ARDAgent kickstart tears the
# live Remote-Management/VNC service down now.
cmd_harden() {
  log "Hardening: disabling Screen Sharing + Remote Management (post-bring-up) ..."
  sudo launchctl disable system/com.apple.screensharing >/dev/null 2>&1 || true
  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -stop >/dev/null 2>&1 || true
  log "Screen Sharing disabled. (Re-run 'bluebubbles-setup.sh' with no args to re-enable it for maintenance.)"
}

# --- best-effort TCC csreq blob --------------------------------------------------------------
# Convert an app's code-signing requirement string into the binary blob TCC stores in its `csreq`
# column, via the Security framework (ctypes — no PyObjC needed). Prints lowercase hex on success;
# prints nothing and returns non-zero on any failure (the caller then inserts a NULL csreq).
csreq_hex() {
  local req="$1"
  [ -n "$req" ] || return 1
  REQ_STR="$req" /usr/bin/python3 - <<'PY' 2>/dev/null
import ctypes, ctypes.util, os, sys
req = os.environ["REQ_STR"]
Sec = ctypes.CDLL(ctypes.util.find_library("Security"))
CF = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFDataGetLength.restype = ctypes.c_long
CF.CFDataGetLength.argtypes = [ctypes.c_void_p]
CF.CFDataGetBytePtr.restype = ctypes.c_void_p
CF.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
Sec.SecRequirementCreateWithString.restype = ctypes.c_int32
Sec.SecRequirementCreateWithString.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
Sec.SecRequirementCopyData.restype = ctypes.c_int32
Sec.SecRequirementCopyData.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
cfstr = CF.CFStringCreateWithCString(None, req.encode(), 0x08000100)  # kCFStringEncodingUTF8
reqref = ctypes.c_void_p()
if cfstr is None or Sec.SecRequirementCreateWithString(cfstr, 0, ctypes.byref(reqref)) != 0:
    sys.exit(1)
dataref = ctypes.c_void_p()
if Sec.SecRequirementCopyData(reqref, 0, ctypes.byref(dataref)) != 0:
    sys.exit(1)
n = CF.CFDataGetLength(dataref)
blob = ctypes.string_at(CF.CFDataGetBytePtr(dataref), n)
sys.stdout.write(blob.hex())
PY
}

# --- best-effort TCC auto-grant (SIP-off ONLY; the health gate is the real guarantee) --------
# Grant BlueBubbles.app Full Disk Access + Accessibility by writing the SYSTEM TCC.db directly —
# possible only because this guest runs SIP-off. The access-table schema shifts across macOS
# releases, so this is BEST-EFFORT: any failure is non-fatal and the health gate falls back to the
# human GUI grant. Bundle id + csreq are resolved from the installed app, never hard-coded.
# The access-table row is keyed on the compound PK (service, client, client_type,
# indirect_object_identifier) since Big Sur — set indirect_object_identifier='UNUSED' explicitly.
# auth_value=2 (allowed), auth_reason=2 (user consent), client_type=0 (bundle id), auth_version=1.
_tcc_sql() {
  printf "INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier,csreq,flags,last_modified) VALUES('%s','%s',0,2,2,1,0,'UNUSED',%s,0,strftime('%%s','now'));" "$1" "$2" "$3"
}

# Insert a grant into one TCC.db, but only if that db already has an `access` table — sqlite3 on a
# missing/empty user db would silently create a schemaless file. $1 is a sudo prefix ("" or "sudo").
_tcc_insert() {
  local pfx="$1" db="$2" svc="$3" bundle="$4" csreq_sql="$5"
  $pfx sqlite3 "$db" 'SELECT 1 FROM access LIMIT 1;' >/dev/null 2>&1 || {
    warn "$db has no access table yet — leaving $svc for the GUI fallback"; return 1; }
  $pfx sqlite3 "$db" "$(_tcc_sql "$svc" "$bundle" "$csreq_sql")" 2>/dev/null
}

grant_tcc() {
  local app bundle req hex csreq_sql rc=0
  app="$(mdfind "kMDItemCFBundleIdentifier == 'com.BlueBubbles.BlueBubbles'" 2>/dev/null | head -1)"
  [ -d "$app" ] || app="/Applications/BlueBubbles.app"
  [ -d "$app" ] || { warn "BlueBubbles.app not found — skipping TCC auto-grant (health gate will fall back)"; return 1; }
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$bundle" ] || { warn "could not read BlueBubbles bundle id — skipping TCC auto-grant"; return 1; }
  req="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
  if hex="$(csreq_hex "$req")" && [ -n "$hex" ]; then csreq_sql="X'$hex'"; else
    warn "could not compute csreq for $bundle — inserting NULL csreq (TCC may reject; health gate covers it)"
    csreq_sql="NULL"
  fi
  # FDA is a SYSTEM permission (root db); Accessibility is per-USER (this GUI user's own db).
  _tcc_insert "sudo" "$TCC_DB_SYSTEM" kTCCServiceSystemPolicyAllFiles "$bundle" "$csreq_sql" || rc=1
  _tcc_insert ""     "$TCC_DB_USER"   kTCCServiceAccessibility        "$bundle" "$csreq_sql" || rc=1
  # tccd caches its state and would overwrite a direct write — reload it so the grants take effect
  # THIS session (otherwise they are not observed until a reboot, and the health gate would fail).
  sudo launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] && log "TCC auto-grant applied for $bundle (FDA + Accessibility)." \
                  || warn "TCC auto-grant partially failed for $bundle (health gate will fall back)."
  return $rc
}

# --- BlueBubbles REST health ------------------------------------------------------------------
# Poll the local REST API until BlueBubbles answers AND the Private API HELPER has injected into
# Messages.app, or the timeout. server/info returns two distinct fields: `private_api` is just the
# config toggle (always true here — we set enable_private_api), while `helper_connected` is the real
# runtime status the TCC grant exists to achieve — so gate on that. Conservative: if it can't be
# confirmed, return non-fatal failure so the caller falls back rather than disabling VNC prematurely.
bb_healthy() {
  local pw="$1" i info
  for i in $(seq 1 30); do
    if curl -sf --max-time 5 "http://localhost:${BB_PORT}/api/v1/ping?password=${pw}" >/dev/null 2>&1; then
      info="$(curl -sf --max-time 5 "http://localhost:${BB_PORT}/api/v1/server/info?password=${pw}" 2>/dev/null || true)"
      printf '%s' "$info" | grep -qiE '"helper_connected"[[:space:]]*:[[:space:]]*true' && return 0
    fi
    sleep 2
  done
  return 1
}

# --- shared idempotent config steps (re-applied by both `setup` and `reconfigure`) ------------

# Write the server config idempotently: fixed REST port, server password, the
# authorized-sender allowlist, and the hermes webhook. BlueBubbles reads this on
# launch; a running server also re-reads on restart. The config carries the server
# password, so it is written 0600 under a 0700 dir (umask 077 on the write, mirroring
# the host-side secrets discipline in scripts/lib/secrets.sh) — never world-readable.
write_config() {
  local BB_PASSWORD="$1" AUTHORIZED_HANDLES="$2"
  mkdir -p "${BB_CONFIG_DIR}"
  chmod 700 "${BB_CONFIG_DIR}"
  ( umask 077; cat > "${BB_CONFIG}" <<EOF
{
  "password": "${BB_PASSWORD}",
  "socket_port": ${BB_PORT},
  "enable_private_api": true,
  "auto_start": true,
  "authorized_handles": "${AUTHORIZED_HANDLES}",
  "webhooks": [
    { "url": "${WEBHOOK_URL}", "events": ["new-message"] }
  ]
}
EOF
  )
  chmod 600 "${BB_CONFIG}"
  # TODO(human): confirm BlueBubbles' actual config.json key names + path on the
  # pinned server version — the catalog fixes the values (port 1234, password,
  # webhook host hermes.<tailnet>, authorized-sender allowlist) but the exact JSON
  # schema (keys, webhook event names, allowlist field) is unverified here. The
  # /api/v1/ping + /api/v1/server/info health probe below shares that caveat.
}

# Expose BlueBubbles on the tailnet at https://bluebubbles.<tailnet>:443 -> :1234.
# Idempotent: only (re)serve if 1234 is not already mapped on 443.
serve_tailnet() {
  if ! tailscale serve status 2>/dev/null | grep -q "${BB_PORT}"; then
    tailscale serve --bg --https=443 "${BB_PORT}"
  fi
}

# `tailscale serve` only adds the :443 front door; BlueBubbles still binds the raw
# socket_port :1234 on every interface, reachable on the bridged LAN behind only the
# app password. Lock it down with a pf anchor (same idempotent install convention as the
# VNC anchor below): inbound :1234 only from the tailnet CGNAT + loopback, blocked elsewhere.
install_rest_anchor() {
  local BB_PF_ANCHOR_FILE="/etc/pf.anchors/bluebubbles-rest"
  sudo mkdir -p /etc/pf.anchors

  sudo tee "$BB_PF_ANCHOR_FILE" > /dev/null <<EOF
pass in quick proto tcp from 100.64.0.0/10 to any port ${BB_PORT}
pass in quick on lo0 proto tcp to any port ${BB_PORT}
block in quick proto tcp from any to any port ${BB_PORT}
EOF

  # Wire the anchor into pf.conf if not already present
  if ! grep -q 'anchor "bluebubbles-rest"' /etc/pf.conf; then
    sudo bash -c 'cat >> /etc/pf.conf <<CONF

anchor "bluebubbles-rest"
load anchor "bluebubbles-rest" from "/etc/pf.anchors/bluebubbles-rest"
CONF'
  fi

  sudo pfctl -f /etc/pf.conf
}

# pf anchor: allow VNC only from Tailscale + private networks. Re-applied on `reconfigure` to keep
# the firewall rules current; the Screen-Sharing SERVICE state itself is left untouched there.
install_vnc_anchor() {
  local PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
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
}

# --- setup (default) --------------------------------------------------------------------------
cmd_setup() {
  local BB_PASSWORD AUTHORIZED_HANDLES
  BB_PASSWORD="${BLUEBUBBLES_PASSWORD:?export BLUEBUBBLES_PASSWORD (yclaw keychain service yclaw-bluebubbles-server-pass)}"
  AUTHORIZED_HANDLES="${BLUEBUBBLES_ALLOWED_USERS:?export BLUEBUBBLES_ALLOWED_USERS (the iMessage allowlist; same value as hermes node.env)}"

  # 1. SIP must be off for BlueBubbles' Private API helper to load — fail loud if not.
  # The SIP-off state comes from cloning the cirruslabs SIP-disabled base
  # (ghcr.io/cirruslabs/macos-tahoe-base, see packer/bluebubbles.pkr.hcl), NOT from a
  # manual recovery `csrutil disable`. A SIP-on guest here means the wrong base image.
  if ! csrutil status | grep -q 'disabled'; then
    echo "FATAL: SIP is still enabled. BlueBubbles' Private API helper cannot load." >&2
    echo "       This VM must be cloned from the cirruslabs SIP-disabled base" >&2
    echo "       (ghcr.io/cirruslabs/macos-tahoe-base, see packer/bluebubbles.pkr.hcl)." >&2
    csrutil status >&2
    exit 1
  fi

  # 2. BlueBubbles server + Private API (SIP-off iMessage extension).
  # The .app install and Apple-ID sign-in are GUI/2FA steps that cannot be scripted; the cask
  # install, config, helper toggle, and TCC grants below ARE scriptable.
  # HUMAN: Sign in to iCloud with the dedicated Apple ID (@@APPLE_ID@@ / @@APPLE_ID_PW@@) BEFORE
  # HUMAN: running this script. The BlueBubbles GUI grants (Full Disk Access, Accessibility, the
  # HUMAN: "Private API" toggle) are auto-applied below where SIP-off allows — but if the health
  # HUMAN: check at the end fails, finish them in the GUI, then re-run or `just bb-harden`.
  if ! brew list --cask bluebubbles-server >/dev/null 2>&1; then
    brew install --cask bluebubbles-server || \
      echo "HUMAN: 'brew install --cask bluebubbles-server' failed — install BlueBubbles.app by hand from https://bluebubbles.app then re-run." >&2
  fi

  write_config "$BB_PASSWORD" "$AUTHORIZED_HANDLES"

  # SIP-off lets us grant the GUI permissions programmatically; do it before first launch so the
  # Private API helper can load on start.
  grant_tcc || true

  # Start the server (idempotent: open is a no-op if already running).
  open -ga "BlueBubbles" 2>/dev/null || \
    echo "HUMAN: BlueBubbles.app not yet installed — start it manually after the GUI install above." >&2

  # 3. Expose BlueBubbles on the tailnet at https://bluebubbles.<tailnet>:443 -> :1234.
  serve_tailnet

  install_rest_anchor

  # 4. (config + webhook handled in §2 above via ${BB_CONFIG}.)

  # 5. VNC: Screen Sharing + pf anchor (locked to tailnet CGNAT + RFC1918).
  # Do NOT "fix" the block below; it is load-bearing exactly as written. Screen Sharing stays ON
  # through bring-up so a human can finish any GUI grant the TCC auto-grant could not; §6 disables
  # it automatically once the health check confirms the server is up.

  # Enable Screen Sharing
  sudo launchctl enable system/com.apple.screensharing
  sudo launchctl bootstrap system \
    /System/Library/LaunchDaemons/com.apple.screensharing.plist

  install_vnc_anchor

  # 6. Health-gate the auto-harden. If BlueBubbles + the Private API came up, the GUI grants took —
  # disable Screen Sharing now (no human needed). Otherwise leave it up and print the GUI fallback.
  log "Waiting for BlueBubbles to come up (server + Private API) ..."
  if bb_healthy "$BB_PASSWORD"; then
    log "BlueBubbles is healthy — the TCC auto-grant took. Hardening now."
    cmd_harden
  else
    warn "BlueBubbles did not report healthy (server or Private API not up)."
    cat >&2 <<'FALLBACK'
HUMAN FALLBACK — the auto-grant did not fully take. Over Screen Sharing (still enabled):
  1. System Settings → Privacy & Security → Full Disk Access → enable BlueBubbles.
  2. System Settings → Privacy & Security → Accessibility → enable BlueBubbles.
  3. In BlueBubbles, enable "Private API" so the helper installs into Messages.app.
Then run:  bluebubbles-setup.sh harden     (or `just bb-harden` from the host)
to disable Screen Sharing once you are done.

If "Private API" stays disconnected on macOS 26 (Tahoe) EVEN after the grants, the pinned
BlueBubbles server/helper may predate Tahoe support (server issue #776) — update to a
Tahoe-compatible server+helper version; the GUI grants alone cannot fix a non-injecting helper.
FALLBACK
  fi
}

# --- reconfigure: re-apply the idempotent config WITHOUT the Screen-Sharing dance -------------
# For a guest that is already up and signed in: re-write config.json, re-grant TCC, re-serve on
# the tailnet, and re-install both pf anchors — the idempotent state `setup` lays down — but NONE
# of the Screen-Sharing enable/disable dance and NONE of the Apple-ID/iMessage steps. Never
# rebuilds the disk image or touches Messages/Apple-ID state. Takes the same two env inputs as
# `setup` (same guard), and the helpers it calls run their sudo steps as root exactly as in setup.
cmd_reconfigure() {
  local BB_PASSWORD AUTHORIZED_HANDLES
  BB_PASSWORD="${BLUEBUBBLES_PASSWORD:?export BLUEBUBBLES_PASSWORD (yclaw keychain service yclaw-bluebubbles-server-pass)}"
  AUTHORIZED_HANDLES="${BLUEBUBBLES_ALLOWED_USERS:?export BLUEBUBBLES_ALLOWED_USERS (the iMessage allowlist; same value as hermes node.env)}"

  write_config "$BB_PASSWORD" "$AUTHORIZED_HANDLES"
  grant_tcc || true
  serve_tailnet
  install_rest_anchor
  install_vnc_anchor
  log "Reconfigure complete — config, TCC grants, tailnet serve, and pf anchors re-applied (Screen Sharing untouched)."
}

# --- dispatch (BEFORE any env guard, so `harden` needs no secrets) ----------------------------
case "${1:-setup}" in
  setup)       cmd_setup ;;
  reconfigure) cmd_reconfigure ;;
  harden)      cmd_harden ;;
  *) die "unknown subcommand: '$1' (expected: setup | reconfigure | harden)" ;;
esac
