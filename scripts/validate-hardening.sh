#!/usr/bin/env bash
# validate-hardening.sh — run ON THE HOST after `just bootstrap`, with the VMs up. Exercises the
# June-2026 per-VM isolation + audit-remediation controls and reports PASS/FAIL per check. It fans
# each check to the right vantage point over `tailscale ssh` (root@metal, admin@hermes). Two checks
# need a vantage the host cannot occupy (a THIRD tailnet node, and a cross-VM decrypt on metal); the
# script prints those as MANUAL steps. Exits non-zero if any hard check fails.
#
# This is a read-only probe: it never changes VM state. It does briefly decrypt hermes's own bundle
# in host memory (the host can already do that) and never writes plaintext to disk.
set -uo pipefail

PORTS=(8000 8765 8317 14321 14322)
metal_ssh=(tailscale ssh root@metal --)
hermes_ssh=(tailscale ssh admin@hermes --)
HERMES_STATE="$HOME/.yclaw/state/hosts/hermes"
DOCKER_PROXY_SOCK="unix:///run/hermes-docker-proxy/docker.sock"

PASS=0; FAIL=0; MANUAL=0

# --- helpers -----------------------------------------------------------------

hdr()    { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m✓ PASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
no()     { printf '  \033[1;31m✗ FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn()   { printf '  \033[1;33m! WARN\033[0m %s\n' "$*"; }
manual() { printf '  \033[1;36m→ MANUAL\033[0m %s\n' "$*"; MANUAL=$((MANUAL + 1)); }
need()   { command -v "$1" >/dev/null 2>&1 || { printf 'FATAL: required tool %s not on PATH\n' "$1" >&2; exit 1; }; }

need tailscale; need sops; need jq; need nc

# --- 1. pf hermes+host gate --------------------------------------------------

hdr "1. pf hermes+host gate — metal's service ports reach only hermes + this host"
for p in "${PORTS[@]}"; do
  if nc -z -w 5 metal "$p" 2>/dev/null; then ok "host → metal:$p reachable (host is allow-listed)"
  else no "host → metal:$p NOT reachable (the host should be allow-listed in the pf anchor)"; fi
done
rules="$("${metal_ssh[@]}" pfctl -a metal -sr 2>/dev/null || true)"
if grep -q 'block ' <<<"$rules"; then ok "metal pf anchor carries the catch-all block rule"
else no "metal pf anchor is missing the catch-all block rule"; fi
if grep -q '100.64.0.0/10' <<<"$rules"; then no "metal pf anchor admits the WHOLE tailnet (100.64.0.0/10) — must be hermes + host only"
else ok "metal pf anchor does not admit the whole tailnet CGNAT"; fi
hermes_ip="$(tailscale ip -4 hermes 2>/dev/null | head -1 || true)"
if [[ -n "$hermes_ip" ]] && grep -q "$hermes_ip" <<<"$rules"; then ok "metal pf anchor passes hermes ($hermes_ip)"
else warn "could not confirm hermes's IP in the pf anchor (resolved: ${hermes_ip:-none})"; fi
manual "From a tailnet node that is NEITHER hermes NOR this host: \`nc -vz metal 8000\` (also 8765/8317/14321/14322) must ALL be refused/time out."

# --- 2. H6 docker socket proxy -----------------------------------------------

hdr "2. H6 docker socket proxy — agent code-exec is filtered, hermes is not docker-root"
run_as_hermes_docker=("${hermes_ssh[@]}" sudo -u hermes -H env "DOCKER_HOST=$DOCKER_PROXY_SOCK" docker)
for spec in "-v /:/host|host-root bind" "--privileged|privileged" "--runtime=runc|runc runtime"; do
  flag="${spec%%|*}"; desc="${spec##*|}"
  if "${run_as_hermes_docker[@]}" run --rm $flag alpine true >/dev/null 2>&1; then
    no "docker run $flag was NOT refused ($desc)"
  else ok "docker run $flag refused ($desc)"; fi
done
if "${run_as_hermes_docker[@]}" run --rm alpine true >/dev/null 2>&1; then ok "benign docker run (no host bind) succeeds through the proxy"
else warn "benign docker run failed — proxy too strict, daemon down, or alpine not pullable"; fi
dockergrp="$("${hermes_ssh[@]}" getent group docker 2>/dev/null || true)"
if printf '%s' "${dockergrp##*:}" | tr ',' '\n' | grep -qx hermes; then no "hermes IS a docker-group member (must not be)"
else ok "hermes is not a docker-group member (members: ${dockergrp##*:})"; fi
manual "Confirm the DENY trail: \`tailscale ssh admin@hermes -- journalctl -u hermes-docker-proxy --no-pager | grep DENY\` shows the three refusals above."

# --- 3. M2 omlx/STT tailnet bind ---------------------------------------------

hdr "3. M2 omlx/STT bound to the tailnet IP, not loopback/vmnet"
if "${hermes_ssh[@]}" curl -sf --max-time 8 http://metal:8000/v1/models >/dev/null 2>&1; then ok "hermes → metal:8000 (omlx) answers"
else no "hermes → metal:8000 (omlx) did not answer"; fi
metal_tsip="$("${metal_ssh[@]}" tailscale ip -4 2>/dev/null | head -1 || true)"
listen="$("${metal_ssh[@]}" lsof -nP -iTCP:8000 -iTCP:8765 -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$metal_tsip" ]] && grep -q "$metal_tsip:" <<<"$listen"; then ok "omlx/STT listen on metal's tailnet IP ($metal_tsip)"
else no "omlx/STT not confirmed on the tailnet IP (metal_tsip=${metal_tsip:-none})"; fi
if grep -qE '\*:(8000|8765)|127\.0\.0\.1:(8000|8765)' <<<"$listen"; then no "omlx/STT also listen on wildcard/loopback"
else ok "omlx/STT do not listen on wildcard/loopback"; fi

# --- 4. Per-VM crypto isolation ----------------------------------------------

hdr "4. Per-VM crypto isolation — hermes's bundle decrypts ONLY with hermes's key"
out="$(SOPS_AGE_KEY_FILE="$HERMES_STATE/key.txt" sops -d "$HERMES_STATE/secrets.sops.yaml" 2>/dev/null || true)"
if [[ -n "$out" ]] && grep -q 'authkey' <<<"$out" && grep -q 'env' <<<"$out"; then ok "hermes key decrypts hermes bundle (tailscale/authkey + hermes/env only)"
else no "hermes key could not decrypt its bundle (check $HERMES_STATE)"; fi
unset out
if [[ -e /var/lib/sops-nix/key.txt ]]; then no "host holds /var/lib/sops-nix/key.txt — it must keep no age key"
else ok "host holds no /var/lib/sops-nix/key.txt"; fi
manual "Cross-VM negative: copy $HERMES_STATE/secrets.sops.yaml onto metal, then \`SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d secrets.sops.yaml\` must FAIL (metal's key cannot decrypt hermes's bundle)."

# --- 5. metal share boundary -------------------------------------------------

hdr "5. metal share boundary — only the narrow per-need shares"
shares="$("${metal_ssh[@]}" ls "/Volumes/My Shared Files/" 2>/dev/null || true)"
for s in metalsecrets agentvault hfhub mlxaudio cliproxy repo; do
  if grep -qx "$s" <<<"$shares"; then ok "share present: $s"; else no "expected share missing: $s"; fi
done
if grep -qiE '^(hosts|hermes|state)$' <<<"$shares"; then no "metal sees a forbidden share: $(tr '\n' ' ' <<<"$shares")"
else ok "metal sees no hosts/hermes/state share"; fi

# --- 6. Credential plane -----------------------------------------------------

hdr "6. Credential plane — the agent egresses through the agent-vault proxy"
envline="$("${hermes_ssh[@]}" sudo -u hermes -H sh -c 'grep "^HTTPS_PROXY=" "$HOME/.hermes/.env"' 2>/dev/null || true)"
if grep -qE '^HTTPS_PROXY=http://av_agt_[^:]+:hermes@metal:14322' <<<"$envline"; then ok "HTTPS_PROXY routes through agent-vault (av_agt_…@metal:14322)"
else no "HTTPS_PROXY is not the agent-vault proxy (got: ${envline:-empty})"; fi
manual "Optional (consumes quota): an Exa/OpenAI/Honcho tool call from hermes returns 200, not 407 (407 = dead/missing proxy token)."

# --- 7. Tailnet tags + admin SSH ---------------------------------------------

hdr "7. Tailnet tags + admin SSH"
status="$(tailscale status --json 2>/dev/null || true)"
for node in hermes metal bluebubbles; do
  if printf '%s' "$status" | jq -e --arg n "$node" '[.Peer[]?, .Self] | any(.HostName == $n and ((.Tags // []) | index("tag:" + $n)))' >/dev/null 2>&1; then ok "$node carries tag:$node"
  else warn "could not confirm tag:$node (node offline, or it is this host's self view)"; fi
done
if tailscale ssh root@hermes -- true 2>/dev/null; then ok "admin \`tailscale ssh root@hermes\` works (additive admin-ssh rule)"
else no "\`tailscale ssh root@hermes\` failed (the additive admin-ssh rule)"; fi

# --- summary -----------------------------------------------------------------

hdr "Summary"
printf '  PASS=%d  FAIL=%d  MANUAL=%d\n' "$PASS" "$FAIL" "$MANUAL"
if [[ "$FAIL" -ne 0 ]]; then
  printf '\033[1;31m%d hard check(s) failed.\033[0m\n' "$FAIL" >&2
  exit 1
fi
printf '\033[1;32mAll hard checks passed.\033[0m Complete the %d MANUAL step(s) above to finish validation.\n' "$MANUAL"
