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
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

NIX_CONFIG='experimental-features = nix-command flakes' \
  nix run nix-darwin/nix-darwin-25.05#darwin-rebuild -- \
  switch --flake github:@@GITHUB_OWNER@@/yclaw#metal
rc=$?

if [ "$rc" -eq 0 ]; then
  mkdir -p /var/lib && touch /var/lib/metal-activated
  echo "metal-activate: darwin-rebuild switch OK"
else
  echo "metal-activate: darwin-rebuild switch FAILED (rc=$rc) — will retry on next boot"
fi
exit "$rc"
