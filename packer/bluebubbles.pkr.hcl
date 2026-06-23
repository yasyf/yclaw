# Packer template: macOS base image for the bluebubbles VM (cirruslabs/tart).
#
# Clones the cirruslabs SIP-disabled macOS Tahoe base
# (ghcr.io/cirruslabs/macos-tahoe-base) and provisions only the scriptable
# baseline: Homebrew + OSS Tailscale. The base ships SIP-OFF (its build runs
# `csrutil disable`), exactly what BlueBubbles' Private API needs, so there is no
# recovery-mode SIP step. The heavy, un-scriptable steps are HUMAN gates that run
# AFTER this image boots:
#
#   - BlueBubbles + Apple-ID/iMessage: scripts/bluebubbles-setup.sh
#
# HUMAN: Apple-ID iMessage sign-in is an interactive flow (2FA, trust prompts)
#   that cannot be Packer-provisioned. Use a SEPARATE Apple ID, not your real one
#   — see scripts/bluebubbles-setup.sh.
# HUMAN: After this image is captured, the cryptographically-bound boot-blob
#   triple — hardwareModel + ecid (config.json) + nvram.bin — must be copied
#   verbatim (`cp -c`) on any clone/migration and NEVER regenerated. Change any
#   one and the guest will not boot.
#
# The wizard exports the build inputs as env before `packer build`:
#   PKR_VAR_vm_admin_user, PKR_VAR_vm_admin_pass. The required vm_admin_pass keeps a
#   fail-loud "@@UNSET_VM_ADMIN_PASS@@" sentinel default.
# The plugin pin + the vm_admin_user/vm_admin_pass/install_default_admin_password vars are shared
# in common.pkr.hcl; build with `packer build -only='tart-cli.bluebubbles' packer/`.

source "tart-cli" "bluebubbles" {
  # Pinned by immutable digest (audit M8): a mutable :latest tag let a registry-side
  # change silently mutate this SIP-off, credential-bearing iMessage VM on rebuild.
  # Resolved 2026-06-18 via:
  #   docker manifest inspect --verbose ghcr.io/cirruslabs/macos-tahoe-base:latest | jq -r '.Descriptor.digest'
  # Re-run that command and update the digest below on an intentional base bump.
  vm_base_name = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:a8e1c8305758643f513fdccdd829c2243687c60791083dea42f73f0b7aeb435c"
  vm_name      = "bluebubbles"
  # BB VM is the lightweight node — just enough to run BlueBubbles and expose iMessage/Calendar/Mail.
  cpu_count    = 2
  memory_gb    = 4
  disk_size_gb = 64
  ssh_username = var.vm_admin_user
  # The cloned base ships admin/admin; reset-admin-password.sh sets the real var.vm_admin_pass
  # in the first provisioner.
  ssh_password = var.install_default_admin_password
  headless     = true
  # Give the cloned base's guest agent + SSH a moment to come up before connecting.
  create_grace_time = "120s"
}

build {
  sources = ["source.tart-cli.bluebubbles"]

  # Reset the install-default admin password to the per-VM password (shared with metal).
  provisioner "shell" {
    script           = "${path.root}/reset-admin-password.sh"
    environment_vars = ["VM_ADMIN_USER=${var.vm_admin_user}", "VM_ADMIN_PASS=${var.vm_admin_pass}"]
  }

  # Install Homebrew, then the OSS Tailscale build (the App Store build does NOT
  # support `tailscale ssh`). Drop the daemon symlink where
  # `tailscaled install-system-daemon` expects it. Joining the tailnet
  # (`tailscale up --advertise-tags=tag:bluebubbles`) is a HUMAN gate — it needs
  # interactive auth and is done in scripts/bluebubbles-setup.sh. The operator
  # authenticates; tailnet/policy.hujson owns tag:bluebubbles, so advertising it
  # succeeds and binds this node to its ACL grant (hermes -> bluebubbles :443).
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
      "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
      "brew install tailscale",
      "sudo ln -sf \"$(brew --prefix)/bin/tailscaled\" /usr/local/bin/tailscaled",
      "sudo tailscaled install-system-daemon",
    ]
  }

  # HUMAN: the remaining bring-up is NOT scripted here:
  #   1. scripts/bluebubbles-setup.sh — sign into iMessage (a SEPARATE Apple ID),
  #      install BlueBubbles + the Private API helper,
  #      `tailscale up --advertise-tags=tag:bluebubbles`, then
  #      `tailscale serve --bg --https=443 1234` to expose the REST API at
  #      https://bluebubbles (MagicDNS; on your-tailnet it becomes bluebubbles.<tailnet>.ts.net).
}
