# Deploying yclaw

> Status: implementation in progress. The high-level flow below is the target;
> detailed steps are TBD as implementation lands.

## Deploy flow

1. **Run the setup flow.** It prompts for the human-supplied values and writes
   the per-user, non-secret config to `~/.yclaw/config.toml`.
2. **Collect secrets.** The flow mints and sops-encrypts the runtime secrets into
   `~/.yclaw/state` (`age/key.txt`, `secrets.sops.yaml`); nothing secret is
   committed to the repo.
3. **Build or pull images.** The metal (nix-darwin) guest is built locally from a
   pinned IPSW via Packer; the bluebubbles macOS base is cloned from the cirruslabs
   SIP-off base (`ghcr.io/cirruslabs/macos-tahoe-base`) and provisioned via Packer;
   the hermes (NixOS) gateway image is built with `tart --nested` or in CI and pulled.

   Each macOS guest bakes a per-VM admin password that step 2 random-generated into the
   dedicated yclaw keychain (`$HOME/Library/Keychains/yclaw.keychain-db`): `yclaw-metal-admin-pass`
   for metal and `yclaw-bluebubbles-admin-pass` for bluebubbles. Unlock the dedicated keychain
   (its password lives in the login keychain under `yclaw-keychain-password`), then source each
   per-VM password from it into the env before that VM's Packer build so the password is never
   prompted or hardcoded:

   ```sh
   KC="$HOME/Library/Keychains/yclaw.keychain-db"
   security unlock-keychain -p "$(security find-generic-password -a "$USER" -s yclaw-keychain-password -w)" "$KC"

   export PKR_VAR_vm_admin_pass="$(security find-generic-password -a "$USER" -s yclaw-metal-admin-pass -w "$KC")"
   packer build packer/metal.pkr.hcl

   export PKR_VAR_vm_admin_pass="$(security find-generic-password -a "$USER" -s yclaw-bluebubbles-admin-pass -w "$KC")"
   packer build packer/bluebubbles.pkr.hcl
   ```

   The packer `vm_admin_pass` variable defaults to the `@@VM_ADMIN_PASS@@` placeholder, so a
   build that forgets the export bakes the literal placeholder (fail-loud) instead of a real
   credential.
4. **Boot the VMs.** tart launches the metal, bluebubbles, and hermes guests;
   each joins the tailnet as its own node.
5. **Clear the human gates.** Finish the one-time interactive steps that cannot
   be scripted: the BlueBubbles Apple-ID iMessage sign-in (2FA) on the bluebubbles
   guest, the Codex/Gemini browser logins on metal, and the agent-vault Google
   OAuth consent on metal. Neither guest needs a SIP recovery step: metal is
   SIP-on from its fresh IPSW install, and bluebubbles is SIP-off because it is
   cloned from the cirruslabs SIP-disabled base.

## State layout

All host-resident, persistent state lives under `~/.yclaw/state`, mounted into the
metal guest over virtiofs (`--dir=state:…`). The guest writes through to the host, so
the state survives destroying and rebuilding the VM:

| Path | Holds | Replaceable? |
|------|-------|--------------|
| `age/key.txt` | master age decryption key | **No** — lose it and every secret is unrecoverable |
| `secrets.sops.yaml` | the encrypted secret blob | **No** (without the age key) |
| `agent-vault/` | the credential-broker DB: owner account, static keys, the Google OAuth refresh token, minted agent tokens | **No** — re-provisioning re-mints tokens hermes would need re-injected |
| `cli-proxy-api/auth/` | Codex/Gemini OAuth sessions | Yes — re-run the `--login` flows |
| `hf/`, `omlx/` | model weights + KV cache (~20 GB) | Yes — re-downloaded on demand |
| `mlx-audio/venv` | the STT server venv | Yes — rebuilt on first STT start |
| `values.env` | resolved non-secret config | Yes — re-derived by setup |

The **irreplaceable** set is small: `age/key.txt`, `secrets.sops.yaml`, `agent-vault/`.

> The hermes gateway's own agent state (honcho memory, sessions in the VM's
> `/var/lib/hermes`) is **inside the hermes VM**, not on `~/.yclaw/state` yet —
> externalizing it via a virtiofs bind is a tracked follow-up. Everything sensitive
> (credentials, OAuth, secrets) is already on the host.

## What to back up

Back up `~/.yclaw/state` (excluding the large, regenerable caches). The
`just backup` target wraps restic; backups are otherwise deferred:

```sh
just backup            # restic backup of ~/.yclaw/state -> $YCLAW_RESTIC_REPO
```

Set `YCLAW_RESTIC_REPO` (e.g. a Backblaze B2 / S3 bucket or a local/NAS path) and
`RESTIC_PASSWORD` first. To restore on a fresh host: install restic, `restic restore
latest --target ~/.yclaw/state`, then run `just setup`.
