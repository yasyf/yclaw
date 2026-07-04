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

# Disable auto-login on these headless (every-service-is-a-daemon) guests: its stale /etc/kcpassword
# still holds the pre-rotation password, so each boot fires a FAILED login that accrues an account
# lockout ("account locked, try again in N minutes"). Drop the password blob and the auto-login key.
sudo rm -f /etc/kcpassword
sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser || true
