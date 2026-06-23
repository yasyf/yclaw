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
  description = "Pinned macOS Tahoe restore image (URL or local path). Set via PKR_VAR_ipsw_url."
  default     = "@@UNSET_IPSW_URL@@"
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
  # tart's from_ipsw install creates the admin account as admin/admin (same default the cirruslabs
  # base ships); reset-admin-password.sh sets the real var.vm_admin_pass in the first provisioner.
  ssh_password = var.install_default_admin_password
  headless     = true
  # macOS Setup Assistant + first-boot account creation need slack before SSH; a fresh install
  # boots slower than a clone, so allow a generous SSH timeout too.
  create_grace_time = "120s"
  ssh_timeout       = "600s"
}

build {
  sources = ["source.tart-cli.metal"]

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
