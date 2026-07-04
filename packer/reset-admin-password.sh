#!/usr/bin/env bash
# Shared first-provisioner step for both macOS guest builds (metal clones the SIP-on vanilla base,
# bluebubbles the SIP-off base). Both ship the admin account as admin/admin; Packer authenticates SSH with that default,
# then runs this to set the real per-VM password (from the yclaw keychain, passed as PKR_VAR_*).
# Invoked via `provisioner "shell" { script = ... environment_vars = [VM_ADMIN_USER,
# VM_ADMIN_OLD_PASS, VM_ADMIN_PASS] }`.
#
# Use the 3-arg `-passwd <path> <old> <new>` form: the 2-arg (root, no old password) form prompts
# for the old password and fails non-interactively (eDSAuthFailed) on these accounts. The old
# password is the cirruslabs base's install default.
set -euo pipefail
sudo dscl . -passwd "/Users/${VM_ADMIN_USER}" "${VM_ADMIN_OLD_PASS}" "${VM_ADMIN_PASS}"

# The base image's /etc/kcpassword still encodes the PRE-rotation password after the dscl reset,
# so every boot fires a FAILED auto-login that accrues an account lockout ("account locked, try
# again in N minutes"). What replaces it is per-node (VM_AUTOLOGIN, required):
#   drop  — metal: headless, every service is a system daemon; no GUI session needed. Remove the
#           blob and the auto-login key entirely.
#   fresh — bluebubbles: BlueBubbles.app + Messages.app need a logged-in GUI session at every
#           boot; re-establish auto-login with the NEW password via sysadminctl.
case "${VM_AUTOLOGIN:?set VM_AUTOLOGIN=drop|fresh}" in
  drop)
    sudo rm -f /etc/kcpassword
    sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser || true
    ;;
  fresh)
    sudo sysadminctl -autologin set -userName "${VM_ADMIN_USER}" -password "${VM_ADMIN_PASS}"
    ;;
  *)
    echo "reset-admin-password: unknown VM_AUTOLOGIN='${VM_AUTOLOGIN}' (expected drop|fresh)" >&2
    exit 1
    ;;
esac
