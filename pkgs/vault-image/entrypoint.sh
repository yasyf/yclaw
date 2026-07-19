#!/usr/bin/env bash
# PID-1 payload for the container-native vault node: render cliproxy config from sops, start
# tailscaled, supervise agent-vault/provision/cliproxy/relays. Ports of darwin/metal.nix.
set -euo pipefail

# Runtime bind-mount targets (overridable for a dry-run harness).
: "${VAULT_STATE_DIR:=/var/lib/vault}"
: "${TS_STATE_DIR:=/var/lib/tailscale}"
: "${TS_SOCKET:=/var/run/tailscale/tailscaled.sock}"

# Baked, non-secret store paths + manifest facts — set by image config.Env.
: "${CLIPROXY_CONFIG_TEMPLATE:?image config.Env must set CLIPROXY_CONFIG_TEMPLATE}"
: "${VAULT_SERVICES_YAML:?image config.Env must set VAULT_SERVICES_YAML}"
: "${TS_WG_PORT:?image config.Env must set TS_WG_PORT}"

# Runtime secrets arrive base64'd via --env-file (host-side sops decrypt, never a bind mount).
: "${VAULT_MASTER_PASSWORD_B64:?--env-file must set VAULT_MASTER_PASSWORD_B64}"
: "${VAULT_STATIC_KEYS_B64:?--env-file must set VAULT_STATIC_KEYS_B64}"
: "${CLIPROXY_API_KEY_B64:?--env-file must set CLIPROXY_API_KEY_B64}"
: "${TS_AUTHKEY_B64:?--env-file must set TS_AUTHKEY_B64}"

VAULT_UID=1000
VAULT_GID=1000
# Exported (with the two below) for the relay payloads, which re-resolve + re-drop per
# restart iteration under svc --root.
export PROXY_UID=1001
export PROXY_GID=1001
export VAULT_STATE_DIR TS_SOCKET
export AGENT_VAULT_HOME="$VAULT_STATE_DIR/agent-vault"
CLIPROXY_DIR="$VAULT_STATE_DIR/cliproxy"
LOG_DIR="$VAULT_STATE_DIR/logs"
export MASTER_PASSWORD_ENV=/run/vault-env/master-password.env
STATIC_KEYS_ENV=/run/vault-env/static-keys.env
ADDR=http://127.0.0.1:14321
# The registered owner email in the DB copied from metal — changing it breaks auth login.
OWNER=admin@metal.local

log()   { printf '[entrypoint] %s\n' "$*" >&2; }
fatal() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# svc <name> [--root|--proxy] -- cmd...: restart loop teeing to $LOG_DIR/<name>.log AND, name-
# prefixed, to PID-1 stdout (`container logs vault`); --proxy = proxy uid, no group 0 (ca8ac58f).
svc() {
  local name="$1"
  shift
  local -a run=(setpriv --reuid="$VAULT_UID" --regid="$VAULT_GID" --groups="$VAULT_GID",0 \
    --no-new-privs -- env "HOME=$VAULT_STATE_DIR")
  case "$1" in
    --root)
      run=()
      shift
      ;;
    --proxy)
      run=(setpriv --reuid="$PROXY_UID" --regid="$PROXY_GID" --clear-groups \
        --no-new-privs -- env "HOME=$VAULT_STATE_DIR")
      shift
      ;;
  esac
  [ "$1" = "--" ] || fatal "svc $name: expected -- before the command"
  shift
  (
    while true; do
      "${run[@]}" "$@" 2>&1 | tee -a "$LOG_DIR/$name.log" | sed -u -e "s/^/[$name] /" || true
      log "$name exited; restarting in 5s"
      sleep 5
    done
  ) &
  log "supervising $name"
}

# Base64 env secrets decode onto the image-local rootfs (guest DAC applies, unlike the bind
# mount): master-password readable by the dropped agent-vault, static-keys root-only.
decode_secret_envs() {
  install -d -m 710 /run/vault-env
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$VAULT_MASTER_PASSWORD_B64" | base64 -d > "$tmp"
  install -m 400 -o "$VAULT_UID" -g "$VAULT_GID" "$tmp" "$MASTER_PASSWORD_ENV"
  rm -f "$tmp"
  tmp="$(mktemp)"
  printf '%s' "$VAULT_STATIC_KEYS_B64" | base64 -d > "$tmp"
  install -m 400 "$tmp" "$STATIC_KEYS_ENV"
  rm -f "$tmp"
}

# Port of metal.nix's cliproxy wrapper: substitute the api key into the baked template at a
# runtime path (the real key never enters the Nix store).
render_cliproxy_config() {
  local key esc tmp
  key="$(printf '%s' "$CLIPROXY_API_KEY_B64" | base64 -d | tr -d '[:space:]')"
  [ -n "$key" ] || fatal "cliproxy/api-key is empty after trim"
  install -d "$CLIPROXY_DIR/auth"
  tmp="$(mktemp)"
  # The key lands inside a YAML double-quoted scalar (`"@@CLIPROXY_API_KEY@@"`), so escape backslash
  # then double-quote for YAML first — otherwise a key with " or \ renders invalid/injectable YAML.
  esc="$(printf '%s' "$key" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  # Then escape sed-replacement metachars (&, \, the | delimiter) so the substitution stays literal.
  esc="$(printf '%s' "$esc" | sed -e 's/[&|\\]/\\&/g')"
  sed -e "s|@@CLIPROXY_API_KEY@@|$esc|g" "$CLIPROXY_CONFIG_TEMPLATE" > "$tmp"
  install -m 600 "$tmp" "$CLIPROXY_DIR/config.yaml"
  rm -f "$tmp"
  log "rendered $CLIPROXY_DIR/config.yaml"
}

# Port of the hermes-image start_tailscale with the vault identity; --port is load-bearing —
# container-pf's WG carve-out is dest-port-keyed (unpinned = DERP fallback).
start_tailscale() {
  install -d -m 700 /var/run/tailscale
  install -d -m 700 "$TS_STATE_DIR"
  svc tailscaled --root -- tailscaled \
    --tun=tailscale0 \
    --port="$TS_WG_PORT" \
    --state="$TS_STATE_DIR/tailscaled.state" \
    --socket="$TS_SOCKET"

  local i
  for ((i = 0; i < 30; i++)); do
    [ -S "$TS_SOCKET" ] && break
    sleep 1
  done
  [ -S "$TS_SOCKET" ] || fatal "tailscaled socket $TS_SOCKET never appeared"

  # authkey via a private 0600 temp and file: (no argv leak); --timeout fails fast headless.
  local akf
  akf="$(mktemp)"
  trap "rm -f -- '$akf'" EXIT
  printf '%s' "$TS_AUTHKEY_B64" | base64 -d | tr -d '[:space:]' > "$akf"
  [ -s "$akf" ] || fatal "decrypted tailnet authkey is empty"
  tailscale --socket="$TS_SOCKET" up \
    --authkey="file:$akf" \
    --hostname=vault \
    --advertise-tags=tag:vault \
    --accept-dns=true \
    --timeout=60s \
    --ssh
  rm -f "$akf"
  trap - EXIT
  log "tailscale up complete"
}

# Port of metal.nix's agentVaultWrapper; the svc loop is the single-instance supervisor, so a
# pidfile at start is stale by definition (PID-existence liveness + PID reuse).
start_agent_vault() {
  install -d "$AGENT_VAULT_HOME"
  # Rate limits: instance-wide; hermes is the sole proxy consumer; LOCK pins them (metal M9).
  svc agent-vault -- bash -c '
    set -euo pipefail
    set -a; . "$MASTER_PASSWORD_ENV"; set +a
    export AGENT_VAULT_RATELIMIT_PROXY_RATE=15
    export AGENT_VAULT_RATELIMIT_PROXY_BURST=100
    export AGENT_VAULT_RATELIMIT_PROXY_CONCURRENCY=32
    export AGENT_VAULT_RATELIMIT_LOCK=true
    rm -f "$AGENT_VAULT_HOME/.agent-vault/agent-vault.pid"
    exec agent-vault server --host 0.0.0.0 --port 14321 --mitm-port 14322
  '
}

# Create-step wrapper: only the server's 409 "already exists" is benign — every other failure
# retries. stdout is discarded: `agent create` prints the minted token there (never log it).
create_ok() {
  local err
  err="$("$@" 2>&1 >/dev/null)" && return 0
  grep -qi 'already exists' <<< "$err" && return 0
  printf '%s\n' "$err" >&2
  return 1
}

# Port of metal.nix's agentVaultProvision. Explicit `|| return 1` per step: bash suppresses
# set -e inside an until condition, so each step must fail the attempt by hand.
provision_once() {
  curl -fs -o /dev/null "$ADDR/health" || return 1
  set -a
  . "$MASTER_PASSWORD_ENV"
  set +a
  local status
  status="$(curl -fsS "$ADDR/v1/status")" || return 1
  if grep -q '"needs_first_user":true' <<< "$status"; then
    printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
      | agent-vault auth register --address "$ADDR" --email "$OWNER" --password-stdin || return 1
  elif [ ! -s "$AGENT_VAULT_HOME/.agent-vault/session.json" ]; then
    printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
      | agent-vault auth login --address "$ADDR" --email "$OWNER" --password-stdin || return 1
  fi
  create_ok agent-vault vault create hermes || return 1
  agent-vault vault service set --vault hermes --file "$VAULT_SERVICES_YAML" || return 1
  # Word-splitting intended: static-keys is VAR=value lines fed as separate args (metal.nix).
  # shellcheck disable=SC2046
  agent-vault vault credential set --vault hermes $(cat "$STATIC_KEYS_ENV") || return 1
  # Bootstrap `agent rotate`s this injection-only agent, so create-vs-exists both suffice.
  create_ok agent-vault agent create hermes --vault hermes:proxy || return 1
  # Post-condition: a misread conflict above must not declare success without the agent.
  agent-vault agent info hermes > /dev/null || return 1
}

# Blocks main so the credential-set argv window closes first; the SUBSHELL contains provision_once's
# `set -a` master-password export (else it leaks into PID 1, inherited by the uid-1001 svcs).
provision_blocking() {
  (
    until provision_once >> "$LOG_DIR/provision.log" 2>&1; do
      sleep 10
    done
    log "provision complete"
  )
}

# Port of metal.nix's relay wrappers: bind THIS node's tailnet IPv4, forward to yasyf-home.
# IPs re-resolve per iteration (a host re-registration strands a baked one), then drop.
start_relays() {
  local port
  for port in 8000 8765; do
    svc "relay-$port" --root -- bash -c '
      set -euo pipefail
      port="$1"
      tsip="$(tailscale --socket="$TS_SOCKET" ip -4)"
      hostip="$(tailscale --socket="$TS_SOCKET" ip -4 yasyf-home)"
      exec setpriv --reuid="$PROXY_UID" --regid="$PROXY_GID" --clear-groups \
        --no-new-privs -- env "HOME=$VAULT_STATE_DIR" socat -t 600 \
        "TCP-LISTEN:$port,bind=$tsip,fork,max-children=64,reuseaddr,nodelay" \
        "TCP:$hostip:$port,nodelay,connect-timeout=10"
    ' relay "$port"
  done
}

main() {
  install -d "$LOG_DIR"
  # No chown of bind-mounted state: impossible on the mount root and unnecessary — uid 1000
  # already has host-enforced access (cc-notes ca8ac58f).
  decode_secret_envs
  render_cliproxy_config
  start_tailscale
  # Secrets are now on the overlay or consumed; scrub the env before any service so they never
  # reach a uid-1001 proxy's environ.
  unset VAULT_MASTER_PASSWORD_B64 VAULT_STATIC_KEYS_B64 CLIPROXY_API_KEY_B64 TS_AUTHKEY_B64
  start_agent_vault
  # #2-A: static keys hit root's argv here — finish before any uid-1001 svc so /proc/cmdline is
  # never cross-uid readable.
  provision_blocking
  svc cliproxy --proxy -- cli-proxy-api --config "$CLIPROXY_DIR/config.yaml"
  start_relays
  log "all services supervised"
  wait
}

main "$@"
