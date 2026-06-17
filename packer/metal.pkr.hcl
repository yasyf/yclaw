# Packer template: the macOS "metal" guest (cirruslabs/tart) — the single locked-down
# services VM (omlx, mlx-audio STT, CLIProxyAPI, agent-vault) that ALSO runs BlueBubbles/
# iMessage. Builds a fresh macOS Tahoe install from a pinned IPSW, installs Nix + nix-darwin,
# and applies `darwinConfigurations.metal` (darwin/metal.nix) so every service is declarative.
#
# The un-scriptable steps are HUMAN gates that run AFTER this image boots:
#   - SIP disable (recovery mode):        scripts/sip-disable.md  (BlueBubbles private API needs it)
#   - Apple-ID / iMessage sign-in:        interactive 2FA + trust prompts (use a SEPARATE Apple ID)
#   - cliproxy Codex/Gemini logins:       device-code / VNC browser flow
#   - Google OAuth:                       scripts/connect-google-oauth.py (VAULT_ADDR=http://metal…)
#   - place the local model:              hf download the Qwen MLX model onto the state mount
#
# HUMAN: SIP disable needs macOS recovery (`tart run metal --recovery` -> `csrutil disable`),
#   which a Packer provisioner cannot reach — keep it in scripts/sip-disable.md.
# HUMAN: After capture, the cryptographically-bound boot-blob triple — hardwareModel + ecid
#   (config.json) + nvram.bin — must be copied verbatim (`cp -c`) on any clone and NEVER
#   regenerated; change one and the guest will not boot.

packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.12.0"
    }
  }
}

variable "ipsw_url" {
  type        = string
  description = "Pinned macOS Tahoe restore image (URL or local path)."
  default     = "@@IPSW_URL@@"
}

variable "vm_name" {
  type    = string
  default = "metal"
}

# metal runs the 35B MLX model + the STT model + the Go services, so it is the heavy node.
variable "cpu_count" {
  type    = number
  default = 10
}

variable "memory_gb" {
  type    = number
  default = 48
}

variable "disk_size_gb" {
  type    = number
  default = 200
}

# Local admin baked into the image (independent of the Apple ID that signs into iMessage).
# nix-darwin's primaryUser + launchd.user.agents target this account, so it MUST be `admin`
# to match darwin/metal.nix (adminUser = "admin", home /Users/admin).
variable "vm_admin_user" {
  type    = string
  default = "admin"
}

variable "vm_admin_pass" {
  type      = string
  default   = "@@VM_ADMIN_PASS@@"
  sensitive = true
}

source "tart-cli" "tahoe" {
  from_ipsw    = var.ipsw_url
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb
  ssh_username = var.vm_admin_user
  ssh_password = var.vm_admin_pass
  headless     = true
  # macOS Setup Assistant + first-boot account creation need slack before SSH.
  create_grace_time = "120s"
}

build {
  sources = ["source.tart-cli.tahoe"]

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
      "git clone https://github.com/@@GITHUB_OWNER@@/yclaw.git /Users/${var.vm_admin_user}/yclaw",
      # First `darwin-rebuild switch` must run as root (system activation) from a git-clean path.
      "sudo NIX_CONFIG='experimental-features = nix-command flakes' \\",
      "  nix run nix-darwin/nix-darwin-25.05#darwin-rebuild -- \\",
      "  switch --flake /Users/${var.vm_admin_user}/yclaw#metal",
    ]
  }

  # HUMAN: the remaining bring-up is NOT scripted here (see the gates listed in the header):
  #   1. scripts/sip-disable.md           — disable SIP in recovery mode (BlueBubbles private API).
  #   2. Apple-ID iMessage sign-in        — interactive 2FA; install the BlueBubbles server + helper.
  #   3. cliproxy --codex-login/--login   — device-code / VNC browser flow.
  #   4. scripts/connect-google-oauth.py  — VAULT_ADDR=http://metal.@@TAILNET_DOMAIN@@:14321.
  #   5. place the Qwen MLX model         — hf download onto /Volumes/My Shared Files/state/hf.
}
