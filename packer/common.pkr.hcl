# Shared Packer config for the macOS guest builds (metal + bluebubbles). Packer loads every
# *.pkr.hcl in this directory together, so the plugin pin and the admin-account variables live
# here once; the node-specific source/build blocks live in metal.pkr.hcl and bluebubbles.pkr.hcl.
# Build one node with:  packer build -only='tart-cli.<node>' packer/
#
# (Source blocks cannot inherit in Packer, so the identical ssh_username/ssh_password/headless
# stanza is repeated per source; the reusable admin-password reset is shared via
# reset-admin-password.sh, run as each build's first provisioner.)

packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.12.0"
    }
  }
}

# Local admin baked into both images. nix-darwin's primaryUser + launchd.user.agents target this
# account, so it MUST be `admin` to match darwin/metal.nix (adminUser = "admin"). Both the cloned
# cirruslabs base and tart's from_ipsw install ship this account as admin/admin; each build SSHes
# in with that default and reset-admin-password.sh sets the real per-VM password.
variable "vm_admin_user" {
  type    = string
  default = "admin"
}

# The password both images' admin account ships with before reset_admin_password.sh runs: tart's
# from_ipsw install and the cirruslabs base both create admin/admin, so each source authenticates
# SSH with this until the first provisioner sets vm_admin_pass.
variable "install_default_admin_password" {
  type    = string
  default = "admin"
}

# The real value comes from the env as PKR_VAR_vm_admin_pass, sourced from the dedicated yclaw
# keychain ($HOME/Library/Keychains/yclaw.keychain-db, random-generated per-VM by
# scripts/lib/secrets.sh: service yclaw-<node>-admin-pass) after unlocking that keychain with the
# login-keychain-stored yclaw-keychain-password — never prompted, never hardcoded. The
# @@UNSET_VM_ADMIN_PASS@@ default is a fail-loud sentinel: build without exporting
# PKR_VAR_vm_admin_pass and the image bakes the placeholder. See docs/DEPLOY.md step 3.
variable "vm_admin_pass" {
  type      = string
  default   = "@@UNSET_VM_ADMIN_PASS@@"
  sensitive = true
}
