#!/bin/bash
# First-boot activator for the metal guest. The packer build pre-builds metal's system closure
# (`darwin-rebuild build`) but does NOT activate it: activation copies metal's age key and decrypts
# its sops secrets from the `metalsecrets` virtiofs share, which the host's tart runner mounts only
# at RUNTIME — so the image must hold no secrets. This LaunchDaemon (baked by packer/metal.pkr.hcl
# as a plain plist, since nix-darwin is not activated at build time) ACTIVATES the pre-built closure
# once the share is mounted at first boot, then self-disables via a sentinel. It activates the BAKED
# store path directly (no flake re-eval), so first boot needs ZERO GitHub access. @@METAL_TOPLEVEL@@
# is substituted with the pre-built system store path by the packer provisioner.
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
# before activation, so nix-darwin can claim them. Idempotent; runs as root (this is a LaunchDaemon).
for f in zshenv zshrc zprofile bashrc; do mv -f "/etc/$f" "/etc/$f.before-nix-darwin" 2>/dev/null || true; done

# Activate the PRE-BUILT closure (baked store path) — NOT `darwin-rebuild switch --flake`, which
# re-resolves the flake ref over the rate-limited GitHub API on an unauthenticated first boot.
# `darwin-rebuild activate` does no flake/GitHub access; set the system profile first (activate does
# not set it). All services are UserName=admin system daemons, so activation has NO `launchctl
# asuser` user-agent step (which aborts headless with no GUI session) — it runs the Homebrew bundle
# (omlx + tailscale) and postActivation (tailscaled install-system-daemon + the tailnet join).
TOPLEVEL="@@METAL_TOPLEVEL@@"
nix-env -p /nix/var/nix/profiles/system --set "$TOPLEVEL" || echo "metal-activate: nix-env --set returned non-zero"
"$TOPLEVEL/sw/bin/darwin-rebuild" activate || echo "metal-activate: darwin-rebuild activate returned non-zero"

# Success = metal actually joined the tailnet (the real criterion, not the activate exit code).
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
