#!/bin/bash
# One tick of the container-hermes chain (apiserver -> socktainer -> proxy -> agent container),
# re-run by the com.yclaw.container-hermes LaunchAgent. Rationale + baking: cc-notes 8639b85.
set -u
export PATH=/opt/homebrew/bin:/usr/sbin:/sbin:/usr/bin:/bin

CONTAINER=@@CONTAINER@@
SOCKTAINER=@@SOCKTAINER@@
SOCKTAINER_SOCK=@@SOCKTAINER_SOCK@@
PROXY_BIN=@@PROXY_BIN@@
STATE_DIR=@@STATE_DIR@@
RUN_DIR=@@RUN_DIR@@
CONFIG_DIR=@@CONFIG_DIR@@
CONFIG_TOML=@@CONFIG_TOML@@
LOG_DIR=@@LOG_DIR@@
YCLAW_LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/wait.sh
. "$YCLAW_LIB/wait.sh"

PROXY_SOCK="$RUN_DIR/docker.sock"
IMAGE=hermes-agent:latest
NAME=hermes
AGENT_GID=1000

# Last-ok epoch for a doctor staleness check; under the user-writable log dir (the lib dir is
# root-owned and this tick runs as the login user).
MARKER="$LOG_DIR/container-hermes.last-ok"

apiserver_running() { [ "$("$CONTAINER" system status 2>/dev/null | awk '$1=="status"{print $2}')" = "running" ]; }
container_running() { "$CONTAINER" list --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }
container_exists()  { "$CONTAINER" list --all --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }

# 1. apiserver. config.toml (192.168.72/24 override) is load-bearing for the first start; assert it
# only then, and die rather than collide with the fleet 192.168.64/24.
if ! apiserver_running; then
  [ -f "$CONFIG_TOML" ] || { echo "container-hermes: FATAL $CONFIG_TOML absent — refusing 'container system start' (subnet would collide with the fleet 192.168.64/24)" >&2; exit 1; }
  echo "container-hermes: apiserver down — container system start"
  "$CONTAINER" system start >>"$LOG_DIR/container-system.log" 2>&1 \
    || { echo "container-hermes: FATAL 'container system start' failed (see $LOG_DIR/container-system.log)" >&2; exit 1; }
  wait_for "container apiserver to report running" 30 2 apiserver_running \
    || { echo "container-hermes: FATAL apiserver did not report running after start" >&2; exit 1; }
fi

# 2. socktainer (after the apiserver, which it version-checks). Relaunch if gone; wait for its
# socket. The 0666 raw socket is NEVER mounted into the agent.
if ! pgrep -qf "$SOCKTAINER"; then
  echo "container-hermes: socktainer down — relaunching"
  nohup "$SOCKTAINER" >>"$LOG_DIR/socktainer.log" 2>&1 &
fi
wait_path_exists "$SOCKTAINER_SOCK" 30 \
  || { echo "container-hermes: FATAL socktainer socket $SOCKTAINER_SOCK never appeared" >&2; exit 1; }

# 3. hermes-docker-proxy (da1c63 screen). Relaunch if gone. The 0660 socket inherits RUN_DIR's group
# (gid 1000, BSD dir-group semantics) — verify it on a fresh launch, die on drift.
if ! pgrep -qf "$PROXY_BIN"; then
  echo "container-hermes: hermes-docker-proxy down — relaunching"
  HERMES_DOCKER_PROXY_LISTEN="$PROXY_SOCK" \
  HERMES_DOCKER_PROXY_UPSTREAM="$SOCKTAINER_SOCK" \
  HERMES_DOCKER_PROXY_BIND_ROOTS="$STATE_DIR/hermes" \
    nohup "$PROXY_BIN" >>"$LOG_DIR/hermes-docker-proxy.log" 2>&1 &
  wait_path_exists "$PROXY_SOCK" 30 \
    || { echo "container-hermes: FATAL proxy socket $PROXY_SOCK never appeared" >&2; exit 1; }
  sock_gid="$(stat -f %g "$PROXY_SOCK")"
  [ "$sock_gid" = "$AGENT_GID" ] \
    || { echo "container-hermes: FATAL proxy socket $PROXY_SOCK is gid $sock_gid, not $AGENT_GID — RUN_DIR group misconfigured, agent cannot connect (re-run 'setup.sh host-container')" >&2; exit 1; }
fi

# 4. agent container. Running -> done; stopped -> rm + run fresh; absent -> run. DEFAULT NAT net
# (pf/2e narrows egress).
if ! container_running "$NAME"; then
  if container_exists "$NAME"; then
    echo "container-hermes: agent container '$NAME' exists but is not running — removing stale instance"
    "$CONTAINER" rm -f "$NAME" >/dev/null 2>&1 \
      || { echo "container-hermes: FATAL could not remove stale container '$NAME'" >&2; exit 1; }
  fi
  echo "container-hermes: starting agent container '$NAME' from $IMAGE"
  "$CONTAINER" run -d --name "$NAME" --cap-add NET_ADMIN \
    -v "$STATE_DIR/hermes:/var/lib/hermes" \
    -v "$STATE_DIR/hermes-ts-state:/var/lib/tailscale" \
    -v "$CONFIG_DIR/key.txt:/run/secrets/age-key:ro" \
    -v "$CONFIG_DIR/secrets.sops.yaml:/run/secrets/secrets.sops.yaml:ro" \
    -v "$CONFIG_DIR/node.env:/run/config/node.env:ro" \
    -v "$CONFIG_DIR/agent-vault-token:/run/secrets/agent-vault-token:ro" \
    -v "$PROXY_SOCK:/run/hermes-docker-proxy/docker.sock" \
    "$IMAGE" >>"$LOG_DIR/container-run.log" 2>&1 \
    || { echo "container-hermes: FATAL 'container run' failed (see $LOG_DIR/container-run.log)" >&2; exit 1; }
  wait_for "agent container '$NAME' to reach running" 30 2 container_running "$NAME" \
    || { echo "container-hermes: FATAL container '$NAME' did not reach running (see $LOG_DIR/container-run.log)" >&2; exit 1; }
fi

date +%s > "$MARKER" || { echo "container-hermes: FATAL cannot write enforcement marker $MARKER" >&2; exit 1; }

echo "container-hermes: chain up — apiserver running, socktainer live, proxy socket $PROXY_SOCK (gid $AGENT_GID), container '$NAME' running"
