#!/usr/bin/env bash
# Shared first-provisioner step for both macOS guest builds (metal from_ipsw, bluebubbles cloned
# base). Both ship the admin account as admin/admin; Packer authenticates SSH with that default,
# then runs this to set the real per-VM password (from the yclaw keychain, passed as PKR_VAR_*).
# Invoked via `provisioner "shell" { script = ... environment_vars = [VM_ADMIN_USER, VM_ADMIN_PASS] }`.
set -euo pipefail
sudo dscl . -passwd "/Users/${VM_ADMIN_USER}" "${VM_ADMIN_PASS}"
