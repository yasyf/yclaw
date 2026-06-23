# Packer template: the macOS "metal" guest (cirruslabs/tart) — the locked-down, SIP-on
# credential + AI services VM (omlx, mlx-audio STT, CLIProxyAPI, agent-vault). Holds no
# iMessage/BlueBubbles. Clones the cirruslabs SIP-ON vanilla Tahoe base, installs Nix, and
# PRE-BUILDS `darwinConfigurations.metal` (darwin/metal.nix) into the image's store.
#
# The image holds NO secrets: nix-darwin ACTIVATION copies metal's age key and decrypts its sops
# secrets from the `metalsecrets` virtiofs share, which the host's tart runner mounts only at
# RUNTIME — so `darwin-rebuild switch` cannot run at build time. The build runs `darwin-rebuild
# build` (validates the config + bakes the closure, no activation), and a baked first-boot
# LaunchDaemon (metal-activate.sh) runs the `switch` once the share is mounted. See that script.
#
# The base is cirruslabs' `macos-tahoe-vanilla` (admin/admin + Remote Login + passwordless sudo,
# CI-built from a pinned IPSW). It is SIP-ON: their *-base images run `csrutil disable` ON TOP of
# this vanilla base, but metal does not, so it stays SIP-on with no SIP step. (Driving Setup
# Assistant from a raw IPSW via boot_command proved too fragile on macOS 26.5, so metal clones the
# prebuilt vanilla base, exactly like bluebubbles clones its SIP-off base.)
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
#   PKR_VAR_github_owner, PKR_VAR_vm_admin_user, PKR_VAR_vm_admin_pass.
#   github_owner keeps a fail-loud "@@UNSET_*@@" sentinel default.
# The plugin pin + the vm_admin_user/vm_admin_pass/install_default_admin_password vars are shared
# in common.pkr.hcl (Packer loads every *.pkr.hcl in this dir together; build with
# `packer build -only='tart-cli.metal' packer/`).

# GitHub owner whose yclaw fork the build applies as `github:<owner>/yclaw#metal`. Set via
# PKR_VAR_github_owner.
variable "github_owner" {
  type    = string
  default = "@@UNSET_GITHUB_OWNER@@"
}

# GitHub token for nix's flake-input fetches: nix pulls each github: input via the API, which is
# unauthenticated-rate-limited to 60/hr/IP — one metal build exhausts it. Used only at build time
# via a temporary nix.conf that is removed afterward (NEVER written into the captured image). Set
# via PKR_VAR_github_token (the wizard passes the host's `gh auth token`).
variable "github_token" {
  type      = string
  default   = ""
  sensitive = true
}

source "tart-cli" "metal" {
  # Pinned by immutable digest (audit M8): a mutable :latest tag would let a registry-side change
  # silently mutate this SIP-on credential VM on rebuild. Resolved 2026-06-22 via:
  #   docker manifest inspect --verbose ghcr.io/cirruslabs/macos-tahoe-vanilla:latest | jq -r '.Descriptor.digest'
  # Re-run that and update the digest on an intentional base bump — keep it the VANILLA base
  # (SIP-on), NOT the *-base image (which is csrutil-disabled).
  vm_base_name = "ghcr.io/cirruslabs/macos-tahoe-vanilla@sha256:e12d678b248f3122e276fa64632970a8e1c6dc60ff6738d21fe9bfa5ea58f426"
  vm_name      = "metal"
  # metal runs the 35B MLX model + the STT model + the Go services, so it is the heavy node.
  cpu_count    = 10
  memory_gb    = 48
  disk_size_gb = 200
  ssh_username = var.vm_admin_user
  # The vanilla base ships admin/admin; reset-admin-password.sh sets the real var.vm_admin_pass
  # in the first provisioner.
  ssh_password = var.install_default_admin_password
  headless     = true
  # Give the cloned base's guest agent + SSH a moment to come up before connecting.
  create_grace_time = "120s"
}

build {
  sources = ["source.tart-cli.metal"]

  # Reset the cloned base's default admin password (admin) to the per-VM password (shared with
  # bluebubbles). The vanilla base already has passwordless sudo, so this runs non-interactively.
  provisioner "shell" {
    script           = "${path.root}/reset-admin-password.sh"
    environment_vars = ["VM_ADMIN_USER=${var.vm_admin_user}", "VM_ADMIN_OLD_PASS=${var.install_default_admin_password}", "VM_ADMIN_PASS=${var.vm_admin_pass}"]
  }

  # Install Nix (Determinate) and PRE-BUILD metal's system closure WITHOUT activating it.
  # `darwin-rebuild build` validates darwin/metal.nix and bakes the whole closure (omlx, the
  # mlx-audio STT venv, the nix-built cliproxy + agent-vault, the pf/app-firewall lockdown,
  # sops-nix) into the image's store, but does NOT run activation — activation copies the age key
  # and decrypts sops from the runtime-only metalsecrets share, so the `switch` is deferred to
  # first boot (metal-activate.sh below). Build from the flake on GitHub: the vanilla base has no
  # git / Xcode CLT (a `git clone` would pop the Command Line Tools dialog and fail), and nix
  # fetches github: refs with its own fetcher, as the nix-darwin ref already does.
  provisioner "shell" {
    environment_vars = ["YCLAW_GH_TOKEN=${var.github_token}"]
    inline = [
      "set -euo pipefail",
      # The vanilla base has no Homebrew (only the cirruslabs *-base images add it on top), but
      # metal's nix-darwin config uses the homebrew module (omlx is a brew formula) — which aborts
      # activation if brew is absent. Install it (NONINTERACTIVE for the non-tty packer shell).
      "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
      # omlx's Homebrew tap lives at github.com/jundot/omlx, NOT the default `homebrew-omlx` repo
      # `brew tap jundot/omlx` would clone (that 404s). Pre-tap with the explicit clone URL so the
      # nix-darwin homebrew module's `brew bundle` (taps = [\"jundot/omlx\"]) finds it already present.
      "/opt/homebrew/bin/brew tap jundot/omlx https://github.com/jundot/omlx",
      # Homebrew refuses to install formulae from an untrusted third-party tap; trust it so the
      # nix-darwin homebrew module's `brew install omlx` succeeds.
      "/opt/homebrew/bin/brew trust jundot/omlx",
      "curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm",
      # The Determinate installer writes /etc/{zshenv,zshrc,zprofile,bashrc} to put Nix on the
      # non-interactive PATH, but nix-darwin's activation also manages those and aborts rather than
      # overwrite an unrecognized file. Rename them so nix-darwin claims them (its versions re-add
      # Nix to PATH); the originals are kept as *.before-nix-darwin.
      "for f in zshenv zshrc zprofile bashrc; do sudo mv -f \"/etc/$f\" \"/etc/$f.before-nix-darwin\" 2>/dev/null || true; done",
      ". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
      # Build-time GitHub auth (see the github_token var): without it, nix's flake-input fetches hit
      # the unauthenticated GitHub API rate limit (60/hr) and a single build exhausts it. The token
      # comes from the redacted YCLAW_GH_TOKEN env (set on this provisioner), so it is not in the
      # logged command and is never written into the captured image.
      "sudo NIX_CONFIG=\"experimental-features = nix-command flakes\naccess-tokens = github.com=$YCLAW_GH_TOKEN\" nix run nix-darwin/nix-darwin-25.05#darwin-rebuild -- build --flake github:${var.github_owner}/yclaw#metal",
    ]
  }

  # Stage the first-boot activator (a plain LaunchDaemon — nix-darwin is not yet activated, so it
  # cannot be a nix-darwin daemon). It runs `darwin-rebuild switch` once the metalsecrets share is
  # mounted at first boot, then self-disables via a sentinel. It loads at the next boot (the
  # runtime boot under the tart runner), not during this build.
  provisioner "file" {
    source      = "${path.root}/metal-activate.sh"
    destination = "/tmp/metal-activate.sh"
  }
  provisioner "file" {
    source      = "${path.root}/com.yclaw.metal-activate.plist"
    destination = "/tmp/com.yclaw.metal-activate.plist"
  }
  provisioner "shell" {
    environment_vars = ["GH_OWNER=${var.github_owner}"]
    inline = [
      "set -euo pipefail",
      # Bake the operator's GitHub owner into the activator (BSD sed needs the empty -i arg).
      "sed -i '' \"s/@@GITHUB_OWNER@@/$GH_OWNER/g\" /tmp/metal-activate.sh",
      "sudo install -m 755 /tmp/metal-activate.sh /usr/local/bin/metal-activate.sh",
      "sudo install -m 644 /tmp/com.yclaw.metal-activate.plist /Library/LaunchDaemons/com.yclaw.metal-activate.plist",
      "rm -f /tmp/metal-activate.sh /tmp/com.yclaw.metal-activate.plist",
    ]
  }

  # HUMAN: the remaining bring-up is NOT scripted here (see the gates listed in the header):
  #   1. cliproxy --codex-login/--login   — device-code / VNC browser flow.
  #   2. scripts/connect-google-oauth.py  — VAULT_ADDR=http://metal:14321.
  #   3. place the Qwen MLX model         — hf download onto /Volumes/My Shared Files/state/hf.
}
