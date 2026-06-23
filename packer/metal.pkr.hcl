# Packer template: the macOS "metal" guest (cirruslabs/tart) — the locked-down, SIP-on
# credential + AI services VM (omlx, mlx-audio STT, CLIProxyAPI, agent-vault). Holds no
# iMessage/BlueBubbles. Builds a fresh macOS Tahoe install from a pinned IPSW, installs
# Nix + nix-darwin, and applies `darwinConfigurations.metal` (darwin/metal.nix) so every
# service is declarative.
#
# A fresh macOS install from the pinned IPSW is SIP-ON by default (unlike the cirruslabs
# published *-base images, which run `csrutil disable`), so metal needs no SIP step.
#
# The un-scriptable steps are HUMAN gates that run AFTER this image boots:
#   - cliproxy Codex/Gemini logins:       device-code / VNC browser flow
#   - Google OAuth:                       scripts/connect-google-oauth.py (VAULT_ADDR=http://metal…)
#   - place the local model:              hf download the Qwen MLX model onto the state mount
#
# HUMAN: After capture, the cryptographically-bound boot-blob triple — hardwareModel + ecid
#   (config.json) + nvram.bin — must be copied verbatim (`cp -c`) on any clone and NEVER
#   regenerated; change one and the guest will not boot.
#
# The wizard exports the build inputs as env before `packer build`:
#   PKR_VAR_ipsw_url, PKR_VAR_github_owner, PKR_VAR_vm_admin_user, PKR_VAR_vm_admin_pass,
#   PKR_VAR_repo_url. Required-but-unset vars keep a fail-loud "@@UNSET_*@@" sentinel default.
# The plugin pin + the vm_admin_user/vm_admin_pass/install_default_admin_password vars are shared
# in common.pkr.hcl (Packer loads every *.pkr.hcl in this dir together; build with
# `packer build -only='tart-cli.metal' packer/`).

variable "ipsw_url" {
  type        = string
  description = "Pinned macOS Tahoe restore image. Defaults to the EXACT IPSW cirruslabs' vanilla-tahoe template builds from, so the boot_command Setup-Assistant choreography below matches this macOS build. Override via PKR_VAR_ipsw_url ONLY together with a matching boot_command."
  default     = "https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-58869/DFB1CEEF-5619-4591-9924-E20DB2C8FED0/UniversalMac_26.5_25F71_Restore.ipsw"
}

# GitHub owner whose yclaw fork the guest clones, unless repo_url overrides it. Set via
# PKR_VAR_github_owner.
variable "github_owner" {
  type    = string
  default = "@@UNSET_GITHUB_OWNER@@"
}

# Explicit clone URL; when empty, locals.clone_url falls back to the github_owner fork.
variable "repo_url" {
  type    = string
  default = ""
}

locals {
  clone_url = var.repo_url != "" ? var.repo_url : "https://github.com/${var.github_owner}/yclaw.git"
}

source "tart-cli" "metal" {
  from_ipsw = var.ipsw_url
  vm_name   = "metal"
  # metal runs the 35B MLX model + the STT model + the Go services, so it is the heavy node.
  cpu_count    = 10
  memory_gb    = 48
  disk_size_gb = 200
  ssh_username = var.vm_admin_user
  # A fresh from_ipsw install boots to Setup Assistant with NO account and NO SSH — tart does not
  # automate it. boot_command drives Setup Assistant over the virtual keyboard to create admin/admin
  # and enable Remote Login (SSH); reset-admin-password.sh then sets the real var.vm_admin_pass.
  ssh_password = var.install_default_admin_password
  headless     = true
  # Keep the recovery partition so `softwareupdate` keeps working in the guest.
  recovery_partition = "keep"
  create_grace_time  = "30s"
  ssh_timeout        = "300s"
  # Setup-Assistant choreography replicated from cirruslabs' vanilla-tahoe template
  # (github.com/cirruslabs/macos-image-templates), which pins this exact IPSW. We keep their
  # account-creation + Remote-Login steps but DROP their SIP/Gatekeeper-disable tail: metal is the
  # hardened, SIP-on credential node. Keystroke counts are tuned to macOS 26.5's screens — bump the
  # IPSW and this block together.
  boot_command = [
    # hello, hola, bonjour, …
    "<wait60s><spacebar>",
    # Language: switch to Italiano then back to English so we land on the first "English" entry.
    "<wait30s>italiano<esc>english<enter>",
    # Select Your Country or Region
    "<wait60s><click 'Select Your Country or Region'><wait5s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    # Transfer Your Data to This Mac
    "<wait10s><tab><tab><tab><spacebar><tab><tab><spacebar>",
    # Written and Spoken Languages
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Accessibility
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Data & Privacy
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Create a Mac Account: full name "Managed via Tart", account admin, password admin
    "<wait10s><tab><tab><tab><tab><tab><tab>Managed via Tart<tab>admin<tab>admin<tab>admin<tab><tab><spacebar><tab><tab><spacebar>",
    # Enable Voice Over (so the remaining screens are keyboard-navigable)
    "<wait120s><leftAltOn><f5><leftAltOff>",
    # Sign In with Your Apple ID -> skip
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar><up><spacebar>",
    # Are you sure you want to skip signing in with an Apple ID?
    "<wait10s><tab><spacebar>",
    # Terms and Conditions
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # I have read and agree …
    "<wait10s><tab><spacebar>",
    # Age Range -> Adult
    "<wait10s><tab><tab><tab><spacebar>",
    # Enable Location Services -> skip
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Are you sure you don't want to use Location Services?
    "<wait10s><tab><spacebar>",
    # Select Your Time Zone -> UTC
    "<wait10s><tab><tab><tab>UTC<enter><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Analytics
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Screen Time
    "<wait10s><tab><tab><spacebar>",
    # Siri
    "<wait10s><tab><spacebar><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Your Mac is Ready for FileVault
    "<wait10s><leftShiftOn><tab><tab><leftShiftOff><spacebar>",
    # Mac Data Will Not Be Securely Encrypted
    "<wait10s><tab><spacebar>",
    # Choose Your Look
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    # Update Mac Automatically
    "<wait10s><tab><tab><spacebar>",
    # Welcome to Mac
    "<wait30s><spacebar>",
    # Disable Voice Over
    "<wait10s><leftAltOn><f5><leftAltOff>",
    # Open Terminal and enable full keyboard navigation so System Settings is tab-navigable
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<wait10s><enter>",
    "<wait10s><wait10s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    # Open System Settings
    "<wait10s>open '/System/Applications/System Settings.app'<enter>",
    "<wait120s>",
    # Navigate to Sharing
    "<wait10s><leftCtrlOn><f2><leftCtrlOff><right><right><right><down>Sharing<enter>",
    # Enable Screen Sharing
    "<wait10s><tab><tab><tab><tab><tab><spacebar>",
    # Authenticate to enable Screen Sharing
    "<wait10s>admin<enter>",
    # Navigate to Remote Login and enable it (the SSH service packer connects to)
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    # Quit System Settings
    "<wait10s><leftAltOn>q<leftAltOff>",
  ]
}

build {
  sources = ["source.tart-cli.metal"]

  # The fresh from_ipsw install has no passwordless sudo (the cirruslabs base bluebubbles clones
  # already does), and admin's password is still the install default here — enable it now, before
  # reset-admin-password.sh and the nix provisioner, which use sudo non-interactively.
  provisioner "shell" {
    inline = [
      "echo ${var.install_default_admin_password} | sudo -S sh -c \"mkdir -p /etc/sudoers.d/; echo 'admin ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/admin-nopasswd\"",
    ]
  }

  # Reset the install-default admin password to the per-VM password (shared with bluebubbles).
  provisioner "shell" {
    script           = "${path.root}/reset-admin-password.sh"
    environment_vars = ["VM_ADMIN_USER=${var.vm_admin_user}", "VM_ADMIN_PASS=${var.vm_admin_pass}"]
  }

  # Install Nix (Determinate) + nix-darwin, clone the repo, and apply `.#metal`. Everything
  # the services need (omlx via Homebrew, the mlx-audio STT venv, the nix-built cliproxy +
  # agent-vault, the pf/app-firewall lockdown, sops-nix) is declared in darwin/metal.nix, so
  # the provisioner is thin. The host shares the age key + secrets blob + model cache into the
  # guest at RUN time via `tart run --dir=state:~/.yclaw/state` (see scripts/setup.sh).
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm",
      ". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
      "git clone ${local.clone_url} /Users/${var.vm_admin_user}/yclaw",
      # First `darwin-rebuild switch` must run as root (system activation) from a git-clean path.
      "sudo NIX_CONFIG='experimental-features = nix-command flakes' \\",
      "  nix run nix-darwin/nix-darwin-25.05#darwin-rebuild -- \\",
      "  switch --flake /Users/${var.vm_admin_user}/yclaw#metal",
    ]
  }

  # HUMAN: the remaining bring-up is NOT scripted here (see the gates listed in the header):
  #   1. cliproxy --codex-login/--login   — device-code / VNC browser flow.
  #   2. scripts/connect-google-oauth.py  — VAULT_ADDR=http://metal:14321.
  #   3. place the Qwen MLX model         — hf download onto /Volumes/My Shared Files/state/hf.
}
