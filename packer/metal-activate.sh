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

# Bounded, fail-loud polling helpers, shipped into the image at /usr/local/lib/yclaw/wait.sh by
# packer/metal.pkr.hcl (source: scripts/lib/wait.sh). Replaces this activator's hand-rolled loops.
# shellcheck source=scripts/lib/wait.sh
. /usr/local/lib/yclaw/wait.sh

[ -f /var/lib/metal-activated ] && { echo "already activated; nothing to do"; exit 0; }

key="/Volumes/My Shared Files/metalsecrets/key.txt"
wait_file_nonempty "$key" 600 || exit 1

# The Determinate Nix daemon also starts at boot — wait for its socket before invoking nix. This is
# a plain poll, not a mount-event wait: [ -S ] just tests the socket's existence.
wait_for "nix daemon socket" 60 2 test -S /nix/var/nix/daemon-socket/socket
# LaunchDaemons run with a minimal env (no HOME/USER), and nix-daemon.sh references $HOME — which
# `set -u` would abort on. Root's home is /var/root on macOS.
export HOME="${HOME:-/var/root}" USER="${USER:-root}"
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# Activate the PRE-BUILT closure (baked store path) — NOT `darwin-rebuild switch --flake`, which
# re-resolves the flake ref over the rate-limited GitHub API on an unauthenticated first boot.
# `darwin-rebuild activate` does no flake/GitHub access; set the system profile first (activate does
# not set it). All services are UserName=admin system daemons, so activation has NO `launchctl
# asuser` user-agent step (which aborts headless with no GUI session) — it runs the Homebrew bundle
# (omlx + tailscale) and postActivation (tailscaled install-system-daemon + the tailnet join).
TOPLEVEL="@@METAL_TOPLEVEL@@"
nix-env -p /nix/var/nix/profiles/system --set "$TOPLEVEL" || echo "metal-activate: nix-env --set returned non-zero"

# nix-darwin activation refuses to overwrite unrecognized /etc shell files, and the Determinate Nix
# daemon RE-CREATES /etc/{zshenv,zshrc,bashrc} at first boot — racing this activation. A single
# up-front rename loses when the daemon recreates them AFTER we rename but BEFORE activate checks,
# and a fresh metal then strands off the tailnet (activate aborts "Unexpected files in /etc"). So
# re-rename right before EACH attempt and retry: a one-shot recreate cannot win a retry loop. Once
# activate succeeds nix-darwin owns /etc/* (they still source the nix profile, so the Determinate
# daemon is satisfied and stops recreating them).
activated=""
for attempt in 1 2 3 4 5; do
  for f in zshenv zshrc zprofile bashrc; do mv -f "/etc/$f" "/etc/$f.before-nix-darwin" 2>/dev/null || true; done
  if "$TOPLEVEL/sw/bin/darwin-rebuild" activate; then activated=1; break; fi
  echo "metal-activate: activate attempt $attempt failed (likely the Determinate /etc race) — re-renaming, retry in 5s"
  sleep 5
done
[ -n "$activated" ] || echo "metal-activate: darwin-rebuild activate did not succeed after 5 attempts"

# Success = metal actually joined the tailnet (the real criterion, not the activate exit code).
# wait_for runs a simple command, so wrap the status|grep pipeline in a helper it can poll.
# shellcheck disable=SC2329  # invoked indirectly, as wait_for's polled command
_metal_tailnet_running() {
  /opt/homebrew/bin/tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'
}
if wait_for "tailnet join (BackendState=Running)" 60 5 _metal_tailnet_running; then
  mkdir -p /var/lib && touch /var/lib/metal-activated
  echo "metal-activate: activated and joined the tailnet"
  exit 0
fi
echo "metal-activate: did NOT join the tailnet — will retry on next boot"
exit 1
