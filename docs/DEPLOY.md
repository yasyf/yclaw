# Deploying yclaw

> Status: implementation in progress. The high-level flow below is the target;
> detailed steps are TBD as implementation lands.

## Deploy flow

1. **Run the setup flow.** It prompts for the human-supplied values and writes
   the per-user, non-secret config to `~/.yclaw/config.toml`.
2. **Collect secrets.** The flow mints and sops-encrypts the runtime secrets into
   `~/.yclaw/state` (`age/key.txt`, `secrets.sops.yaml`); nothing secret is
   committed to the repo.
3. **Build or pull images.** The metal (nix-darwin) guest is built locally; the
   hermes (NixOS) gateway image is built in CI and pulled.
4. **Boot the VMs.** tart launches the metal and hermes guests; each joins the
   tailnet as its own node.
5. **Clear the human gates.** Finish the one-time interactive steps that cannot
   be scripted: the locked-down-guest setup, the BlueBubbles Apple-ID sign-in,
   and the Codex/Gemini browser logins.

## What to back up

Back up `~/.yclaw/state` — it holds the only irreplaceable material. Two files
matter most:

- `age/key.txt` — the master decryption key. Lose it and every encrypted secret
  is unrecoverable.
- `secrets.sops.yaml` — the encrypted secret blob.

A `just backup` target is planned to automate this; backups are deferred for now.
