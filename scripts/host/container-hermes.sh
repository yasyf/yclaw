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
AGENT_UID=1000
AGENT_GID=1000

# Last-ok epoch for a doctor staleness check; under the user-writable log dir (the lib dir is
# root-owned and this tick runs as the login user).
MARKER="$LOG_DIR/container-hermes.last-ok"

apiserver_running() { [ "$("$CONTAINER" system status 2>/dev/null | awk '$1=="status"{print $2}')" = "running" ]; }
container_running() { "$CONTAINER" list --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }
container_exists()  { "$CONTAINER" list --all --format json 2>/dev/null | grep -q "\"id\":\"$1\""; }

# pgrep -f matches a regex anywhere in any command line, so a process carrying the binary path in its
# argv would false-match and skip a needed relaunch. Anchor at argv start (nohup exec's the bare
# path) with metachars escaped.
proc_running() {
  local esc; esc="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/\\&/g')"
  # Trailing boundary (space or end): without it `^/path/bin` also matches `/path/bin-helper`, so a
  # differently-named process could satisfy the check while the real binary is down. ERE (macOS pgrep).
  pgrep -qf "^$esc( |\$)"
}

# Validate the proxy socket EVERY tick before mounting it: a symlink swap (-> raw socktainer) or a
# chmod failure (0755 blocks the gid-1000 connect) can happen while the process stays up. This is the
# HOST side; guest-side connectivity is proven by proxy_canary.
assert_proxy_socket() {
  [ ! -L "$PROXY_SOCK" ] || { echo "container-hermes: FATAL $PROXY_SOCK is a symlink — refusing (raw-socktainer redirect?)" >&2; exit 1; }
  [ -S "$PROXY_SOCK" ]   || { echo "container-hermes: FATAL $PROXY_SOCK is not a socket" >&2; exit 1; }
  local gid owner mode
  gid="$(stat -f %g "$PROXY_SOCK")"; owner="$(stat -f %u "$PROXY_SOCK")"; mode="$(stat -f %Lp "$PROXY_SOCK")"
  [ "$gid" = "$AGENT_GID" ] || { echo "container-hermes: FATAL proxy socket gid $gid != $AGENT_GID (re-run 'setup.sh host-container')" >&2; exit 1; }
  [ "$owner" = "$(id -u)" ] || { echo "container-hermes: FATAL proxy socket owner $owner != $(id -u)" >&2; exit 1; }
  [ "$mode" = "660" ]       || { echo "container-hermes: FATAL proxy socket mode $mode != 660 (chmod failed — agent cannot connect)" >&2; exit 1; }
}

# In-container canary: from inside the agent AS the dropped uid:gid 1000, send a create the proxy MUST
# reject and require its 403. Proves the mounted socket is the FILTERING proxy (raw socktainer 404s
# the bogus image) AND that uid 1000 can connect at all (guest-side gid, sup #2). The proxy 403s any
# forbidden create OR unlisted route pre-forward, so the bogus image never reaches a daemon. Exit:
# 0=403 ok, 2=could not connect, 3=answered but not 403 (WRONG socket), other=exec/probe error.
proxy_canary() {
  "$CONTAINER" exec --user "$AGENT_UID:$AGENT_GID" "$NAME" python3 -c '
import http.client, socket, sys
class U(http.client.HTTPConnection):
    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect("/run/hermes-docker-proxy/docker.sock"); self.sock = s
c = U("localhost")
try:
    c.request("POST", "/v1.43/containers/create",
              b"{\"Image\":\"x\",\"HostConfig\":{\"Privileged\":true}}",
              {"Content-Type": "application/json"})
    code = c.getresponse().status
except Exception:
    sys.exit(2)
sys.exit(0 if code == 403 else 3)
' 2>>"$LOG_DIR/container-canary.log" &
  # macOS bash 3.2 has no `timeout`: a hung `container exec` (wedged guest channel) would stall the
  # whole KeepAlive loop forever (body never returns), so bound it with a background kill -> WARN.
  local pid=$! killer rc
  # TERM then, after a grace, KILL: a `container exec` wedged on a hung guest channel may ignore
  # SIGTERM, so escalate to SIGKILL to guarantee `wait` unblocks.
  ( sleep 20; kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null ) & killer=$!
  wait "$pid"; rc=$?
  kill "$killer" 2>/dev/null
  return "$rc"
}

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
if ! proc_running "$SOCKTAINER"; then
  echo "container-hermes: socktainer down — relaunching"
  # socktainer does not clear its stale socket on start (our proxy does, main.go:105); leaving it
  # would EADDRINUSE the bind and false-positive wait_path_exists below.
  rm -f "$SOCKTAINER_SOCK"
  nohup "$SOCKTAINER" >>"$LOG_DIR/socktainer.log" 2>&1 &
fi
wait_path_exists "$SOCKTAINER_SOCK" 30 \
  || { echo "container-hermes: FATAL socktainer socket $SOCKTAINER_SOCK never appeared" >&2; exit 1; }

# 3. hermes-docker-proxy (da1c63 screen). Relaunch if gone, then assert the socket EVERY tick (a
# symlink swap or chmod failure can happen while the process stays up) — not only on a fresh launch.
if ! proc_running "$PROXY_BIN"; then
  echo "container-hermes: hermes-docker-proxy down — relaunching"
  HERMES_DOCKER_PROXY_LISTEN="$PROXY_SOCK" \
  HERMES_DOCKER_PROXY_UPSTREAM="$SOCKTAINER_SOCK" \
  HERMES_DOCKER_PROXY_BIND_ROOTS="$STATE_DIR/hermes" \
    nohup "$PROXY_BIN" >>"$LOG_DIR/hermes-docker-proxy.log" 2>&1 &
  wait_path_exists "$PROXY_SOCK" 30 \
    || { echo "container-hermes: FATAL proxy socket $PROXY_SOCK never appeared" >&2; exit 1; }
fi
assert_proxy_socket

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

# Prove the running agent reaches the FILTERING proxy (sup #3/#4) and can connect as uid 1000 (sup
# #2). FATAL only on a definitive wrong-socket answer; a probe that cannot complete WARNs (exec
# mechanics are validated live at bring-up) so a mechanics detail does not brick the chain.
proxy_canary; crc=$?
if [ "$crc" -eq 3 ]; then
  # Definitive wrong-socket answer = the agent has raw (non-filtering) docker access. DETECT alone
  # leaves it running (next tick sees it "running" and skips step 4), so REVOKE by force-removing —
  # next tick recreates clean, or assert_proxy_socket refuses on a bad host socket first.
  echo "container-hermes: FATAL proxy canary got a non-403 answer — mounted socket is NOT the filtering proxy; force-removing '$NAME' to revoke raw docker access" >&2
  "$CONTAINER" rm -f "$NAME" >/dev/null 2>&1 || echo "container-hermes: FATAL could not force-remove compromised container '$NAME'" >&2
  exit 1
elif [ "$crc" -ne 0 ]; then
  echo "container-hermes: WARN proxy canary did not complete (rc=$crc; 2=agent could not connect [guest-side gid — sup #2?], other=exec/probe error) — see $LOG_DIR/container-canary.log" >&2
fi

# last-ok = the canary definitively passed (crc==0), not merely "chain up" — a WARN tick leaves it
# stale for a doctor staleness check (#25 wires the reader).
if [ "$crc" -eq 0 ]; then
  date +%s > "$MARKER" || { echo "container-hermes: FATAL cannot write enforcement marker $MARKER" >&2; exit 1; }
fi

echo "container-hermes: chain up — apiserver running, socktainer live, proxy socket $PROXY_SOCK (gid $AGENT_GID), container '$NAME' running"
