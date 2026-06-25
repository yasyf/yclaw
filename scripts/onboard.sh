#!/usr/bin/env bash
# scripts/onboard.sh — the post-bootstrap onboarding TUI. `just bootstrap` automates every
# mechanical step and stops at the credential ceremonies the providers keep human; THIS script
# is the guided, idempotent, re-runnable driver for those gates:
#
#   Gate 0  Tailscale SSH check — surface the `action: check` re-auth URL the bootstrap probes
#           swallow with 2>/dev/null, so the operator can approve it (silent-hang fix).
#   Gate A  hermes identity (USER.md + SOUL.md + Honcho peer) via hermes-onboard.
#   Gate B  CLIProxyAPI Codex login (ChatGPT account) on metal.
#   Gate C  CLIProxyAPI Gemini login (personal Google) on metal — port-forwarded callback.
#   Gate D  agent-vault Google Workspace OAuth (scripts/connect-google-oauth.py).
#   Gate E  Apple-ID iMessage / BlueBubbles bring-up on the bluebubbles VM.
#   Final   just validate + just smoke.
#
# It NEVER mints or regenerates a secret (scripts/bootstrap.sh owns that): the only keychain touch
# is a READ of existing passwords. It enters a zellij session (the operator gets a real multiplexer;
# the interactive cli-proxy logins run as subprocesses in their own panes) unless already inside one,
# tmux is the fallback, and YCLAW_ONBOARD_NO_ZELLIJ=1 forces an inline run with no multiplexer.
#
# Multiplexer rule of thumb (verified against the live stack):
#   * `tailscale ssh <user>@<host> -- <cmd>` for every NON-interactive remote command + stdin pipe
#     (proven throughout bootstrap.sh / redeploy.sh; resolves MagicDNS; no -L, no -t).
#   * plain `ssh -t [-L …] root@metal` ONLY for the interactive cli-proxy logins — Tailscale SSH
#     intercepts port 22, so plain ssh authenticates transparently AND supports the PTY + the
#     local port-forward the Gemini callback needs. `tailscale ssh` is just a wrapper around the
#     system ssh and exposes neither -t nor -L.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# Sourced ONLY for _yclaw_keychain_unlock/_lock, the KC_SERVICE_* names, and $YCLAW_KEYCHAIN /
# $YCLAW_STATE — collect_secrets is never called, so nothing is minted (mirrors redeploy.sh).
# shellcheck source=scripts/lib/secrets.sh
source "$REPO_ROOT/scripts/lib/secrets.sh"

SELF="$REPO_ROOT/scripts/onboard.sh"
SESSION="yclaw-onboard"
STATUS_DIR="$YCLAW_STATE/onboard"
LAYOUT_FILE="$STATUS_DIR/layout.kdl"
NODE_CONFIG_DIR="$HOME/.config/yclaw/vm-secrets"   # bootstrap.sh's hermes node-config share source
GOOGLE_OAUTH="$REPO_ROOT/scripts/connect-google-oauth.py"

# CLIProxyAPI (metal): verified against router-for-me/CLIProxyAPI @ the commit pkgs/cli-proxy-api.nix pins.
CLIPROXY_CONFIG="/Volumes/My Shared Files/cliproxy/config.yaml"   # the wrapper's rendered runtime config
CLIPROXY_AUTH="/Volumes/My Shared Files/cliproxy/auth"            # token files land here
CLIPROXY_LABEL="system/org.nixos.cliproxy"                        # launchd.daemons.cliproxy
CODEX_CALLBACK_PORT=1455     # Codex --no-browser callback (paste fallback also armed after 15s)
GEMINI_CALLBACK_PORT=8085    # Gemini --no-browser callback (NO paste fallback without --project_id)
GOOGLE_OAUTH_PORT=8723       # connect-google-oauth.py loopback consent port (host-side)

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
CHECK_URL_RE='https://login\.tailscale\.com/a/[A-Za-z0-9]+'

# --- UI (gum) ---------------------------------------------------------------------------------
hdr()  { gum style --border rounded --padding "0 2" --margin "1 0" --border-foreground 212 "$@"; }
note() { gum style --foreground 244 "  $*"; }
ok()   { gum style --foreground 84  "  ✓ $*"; }
warn() { gum style --foreground 214 "  ! $*" >&2; }
err()  { gum style --foreground 196 "  ✗ $*" >&2; }
pause(){ printf '  ↵ %s ' "${1:-press Enter to continue…}"; read -r _ || true; }
confirm() { gum confirm "$1"; }   # 0 = yes, 1 = no

# --- ssh helpers ------------------------------------------------------------------------------

# Run a non-interactive remote command over the proven Tailscale SSH path. Stdin is forwarded
# (so callers can pipe a heredoc / script), stderr passes through.
tsh() { tailscale ssh "$@"; }

# Probe + surface the `action: check` re-auth URL for one node, looping until the operator has
# approved it (or gives up). $1 = user@host, $2 = human label. The bootstrap probes hide this URL
# with 2>/dev/null and hang silently; here we capture it and present it. Returns 0 once SSH works.
clear_check() {
  local target="$1" label="$2" out url rc
  local attempt
  for attempt in 1 2 3 4 5 6; do
    # A failed probe is the EXPECTED path (check needed / unreachable), so capture rc without letting
    # set -e abort at the assignment — correct independent of how the caller invokes clear_check.
    rc=0; out="$(timeout 25 tailscale ssh "$target" -- true 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$attempt" -eq 1 ]; then ok "$label reachable (Tailscale SSH check satisfied)."
      else ok "$label now reachable — check approved."; fi
      return 0
    fi
    url="$(printf '%s\n' "$out" | grep -oE "$CHECK_URL_RE" | head -1 || true)"
    if [ -z "$url" ]; then
      err "$label not reachable over Tailscale SSH and no check URL was printed:"
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      confirm "Retry reaching $label?" || return 1
      continue
    fi
    hdr "Tailscale wants you to re-authorize SSH → $label" \
        "Open this URL, sign in, and approve (≈12h window, then it stops asking):" \
        "$url"
    if confirm "Open it in your browser now?"; then open "$url" >/dev/null 2>&1 || true; fi
    pause "approve in the browser, then press Enter to re-check"
  done
  err "Gave up clearing the Tailscale SSH check for $label after several attempts."
  return 1
}

# Resolve the exact cli-proxy-api binary the daemon runs (the Nix store hash changes every metal
# rebuild — never hardcode it). Prefer the running process's argv[0]; fall back to the store glob.
resolve_cliproxy_bin() {
  local bin
  bin="$(ssh "${SSH_OPTS[@]}" root@metal \
    "ps -axo command 2>/dev/null | grep -m1 '[c]li-proxy-api --config' | awk '{print \$1}'" 2>/dev/null || true)"
  if [ -z "$bin" ]; then
    bin="$(ssh "${SSH_OPTS[@]}" root@metal \
      "ls -t /nix/store/*-cli-proxy-api-*/bin/cli-proxy-api 2>/dev/null | head -1" 2>/dev/null || true)"
  fi
  printf '%s' "$bin"
}

# Reload the cliproxy daemon so it picks up freshly-written auth tokens (best-effort, non-fatal).
reload_cliproxy() {
  ssh "${SSH_OPTS[@]}" root@metal "launchctl kickstart -k $CLIPROXY_LABEL" >/dev/null 2>&1 || true
}

# List the cli-proxy auth-dir token files matching $1 (a shell glob), one per line. Empty if none.
cliproxy_auth_files() {
  ssh "${SSH_OPTS[@]}" root@metal "ls -1 \"$CLIPROXY_AUTH\"/$1 2>/dev/null" 2>/dev/null || true
}

# True if a Gemini OAuth token is present. Gemini tokens are <email>-<project>.json (no provider
# prefix), so match positively: a *.json that carries an email (@) and is NOT a codex- token. On this
# Codex+Gemini-only stack that is exactly the Gemini token (and ignores a stray non-token .json).
gemini_logged_in() {
  ssh "${SSH_OPTS[@]}" root@metal \
    "ls -1 \"$CLIPROXY_AUTH\"/*.json 2>/dev/null | grep -v '/codex-' | grep -q '@'" 2>/dev/null
}

# ==============================================================================================
# Gate A — hermes identity (USER.md + SOUL.md + Honcho peer)
# ==============================================================================================

# Emit USER_OK / SOUL_OK lines for whichever identity files hermes-onboard has already written.
# Re-derives the exact paths from the installed script (writeShellApplication bakes them in) so we
# never hardcode cfg.stateDir / cfg.workingDirectory. Piped over stdin (bash -s) to dodge the
# tailscale-ssh remote-arg word-split.
hermes_identity_state() {
  tsh admin@hermes -- sudo -u hermes -H bash -s <<'PROBE' 2>/dev/null || true
s="$(command -v hermes-onboard)" || exit 0
eval "$(grep -E '^[[:space:]]*(export HOME=|export HERMES_HOME=|workspace=|memdir=|usermd=|soulmd=)' "$s")"
[ -s "$usermd" ] && echo USER_OK
[ -s "$soulmd" ] && echo SOUL_OK
exit 0
PROBE
}

gate_a_hermes() {
  local state user_ok="" soul_ok=""
  state="$(hermes_identity_state)"
  case "$state" in *USER_OK*) user_ok=1 ;; esac
  case "$state" in *SOUL_OK*) soul_ok=1 ;; esac

  if [ -n "$user_ok" ] && [ -n "$soul_ok" ]; then
    ok "hermes already onboarded (USER.md + SOUL.md present)."
    return 0
  fi

  hdr "Gate A — hermes identity"
  note "Seeds the profile (USER.md) and persona (SOUL.md) hermes-onboard can't infer, then the Honcho peer."
  local name about persona feed=""
  if [ -z "$user_ok" ]; then
    name="$(gum input --prompt "  Your name ❯ " --placeholder "e.g. Rebecca")"
    about="$(gum input --prompt "  A sentence or two about you ❯ " --placeholder "the agent remembers this")"
    feed+="$name"$'\n'"$about"$'\n'
  else
    ok "USER.md already present — keeping it."
  fi
  if [ -z "$soul_ok" ]; then
    persona="$(gum input --prompt "  Agent persona in one line ❯ " --placeholder "blank = sensible default")"
    feed+="$persona"$'\n'
  else
    ok "SOUL.md already present — keeping it."
  fi

  note "Running hermes-onboard on hermes (feeding your answers) …"
  if printf '%s' "$feed" | tsh admin@hermes -- sudo -u hermes -H hermes-onboard; then
    state="$(hermes_identity_state)"
    if [[ "$state" == *USER_OK* && "$state" == *SOUL_OK* ]]; then
      ok "hermes identity written (USER.md + SOUL.md)."
      return 0
    fi
  fi
  err "hermes onboarding did not leave both USER.md and SOUL.md — re-run Gate A."
  return 1
}

# ==============================================================================================
# Gate B / C — CLIProxyAPI logins (interactive; run in their own pane via run_interactive_gate)
# ==============================================================================================

gate_codex_login() {
  local bin
  if [ -n "$(cliproxy_auth_files 'codex-*.json')" ]; then
    ok "Codex already logged in (codex-*.json present in the cli-proxy auth-dir)."
    return 0
  fi
  bin="$(resolve_cliproxy_bin)"
  [ -n "$bin" ] || { err "Could not locate cli-proxy-api on metal (is the daemon running?)."; return 1; }

  hdr "Gate B — CLIProxyAPI Codex login"
  note "A URL prints below. Open it, approve with your ChatGPT-subscription Google/OpenAI account."
  note "The browser will try to redirect to http://localhost:${CODEX_CALLBACK_PORT}/auth/callback and FAIL to load"
  note "— that is expected. Copy the FULL url from the address bar and paste it here (the prompt arms after ~15s)."
  echo
  # Codex --no-browser arms a stdin paste fallback, so no tunnel is needed: paste the failed
  # redirect URL back. Run as `admin` (the daemon's user) so tokens land readable by the daemon.
  ssh -t "${SSH_OPTS[@]}" root@metal \
    "sudo -u admin '$bin' --config '$CLIPROXY_CONFIG' --codex-login --no-browser"

  if [ -n "$(cliproxy_auth_files 'codex-*.json')" ]; then
    reload_cliproxy
    ok "Codex login succeeded (codex-*.json written)."
    return 0
  fi
  err "No codex-*.json appeared in the cli-proxy auth-dir — Codex login did not complete."
  return 1
}

gate_gemini_login() {
  local bin
  if gemini_logged_in; then
    ok "Gemini already logged in (token present in the cli-proxy auth-dir)."
    return 0
  fi
  bin="$(resolve_cliproxy_bin)"
  [ -n "$bin" ] || { err "Could not locate cli-proxy-api on metal (is the daemon running?)."; return 1; }

  hdr "Gate C — CLIProxyAPI Gemini login"
  note "A URL prints below. Open it and approve with your personal Google account."
  note "When asked, choose option 2 (Google One / personal account, auto-discover project)."
  note "The callback is port-forwarded, so after you approve the browser redirect completes itself — no paste."
  echo
  # Gemini --login --no-browser has NO stdin paste fallback unless --project_id is passed, so we
  # forward its localhost:8085 callback through plain ssh: the operator's browser redirect to
  # localhost:8085/oauth2callback tunnels to metal's callback server. Run as `admin` (daemon user).
  ssh -t "${SSH_OPTS[@]}" -L "${GEMINI_CALLBACK_PORT}:127.0.0.1:${GEMINI_CALLBACK_PORT}" root@metal \
    "sudo -u admin '$bin' --config '$CLIPROXY_CONFIG' --login --no-browser"

  if gemini_logged_in; then
    reload_cliproxy
    ok "Gemini login succeeded (token written)."
    return 0
  fi
  err "No Gemini token appeared in the cli-proxy auth-dir — Gemini login did not complete."
  return 1
}

# ==============================================================================================
# Gate D — agent-vault Google Workspace OAuth
# ==============================================================================================

gate_d_google_oauth() {
  # Guard BEFORE unlock: _yclaw_keychain_unlock's create branch would MINT a fresh keychain if absent,
  # which onboard must never do (mirrors redeploy.sh's guard-before-unlock).
  [ -f "$YCLAW_KEYCHAIN" ] || { err "no yclaw keychain — run \`just bootstrap\` first."; return 1; }
  _yclaw_keychain_unlock
  if "$GOOGLE_OAUTH" check 2>/dev/null | grep -q CONNECTED; then
    _yclaw_keychain_lock
    ok "Google Workspace OAuth already connected to the hermes vault."
    return 0
  fi

  hdr "Gate D — agent-vault Google Workspace OAuth"
  note "Reuses your local gws desktop OAuth client; you approve ONE consent URL in a browser on this Mac."
  local line url=""
  # Run the connect script, surface its CONSENT_URL as soon as it prints, then wait for the verdict.
  while IFS= read -r line; do
    case "$line" in
      "CONSENT_URL: "*)
        url="${line#CONSENT_URL: }"
        hdr "Open this consent URL, approve the requested scopes:" "$url"
        if confirm "Open it in your browser now?"; then open "$url" >/dev/null 2>&1 || true; fi
        note "Waiting for you to approve (the loopback on :${GOOGLE_OAUTH_PORT} captures the result, 10-min ceiling) …"
        ;;
      "OAUTH_STATUS: "*) printf '%s\n' "$line" | grep -q '"connected":[[:space:]]*true' \
          && { _yclaw_keychain_lock; ok "Google Workspace OAuth connected."; return 0; } ;;
      "UPLOAD_RESULT: "*) note "uploaded to vault." ;;
      TIMEOUT*|ERROR*) err "$line" ;;
    esac
  done < <("$GOOGLE_OAUTH")
  _yclaw_keychain_lock
  err "Google OAuth did not report connected:true — re-run Gate D."
  return 1
}

# ==============================================================================================
# Gate E — Apple-ID iMessage / BlueBubbles
# ==============================================================================================

# Read the BlueBubbles server health from the host. Echoes HEALTHY / UNHEALTHY / UNREACHABLE.
bluebubbles_health() {
  local pw="$1" info
  info="$(curl -sf --max-time 8 "https://bluebubbles/api/v1/server/info?password=${pw}" 2>/dev/null || true)"
  [ -z "$info" ] && { echo UNREACHABLE; return; }
  printf '%s' "$info" | grep -qiE '"helper_connected"[[:space:]]*:[[:space:]]*true' \
    && echo HEALTHY || echo UNHEALTHY
}

gate_e_bluebubbles() {
  local bb_pw allowlist
  # Guard BEFORE unlock (mirrors redeploy.sh): the create branch in _yclaw_keychain_unlock would mint a
  # fresh keychain if absent, which onboard must never do.
  [ -f "$YCLAW_KEYCHAIN" ] || { err "no yclaw keychain — run \`just bootstrap\` first."; return 1; }
  _yclaw_keychain_unlock
  bb_pw="$(security find-generic-password -a "$USER" -s "$KC_SERVICE_BLUEBUBBLES_SERVER" -w "$YCLAW_KEYCHAIN")"
  _yclaw_keychain_lock

  if [ "$(bluebubbles_health "$bb_pw")" = HEALTHY ]; then
    ok "BlueBubbles already healthy (server + Private API helper connected)."
    return 0
  fi

  hdr "Gate E — Apple-ID iMessage / BlueBubbles"
  note "The one irreducibly-human gate: sign into the dedicated Apple ID + 2FA in the VNC window."
  note "You type the Apple-ID password and 2FA code in the GUI — they never touch this script."
  if confirm "Open Screen Sharing to the bluebubbles VM now?"; then
    open "vnc://bluebubbles" >/dev/null 2>&1 || warn "could not launch Screen Sharing — open vnc://bluebubbles by hand."
  fi
  pause "in the VNC window: sign in to iCloud/iMessage, complete 2FA, enable iMessage — then press Enter"

  # Source the allowlist (NON-secret) bootstrap.sh wrote, exactly as redeploy.sh does.
  [ -f "$NODE_CONFIG_DIR/node.env" ] || { err "no $NODE_CONFIG_DIR/node.env (the iMessage allowlist) — run \`just bootstrap\`."; return 1; }
  # shellcheck disable=SC1091
  . "$NODE_CONFIG_DIR/node.env"
  allowlist="${BLUEBUBBLES_ALLOWED_USERS:?node.env has no BLUEBUBBLES_ALLOWED_USERS}"

  note "Running bluebubbles-setup.sh on the guest (config, TCC grants, tailnet serve, health gate) …"
  tsh root@bluebubbles -- \
    env BLUEBUBBLES_PASSWORD="$bb_pw" BLUEBUBBLES_ALLOWED_USERS="$allowlist" \
    bash -s setup < "$REPO_ROOT/scripts/bluebubbles-setup.sh" || true

  if [ "$(bluebubbles_health "$bb_pw")" = HEALTHY ]; then
    ok "BlueBubbles healthy — setup auto-hardened (Screen Sharing disabled)."
    return 0
  fi
  warn "BlueBubbles is not healthy yet. The setup script printed a HUMAN FALLBACK above — over the still-open"
  warn "Screen Sharing session grant BlueBubbles Full Disk Access + Accessibility and enable its Private API,"
  warn "then run \`just bb-harden\` (or re-run Gate E)."
  return 1
}

# ==============================================================================================
# Final — validate + smoke
# ==============================================================================================

gate_final() {
  hdr "Final — validate + smoke"
  if confirm "Run \`just validate\` (per-VM isolation + audit hardening probes)?"; then
    just validate || warn "just validate reported failures (see above)."
  fi
  if confirm "Run \`just smoke\` (nix flake check + model-plane curl + hermes doctor)?"; then
    just smoke || warn "just smoke reported failures (see above)."
  fi
  note "Final manual check: send an iMessage from an allowlisted handle and confirm hermes replies"
  note "(and that a non-allowlisted handle is ignored)."
}

# ==============================================================================================
# Gate runner (executes inside a spawned pane or inline) + driver
# ==============================================================================================

# Run one interactive gate; in a zellij/tmux session it gets its own pane and we wait on a sentinel
# rc file, otherwise it runs inline in the current terminal. $1 = key (codex|gemini), $2 = label.
run_interactive_gate() {
  local key="$1" label="$2"
  local rcfile="$STATUS_DIR/$key.rc" waited=0 ceiling=2400
  mkdir -p "$STATUS_DIR"; rm -f "$rcfile"
  if [ -n "${ZELLIJ:-}" ]; then
    note "Opening a pane for $label — interact with it there; this guide waits for it to finish."
    if ! zellij action new-pane --name "$label" --close-on-exit --cwd "$REPO_ROOT" -- \
           bash -lc "YCLAW_ONBOARD_INNER=1 '$SELF' __gate '$key'" >/dev/null; then
      err "Failed to open a zellij pane for $label."; return 1
    fi
    while [ ! -f "$rcfile" ]; do
      sleep 3; waited=$((waited + 3))
      if [ "$waited" -ge "$ceiling" ]; then warn "Timed out waiting for the $label pane."; return 1; fi
    done
    pause "when the $label pane has closed, press Enter to continue"
    return "$(cat "$rcfile")"
  fi
  YCLAW_ONBOARD_INNER=1 "$SELF" __gate "$key"
}

# The body run inside a pane (or inline): execute one gate, persist its rc, and — in a pane — hold
# so the operator can read the result before --close-on-exit tears the pane down. rc starts UNSET so
# that being killed mid-login (the operator closing the pane) persists a failure (130), not a stale 0;
# the signal trap converts a SIGINT/TERM/HUP into a recorded rc so the driver's poll never hangs.
gate_runner() {
  local key="$1" rc=
  trap 'printf "%s" "${rc:-130}" > "$STATUS_DIR/$key.rc"; exit "${rc:-130}"' INT TERM HUP
  mkdir -p "$STATUS_DIR"
  case "$key" in
    codex)  if gate_codex_login;  then rc=0; else rc=$?; fi ;;
    gemini) if gate_gemini_login; then rc=0; else rc=$?; fi ;;
    *) err "unknown gate: $key"; rc=2 ;;
  esac
  printf '%s' "$rc" > "$STATUS_DIR/$key.rc"   # real result, available to the driver immediately
  if [ -n "${ZELLIJ:-}" ]; then
    echo
    if [ "$rc" -eq 0 ]; then ok "$key done."; else err "$key failed (rc=$rc)."; fi
    pause "press Enter to close this pane and return to the guide"
  fi
  exit "$rc"
}

# Run a non-interactive gate function, tracking pass/fail for the summary. $1 = fn, $2 = label.
# Records the label in FAILED EXACTLY ONCE, and only when the operator gives up — a gate that fails
# then passes on retry (or is retried several times) must not linger in the final summary.
declare -a FAILED=()
run_gate() {
  local fn="$1" label="$2"
  if "$fn"; then return 0; fi
  if confirm "$label did not complete — retry it now?"; then run_gate "$fn" "$label"
  else FAILED+=("$label"); fi
}

preflight() {
  local t missing=()
  for t in gum tailscale ssh curl python3 jq; do command -v "$t" >/dev/null || missing+=("$t"); done
  [ "${#missing[@]}" -eq 0 ] || { err "missing required tools: ${missing[*]}"; exit 1; }
  [ -f "$YCLAW_KEYCHAIN" ] || { err "no yclaw keychain at $YCLAW_KEYCHAIN — run \`just bootstrap\` first."; exit 1; }
  _yclaw_keychain_unlock
  security find-generic-password -a "$USER" -s "$KC_SERVICE_TS_OAUTH_ID" -w "$YCLAW_KEYCHAIN" >/dev/null 2>&1 \
    || warn "Tailscale OAuth client not in the keychain — bootstrap may be incomplete."
  _yclaw_keychain_lock
  local p
  for p in "$GOOGLE_OAUTH_PORT" "$GEMINI_CALLBACK_PORT"; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      warn "host port $p is already in use — a stale run may conflict (Gate C/D forward it)."
    fi
  done
  ok "preflight OK (tools, keychain, ports)."
}

driver() {
  hdr "yclaw · onboarding" \
      "Drives the human gates bootstrap stops at. Idempotent — already-done gates are skipped." \
      "You approve every consent/2FA in a browser or the VNC GUI; nothing sensitive crosses this script."
  preflight

  hdr "Gate 0 — Tailscale SSH access"
  clear_check root@metal       "metal"        || warn "metal not reachable — its gates will fail."
  clear_check admin@hermes     "hermes"       || warn "hermes not reachable — Gate A will fail."
  clear_check root@bluebubbles "bluebubbles"  || warn "bluebubbles not reachable — Gate E will fail."

  run_gate gate_a_hermes "Gate A (hermes identity)"

  hdr "Gate B — Codex login"
  if [ -n "$(cliproxy_auth_files 'codex-*.json')" ]; then ok "Codex already logged in — skipping."
  else run_interactive_gate codex "Gate B (Codex)" || FAILED+=("Gate B (Codex)"); fi

  hdr "Gate C — Gemini login"
  if gemini_logged_in; then ok "Gemini already logged in — skipping."
  else run_interactive_gate gemini "Gate C (Gemini)" || FAILED+=("Gate C (Gemini)"); fi

  run_gate gate_d_google_oauth "Gate D (Google OAuth)"
  run_gate gate_e_bluebubbles  "Gate E (BlueBubbles)"
  gate_final

  echo
  if [ "${#FAILED[@]}" -eq 0 ]; then
    hdr "Onboarding complete." "Every gate cleared. The stack is fully credentialed."
  else
    hdr "Onboarding finished with gates left to clear:" "$(printf '  • %s\n' "${FAILED[@]}")" \
        "Re-run \`just onboard\` any time — cleared gates are skipped."
  fi
}

# --- entrypoint -------------------------------------------------------------------------------
# Gate-runner subprocess (spawned into a pane, or run inline by run_interactive_gate).
if [ "${1:-}" = "__gate" ]; then
  gate_runner "${2:?gate key required}"
fi

usage() { sed -n '2,30p' "$SELF"; exit "${1:-0}"; }
case "${1:-}" in
  "") ;;                                   # bare run → the driver
  -h|--help|help) usage 0 ;;
  *) err "unknown argument: ${1}"; usage 1 ;;
esac

# Enter a multiplexer for the nice TUI unless already inside one (or opted out). zellij is preferred;
# tmux is the fallback. Inside the session $ZELLIJ / $TMUX is set, so we fall through to the driver.
if [ -z "${ZELLIJ:-}" ] && [ -z "${TMUX:-}" ] && [ -z "${YCLAW_ONBOARD_INNER:-}" ] \
   && [ -z "${YCLAW_ONBOARD_NO_ZELLIJ:-}" ]; then
  if command -v zellij >/dev/null; then
    mkdir -p "$STATUS_DIR"
    printf 'layout {\n    pane command="bash" {\n        args "-lc" "YCLAW_ONBOARD_INNER=1 exec %s"\n        cwd "%s"\n    }\n}\n' \
      "$SELF" "$REPO_ROOT" > "$LAYOUT_FILE"
    zellij kill-session "$SESSION" >/dev/null 2>&1 || true
    zellij delete-session "$SESSION" >/dev/null 2>&1 || true
    exec zellij --session "$SESSION" --new-session-with-layout "$LAYOUT_FILE"
  elif command -v tmux >/dev/null; then
    exec tmux new-session -A -s "$SESSION" "YCLAW_ONBOARD_INNER=1 exec '$SELF'"
  fi
fi

driver
