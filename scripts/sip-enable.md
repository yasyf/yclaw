# Enable SIP on the metal VM

> **HUMAN gate.** This step runs in macOS recovery mode and cannot be scripted. The cirruslabs/tart
> base image ships with [System Integrity Protection](https://support.apple.com/en-us/102149) **off**
> (its build runs `csrutil disable`), so a fresh metal guest inherits SIP off. metal is the
> locked-down credential + AI VM and must run SIP **on**, so re-enable it here. The bluebubbles VM is
> the mirror image — it keeps SIP **off** so BlueBubbles can load its private iMessage extension.

## When

On the metal macOS guest, once, after the Packer build and before you trust the lockdown. Because the
base image ships SIP off, skipping this leaves the "metal is SIP-on" guarantee false. This applies to
metal only; bluebubbles stays SIP **off** (see [`sip-disable.md`](sip-disable.md)).

## Interactive method

1. Boot the VM into recovery mode:

   ```bash
   tart run metal --recovery
   ```

2. The VM pauses at the recovery screen; on its window (or over VNC) choose **Options → Continue**,
   then authenticate as the `admin` user.

3. Open **Utilities → Terminal** and enable SIP:

   ```bash
   csrutil enable
   ```

   `csrutil enable` needs no `y` confirmation, where `csrutil disable` does.

4. Reboot:

   ```bash
   reboot
   ```

5. Confirm SIP is on once the VM is back up (over `tailscale ssh` or VNC):

   ```bash
   csrutil status   # expect: "System Integrity Protection status: enabled."
   ```

## Reproducible (Packer) method

To bake this into the build instead, drive recovery with a keystroke-injection stage — the exact
inverse of cirruslabs'
[`templates/disable-sip.pkr.hcl`](https://github.com/cirruslabs/macos-image-templates/blob/master/templates/disable-sip.pkr.hcl).
Boot `recovery = true` with `communicator = "none"` and swap `csrutil disable` (plus its `y`
confirmation) for `csrutil enable`:

```hcl
source "tart-cli" "tart" {
  vm_name      = var.vm_name
  recovery     = true
  communicator = "none"
  boot_command = [
    "<wait60s><right><right><enter>",      # recovery screen -> Options -> Continue
    "<wait10s><leftAltOn>T<leftAltOff>",   # Utilities -> Terminal (Alt+T)
    "<wait10s>csrutil enable<enter>",      # no y/confirm, unlike disable
    "<wait10s>admin<enter>",               # authenticate as the admin user
    "<wait10s>halt<enter>",
  ]
}

build {
  sources = ["source.tart-cli.tart"]
}
```

## VZ boot-policy caveat

Inside a Virtualization.framework guest, `csrutil enable` gives real SIP enforcement: the setting
persists in NVRAM (tart's `nvram.bin`) and the kernel honors it as on bare metal. What does *not*
transfer is the Apple-silicon **Startup Security Utility / Full Security** boot-policy model — VZ
guests are not signature-gated the way a physical Mac is. SIP-on is real; guest boot-policy
hardening is largely not a VZ concept, so expect nothing beyond what SIP itself enforces.
