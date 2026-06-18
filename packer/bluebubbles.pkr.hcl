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
#   that cannot be Packer-provisioned. Use a SEPARATE Apple ID (@@APPLE_ID@@), not
#   your real one — see scripts/bluebubbles-setup.sh.
# HUMAN: After this image is captured, the cryptographically-bound boot-blob
#   triple — hardwareModel + ecid (config.json) + nvram.bin — must be copied
#   verbatim (`cp -c`) on any clone/migration and NEVER regenerated. Change any
#   one and the guest will not boot.

packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.12.0"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "bluebubbles"
}

# BB VM is the lightweight node — just enough to run BlueBubbles and expose
# iMessage/Calendar/Mail as hermes actions.
variable "cpu_count" {
  type    = number
  default = 2
}

variable "memory_gb" {
  type    = number
  default = 4
}

variable "disk_size_gb" {
  type    = number
  default = 64
}

# Local admin baked into the image — independent of the Apple ID that signs into
# iMessage later. SSH uses this account until Tailscale SSH takes over.
variable "vm_admin_user" {
  type    = string
  default = "@@VM_ADMIN_USER@@"
}

variable "vm_admin_pass" {
  type      = string
  default   = "@@VM_ADMIN_PASS@@"
  sensitive = true
}

source "tart-cli" "tahoe" {
  vm_base_name = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb
  ssh_username = var.vm_admin_user
  # The cloned base ships admin/admin; authenticate with that default, then the
  # first provisioner resets the password to var.vm_admin_pass (@@VM_ADMIN_PASS@@).
  ssh_password = "admin"
  headless     = true
  # Give the cloned base's guest agent + SSH a moment to come up before connecting.
  create_grace_time = "120s"
}

build {
  sources = ["source.tart-cli.tahoe"]

  # Install Homebrew, then the OSS Tailscale build (the App Store build does NOT
  # support `tailscale ssh`). Drop the daemon symlink where
  # `tailscaled install-system-daemon` expects it. Joining the tailnet
  # (`tailscale up`) is a HUMAN gate — it needs interactive auth and is done in
  # scripts/bluebubbles-setup.sh.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      # Reset the cloned base's default admin password (admin) to var.vm_admin_pass.
      "sudo dscl . -passwd /Users/${var.vm_admin_user} '${var.vm_admin_pass}'",
      "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
      "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
      "brew install tailscale",
      "sudo ln -sf \"$(brew --prefix)/bin/tailscaled\" /usr/local/bin/tailscaled",
      "sudo tailscaled install-system-daemon",
    ]
  }

  # HUMAN: the remaining bring-up is NOT scripted here:
  #   1. scripts/bluebubbles-setup.sh — sign into iMessage (@@APPLE_ID@@), install
  #      BlueBubbles + the Private API helper, `tailscale up`, then
  #      `tailscale serve --bg --https=443 1234` to expose the REST API at
  #      https://bluebubbles.@@TAILNET_DOMAIN@@.
}
