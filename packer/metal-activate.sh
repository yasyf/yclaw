#!/bin/bash
# First-boot activator for the metal guest. The packer build pre-builds metal's system closure
# (`darwin-rebuild build`) but does NOT activate it: activation copies metal's age key and decrypts
# its sops secrets from the `metalsecrets` virtiofs share, which the host's tart runner mounts only
# at RUNTIME — so the image must hold no secrets. This LaunchDaemon (baked by packer/metal.pkr.hcl
# as a plain plist, since nix-darwin is not activated at build time) runs `darwin-rebuild switch`
# once the share is mounted at first boot, then self-disables via a sentinel. Reboots then boot the
# already-activated system; metal-boot-setup re-applies the volatile pf/sysctl. @@GITHUB_OWNER@@ is
# substituted with the operator's GitHub owner by the packer provisioner.
set -uo pipefail
exec >>/var/log/metal-activate.log 2>&1
echo "=== metal-activate $(date) ==="

[ -f /var/lib/metal-activated ] && { echo "already activated; nothing to do"; exit 0; }

key="/Volumes/My Shared Files/metalsecrets/key.txt"
for _ in $(seq 1 120); do [ -s "$key" ] && break; echo "waiting for metalsecrets share ..."; sleep 5; done
[ -s "$key" ] || { echo "FATAL: metalsecrets share ($key) not mounted after 600s"; exit 1; }

# The Determinate Nix daemon also starts at boot — wait for its socket before invoking nix.
for _ in $(seq 1 60); do [ -S /nix/var/nix/daemon-socket/socket ] && break; sleep 2; done
# LaunchDaemons run with a minimal env (no HOME/USER), and nix-daemon.sh references $HOME — which
# `set -u` would abort on. Root's home is /var/root on macOS.
export HOME="${HOME:-/var/root}" USER="${USER:-root}"
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# nix-darwin activation refuses to overwrite unrecognized /etc shell files. The Determinate Nix
# install (re)creates /etc/{zshenv,zshrc,bashrc} for the non-interactive PATH and they are present
# again by first boot (the packer build's rename does not survive), so rename them here, right
# before the switch, so nix-darwin can claim them. Idempotent; runs as root (this is a LaunchDaemon).
for f in zshenv zshrc zprofile bashrc; do mv -f "/etc/$f" "/etc/$f.before-nix-darwin" 2>/dev/null || true; done

# `darwin-rebuild switch` builds + sets the generation + activates, but has been observed to exit
# non-zero (134) at a late user-launchd step BEFORE postActivation (the tailnet join) runs. The
# generation is set by then, so re-run the now-current system's activate (idempotent, rc=0) to
# complete activation: the homebrew bundle (omlx + tailscale) and postActivation (tailscaled
# install-system-daemon + the tailnet join).
# Retry the switch a few times: the build authenticated nix's GitHub fetches, but first boot is
# unauthenticated, so resolving the flake ref can transiently hit the 60/hr API rate limit (which
# recovers ~1/min). The flake INPUTS are already cached in the image store, so only the ref-resolve
# needs the API.
switched=""
for attempt in 1 2 3 4; do
  if NIX_CONFIG='experimental-features = nix-command flakes' \
       nix run nix-darwin/nix-darwin-25.05#darwin-rebuild -- \
       switch --flake github:@@GITHUB_OWNER@@/yclaw#metal; then switched=1; break; fi
  echo "metal-activate: darwin-rebuild switch attempt $attempt failed; retrying in 90s"
  sleep 90
done
[ -n "$switched" ] || echo "metal-activate: switch did not succeed in 4 attempts; completing via /run/current-system/activate"
[ -x /run/current-system/activate ] && /run/current-system/activate || true

# Success = metal actually joined the tailnet (the real criterion, not the switch exit code).
joined=""
for _ in $(seq 1 60); do
  if /opt/homebrew/bin/tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'; then joined=1; break; fi
  sleep 5
done
if [ -n "$joined" ]; then
  mkdir -p /var/lib && touch /var/lib/metal-activated
  echo "metal-activate: activated and joined the tailnet"
  exit 0
fi
echo "metal-activate: did NOT join the tailnet — will retry on next boot"
exit 1
