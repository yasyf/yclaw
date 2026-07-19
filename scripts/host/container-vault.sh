#!/bin/bash
# One tick of the container-vault lifecycle, re-run by its LaunchAgent.
set -u
export PATH=/opt/homebrew/bin:/usr/sbin:/sbin:/usr/bin:/bin

CONTAINER=@@CONTAINER@@
STATE_DIR=@@STATE_DIR@@
CONFIG_DIR=@@CONFIG_DIR@@
CONFIG_TOML=@@CONFIG_TOML@@
LOG_DIR=@@LOG_DIR@@
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$YCLAW_LIB/wait.sh"

IMAGE=vault:latest
NAME=vault
MARKER="$LOG_DIR/container-vault.last-ok"
AGE_KEY="$CONFIG_DIR/key.txt"
SOPS_BUNDLE="$CONFIG_DIR/secrets.sops.yaml"

apiserver_running() { [ "$("$CONTAINER" system status 2>/dev/null | awk '$1=="status"{print $2}')" = "running" ]; }
container_running() { "$CONTAINER" list --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }
container_exists()  { "$CONTAINER" list --all --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }
vault_healthy() { "$CONTAINER" exec "$NAME" curl -fsS http://127.0.0.1:14321/health >/dev/null; }
mint_hermes_token() { "$CONTAINER" exec "$NAME" /mint-hermes-token.sh; }

# Extract one path from the vault sops bundle with the host's age key (idiom: secrets.sh).
decrypt_secret() {
  SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt --config /dev/null --input-type yaml \
    --output-type yaml --extract "$1" "$SOPS_BUNDLE"
}

# Decrypt host-side into a base64 KEY=VALUE env-file — the age key + bundle never enter the container
# (bind-mount reads are uid-agnostic); --env-file lands secrets in PID 1's root-only environ.
build_secret_envfile() {
  local out="$1" name path raw
  [ -s "$AGE_KEY" ]     || { echo "container-vault: FATAL age key $AGE_KEY missing" >&2; return 1; }
  [ -s "$SOPS_BUNDLE" ] || { echo "container-vault: FATAL sops bundle $SOPS_BUNDLE missing" >&2; return 1; }
  for spec in \
    'VAULT_MASTER_PASSWORD_B64=["vault"]["master-password"]' \
    'VAULT_STATIC_KEYS_B64=["vault"]["static-keys"]' \
    'CLIPROXY_API_KEY_B64=["cliproxy"]["api-key"]' \
    'TS_AUTHKEY_B64=["tailscale"]["authkey"]'; do
    name="${spec%%=*}"
    path="${spec#*=}"
    raw="$(decrypt_secret "$path")" \
      || { echo "container-vault: FATAL sops could not decrypt $path" >&2; return 1; }
    [ -n "$raw" ] || { echo "container-vault: FATAL decrypted $path is empty" >&2; return 1; }
    printf '%s=%s\n' "$name" "$(printf '%s' "$raw" | base64 | tr -d '\n')" >> "$out"
  done
}

case "${1:-tick}" in
  tick) ;;
  mint-hermes-token) mint_hermes_token; exit ;;
  *) echo "usage: container-vault.sh [tick|mint-hermes-token]" >&2; exit 2 ;;
esac

# config.toml must precede the first start; an unclean stop can leave a stale bridge, so the
# shared pf tick refuses anything except the single expected live bridge.
if ! apiserver_running; then
  [ -f "$CONFIG_TOML" ] || { echo "container-vault: FATAL $CONFIG_TOML absent — refusing 'container system start'" >&2; exit 1; }
  echo "container-vault: apiserver down — container system start"
  "$CONTAINER" system start >>"$LOG_DIR/container-system.log" 2>&1 \
    || { echo "container-vault: FATAL 'container system start' failed (see $LOG_DIR/container-system.log)" >&2; exit 1; }
  wait_for "container apiserver to report running" 30 2 apiserver_running \
    || { echo "container-vault: FATAL apiserver did not report running after start" >&2; exit 1; }
fi

if ! container_running "$NAME"; then
  if container_exists "$NAME"; then
    echo "container-vault: container '$NAME' exists but is not running — removing stale instance"
    "$CONTAINER" rm -f "$NAME" >/dev/null 2>&1 \
      || { echo "container-vault: FATAL could not remove stale container '$NAME'" >&2; exit 1; }
  fi
  echo "container-vault: starting container '$NAME' from $IMAGE"
  envfile="$(mktemp)" || { echo "container-vault: FATAL mktemp failed for the secret env-file" >&2; exit 1; }
  chmod 600 "$envfile"
  build_secret_envfile "$envfile" || { rm -f "$envfile"; exit 1; }
  "$CONTAINER" run -d --name "$NAME" --cap-add NET_ADMIN \
    -v "$STATE_DIR/vault:/var/lib/vault" \
    -v "$STATE_DIR/vault-ts-state:/var/lib/tailscale" \
    --env-file "$envfile" \
    "$IMAGE" >>"$LOG_DIR/container-vault-run.log" 2>&1
  run_rc=$?
  # run materialized --env-file into the container's environ; drop the host plaintext immediately.
  rm -f "$envfile"
  [ "$run_rc" -eq 0 ] || { echo "container-vault: FATAL 'container run' failed (see $LOG_DIR/container-vault-run.log)" >&2; exit 1; }
  wait_for "vault container '$NAME' to reach running" 30 2 container_running "$NAME" \
    || { echo "container-vault: FATAL container '$NAME' did not reach running" >&2; exit 1; }
fi

wait_for "vault health probe" 60 2 vault_healthy \
  || { echo "container-vault: FATAL health probe failed" >&2; exit 1; }
date +%s > "$MARKER" || { echo "container-vault: FATAL cannot write health marker $MARKER" >&2; exit 1; }
echo "container-vault: apiserver running, container '$NAME' healthy"
