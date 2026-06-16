# Disable SIP on the bluebubbles VM

> **HUMAN gate.** This step runs in macOS recovery mode and cannot be scripted. The bluebubbles VM
> needs [System Integrity Protection](https://support.apple.com/en-us/102149) off so BlueBubbles can
> load its private iMessage extension (the Private API helper). SIP stays **on** for every other node.

## When

After the macOS base image boots for the first time (`just build-images` produces it from
`packer/bluebubbles.pkr.hcl`) and before running `scripts/bluebubbles-setup.sh`.

## Steps

1. Boot the VM into recovery mode:

   ```bash
   tart run bluebubbles --recovery-mode
   ```

2. In the recovery menu open **Utilities → Terminal** and disable SIP:

   ```bash
   csrutil disable
   ```

3. Reboot:

   ```bash
   reboot
   ```

4. Confirm SIP is off once the VM is back up (over `tailscale ssh` or VNC):

   ```bash
   csrutil status   # expect: "System Integrity Protection status: disabled."
   ```

`bluebubbles-setup.sh` checks `csrutil status` and **fails loud** if SIP is still enabled, so a
forgotten disable surfaces immediately rather than silently breaking the Private API helper.
