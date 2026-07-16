#!/usr/bin/env bash
# PID-1 payload for container-native hermes-agent: root under tini reads mounted secrets and
# starts tailscaled, then drops to the hermes user for the agent (replaces sops-nix activation).
set -euo pipefail

# Runtime bind-mount targets (overridable for the dry-run harness).
: "${HERMES_STATE_DIR:=/var/lib/hermes}"
: "${HERMES_HOME:=${HERMES_STATE_DIR}/.hermes}"
: "${AGE_KEY_FILE:=/run/secrets/age-key}"
: "${SOPS_BUNDLE:=/run/secrets/secrets.sops.yaml}"
: "${NODE_ENV_FILE:=/run/config/node.env}"
: "${AGENT_VAULT_TOKEN_FILE:=/run/secrets/agent-vault-token}"
: "${TS_AUTHKEY_FILE:=/run/secrets/ts-authkey}"
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"

# Baked, non-secret store paths — set by image config.Env, derived from the VM's config.
: "${HERMES_STATIC_ENV:?image config.Env must set HERMES_STATIC_ENV}"
: "${HERMES_CONFIG_JSON:?image config.Env must set HERMES_CONFIG_JSON}"

HERMES_UID=1000
HERMES_GID=1000

log()   { printf '[entrypoint] %s\n' "$*" >&2; }
fatal() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# hermes.env is a literal block of dotenv lines (BLUEBUBBLES_PASSWORD + CLIPROXY_API_KEY).
decrypt_hermes_env() {
  [ -s "$AGE_KEY_FILE" ] || fatal "no age key at $AGE_KEY_FILE"
  [ -s "$SOPS_BUNDLE" ]  || fatal "no sops bundle at $SOPS_BUNDLE"
  local out
  out="$(SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt --config /dev/null \
    --input-type yaml --output-type yaml --extract '["hermes"]["env"]' "$SOPS_BUNDLE")" \
    || fatal "sops could not decrypt hermes/env from $SOPS_BUNDLE"
  [ -n "$out" ] || fatal "decrypted hermes/env is empty"
  printf '%s\n' "$out"
}

# Byte-identical to renderHermesProxyEnv; :hermes@ is a fixed vault hint, not a variable.
render_proxy_env() {
  [ -s "$AGENT_VAULT_TOKEN_FILE" ] || fatal "no agent-vault token at $AGENT_VAULT_TOKEN_FILE"
  local tok
  tok="$(cat "$AGENT_VAULT_TOKEN_FILE")"
  [ -n "$tok" ] || fatal "empty agent-vault token"
  printf 'HTTPS_PROXY=http://%s:hermes@metal:14322\nHTTP_PROXY=http://%s:hermes@metal:14322\n' \
    "$tok" "$tok"
}

# Layer order mirrors nixos/hermes.nix environmentFiles; python-dotenv keeps the last dup.
assemble_env() {
  [ -s "$HERMES_STATIC_ENV" ] || fatal "no static env at $HERMES_STATIC_ENV"
  [ -s "$NODE_ENV_FILE" ]     || fatal "no node.env at $NODE_ENV_FILE"
  local dst="$HERMES_HOME/.env" tmp
  tmp="$(mktemp)"
  trap "rm -f -- '$tmp'" EXIT
  {
    cat "$HERMES_STATIC_ENV"; printf '\n'
    cat "$NODE_ENV_FILE";     printf '\n'
    decrypt_hermes_env
    render_proxy_env
  } > "$tmp"
  install -m 600 -o "$HERMES_UID" -g "$HERMES_GID" "$tmp" "$dst"
  rm -f "$tmp"
  trap - EXIT
  log "assembled $dst"
}

# Deep-merge onto any existing config.yaml (nix keys win, user keys survive), as upstream does.
render_config() {
  local dst="$HERMES_HOME/config.yaml"
  python3 - "$HERMES_CONFIG_JSON" "$dst" <<'PY'
import json, os, sys
import yaml

incoming = json.load(open(sys.argv[1]))
dst = sys.argv[2]
existing = {}
if os.path.exists(dst):
    with open(dst) as f:
        existing = yaml.safe_load(f) or {}

def deep_merge(base, incoming):
    for k, v in incoming.items():
        if isinstance(base.get(k), dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base

with open(dst, "w") as f:
    yaml.safe_dump(deep_merge(existing, incoming), f, sort_keys=False, default_flow_style=False)
PY
  chown "$HERMES_UID:$HERMES_GID" "$dst"
  chmod 600 "$dst"
  log "rendered $dst"
}

# tailscaled restart loop on a real tun (run adds --cap-add NET_ADMIN); the container needs its
# OWN peer identity so the inbound BlueBubbles->hermes webhook (hermes.<tailnet>:8645) resolves.
start_tailscale() {
  install -d -m 700 /var/run/tailscale
  install -d -m 700 "$TS_STATE_DIR"
  (
    while true; do
      tailscaled \
        --tun=tailscale0 \
        --state="$TS_STATE_DIR/tailscaled.state" \
        --socket="$TS_SOCKET" || true
      log "tailscaled exited; restarting in 5s"
      sleep 5
    done
  ) &

  local i
  for ((i = 0; i < 30; i++)); do
    [ -S "$TS_SOCKET" ] && break
    sleep 1
  done
  [ -S "$TS_SOCKET" ] || fatal "tailscaled socket $TS_SOCKET never appeared"

  [ -s "$TS_AUTHKEY_FILE" ] || fatal "no tailnet authkey at $TS_AUTHKEY_FILE"
  # --authkey=file: keeps the key out of argv (/proc/<pid>/cmdline); tailscale trims whitespace.
  tailscale --socket="$TS_SOCKET" up \
    --authkey="file:$TS_AUTHKEY_FILE" \
    --hostname=hermes \
    --advertise-tags=tag:hermes \
    --accept-dns=true \
    --ssh
  log "tailscale up complete"
}

main() {
  install -d -m 750 "$HERMES_HOME"
  render_config
  assemble_env
  # Bind-mounted state may arrive host-owned; give the agent user its home tree.
  chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_STATE_DIR"
  start_tailscale
  log "exec hermes gateway run (uid=$HERMES_UID)"
  exec setpriv --reuid="$HERMES_UID" --regid="$HERMES_GID" --groups="$HERMES_GID" \
    --no-new-privs -- hermes gateway run
}

main "$@"
