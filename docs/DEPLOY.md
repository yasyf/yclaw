# Deploying yclaw

Bring the whole stack up from a bare Apple Silicon Mac with one wizard, clear the
human gates that can't be scripted, and back up the irreplaceable state. This is
the shortest correct path for an operator who already has the repo cloned.

## Prerequisites

- An **Apple Silicon** Mac. `metal` is sized for the 35B MLX model (`unsloth--Qwen3.6-35B-A3B-UD-MLX-4bit`),
  which wires ~42 GB of GPU memory on a 48 GB-RAM guest. On a smaller Mac, point
  `qwen` in `nixos/models.nix` at a smaller model.
- Host tooling on `PATH`: `tart`, `tailscale`, `gum`, `packer`, `restic`, plus
  `age-keygen`, `sops`, `openssl`, `jq`, `python3`, `security`, `rsync`, `curl`,
  and `nix` (the hermes image builds inside a Linux builder VM). `just bootstrap`
  preflights all of them and stops if one is missing.
- Disk headroom: the model cache is ~20–25 GB, and the VM disks are `metal` 200 GB,
  `bluebubbles` ~68 GB, and `hermes` 64 GB.
- A pinned macOS Tahoe IPSW URL (or local path) for the `metal` build, a dedicated
  Apple ID for iMessage, and a Tailscale tailnet the host already belongs to.

First boot is **long** — hours. It downloads the IPSW, installs macOS into the
guest, and pulls the model weights.

## Run the wizard

`just bootstrap` (`scripts/bootstrap.sh`) is the single entrypoint. It's
idempotent: re-running prompts only for still-unset values, reuses the age key
and the generated keychain passwords, and rebuilds images in place.

```sh
just bootstrap
```

The wizard runs these stages autonomously:

1. **Preflight** the required host tools.
2. **Prompt for non-secret values.** It auto-detects `TAILNET_DOMAIN` from
   `tailscale status`, derives `GITHUB_OWNER` from your `origin` remote, and
   asks for `IPSW_URL` (HEAD-checked for reachability — a warning, not a hard
   fail), `HOST_RAM` (the GB tier for VM sizing), and `AUTHORIZED_HANDLES` (the
   comma-separated iMessage allowlist; the first handle is the home channel).
3. **Mint the age key and encrypt the secrets.** `collect_secrets` mints (or
   reuses) the master age key, generates the Aperture static key plus the per-VM
   admin passwords and the BlueBubbles server password into the dedicated yclaw
   keychain (`~/Library/Keychains/yclaw.keychain-db`), and writes the encrypted
   `~/.yclaw/state/secrets.sops.yaml`. It also stages the private key at
   `/var/lib/sops-nix/key.txt` (via `sudo install`) so sops-nix can read it.
4. **Assemble the hermes node-config share** at `~/.config/yclaw/vm-secrets`:
   `key.txt`, `secrets.sops.yaml`, and a `node.env` carrying the non-secret
   BlueBubbles allowlist and home channel. `seedNodeConfig` installs these into
   the guest on first boot.
5. **Apply the host config** by running `scripts/setup.sh` — Homebrew tooling,
   `~/.yclaw/state`, and the `com.yclaw.tart-*` launchd runners.
6. **Build the macOS guests** (`metal`, then `bluebubbles`) with Packer, feeding
   inputs as `PKR_VAR_*` exports sourced from the yclaw keychain, then kickstarts
   their launchd agents to boot them.
7. **Build the hermes image.** It fetches the real agent-vault MITM CA from
   `http://metal:14321/v1/mitm/ca.pem` (retrying until metal is up), writes it
   into a gitignored `.build/` copy of the repo, builds the image from there
   (the tracked tree stays clean), and disk-replaces it into the `hermes` tart VM.
8. **Boot hermes** by kickstarting `com.yclaw.tart-hermes`.
9. **Onboard.** Once `hermes` answers over `tailscale ssh`, the wizard launches the
   interactive `hermes-onboard` (as the `hermes` user): it seeds your profile
   (`USER.md`), the agent persona (`SOUL.md`), and the Honcho peer identity — the
   user-specific context the declarative build can't supply. It only writes files that
   are absent, so re-running is safe:

   ```sh
   tailscale ssh -t admin@hermes -- sudo -u hermes -H hermes-onboard
   ```

When the autonomous steps finish, the wizard prints the human gates and stops
cleanly.

## Clear the human gates

These are one-time interactive steps the wizard can't perform. Do them in order,
then verify.

1. **Apple-ID iMessage sign-in (2FA) on `bluebubbles`.** Sign in with the
   dedicated Apple ID, complete 2FA, enable iMessage, then run
   `scripts/bluebubbles-setup.sh` on the `bluebubbles` guest.
2. **CLIProxyAPI Codex login on `metal`** (browser flow):

   ```sh
   cli-proxy-api --codex-login
   ```

3. **CLIProxyAPI Gemini login on `metal`** (browser flow — the flag is `--login`,
   not `--gemini-login`):

   ```sh
   cli-proxy-api --login
   ```

4. **agent-vault Google OAuth connect** (run on the host):

   ```sh
   ./scripts/connect-google-oauth.py
   ```

   Open the printed consent URL, approve, and it finishes and verifies.

5. **Place the Qwen MLX model on `metal`.** Download it onto the `metal` `state`
   share (`/Volumes/My Shared Files/state/hf`):

   ```sh
   hf download "$(rg -o 'qwen = "[^"]+"' nixos/models.nix | sed -E 's/qwen = "(.*)"/\1/')"
   ```

`metal` is SIP-on from its fresh IPSW install and `bluebubbles` is SIP-off from
the cirruslabs base, so neither guest needs a SIP recovery step.

## State layout

All host-resident persistent state lives under `~/.yclaw/state`, mounted into the
guests over virtiofs. The guests write through to the host, so the state survives
destroying and rebuilding a VM.

| Path | Holds | Replaceable? |
|------|-------|--------------|
| `age/key.txt` | master age decryption key | **No** — lose it and every secret is unrecoverable |
| `secrets.sops.yaml` | the encrypted secret blob | **No** (without the age key) |
| `agent-vault/` | credential-broker DB: owner account, static keys, the Google OAuth refresh token, minted agent tokens | **No** — re-provisioning re-mints tokens hermes would need re-injected |
| `cli-proxy-api/auth/` | Codex/Gemini OAuth sessions | Yes — re-run the `--login` flows |
| `hf/`, `omlx/` | model weights + KV cache (~20–25 GB) | Yes — re-downloaded on demand |
| `mlx-audio/` | the STT server venv | Yes — rebuilt on first STT start |
| `hermes/` | hermes agent state (honcho memory, sessions), externalized from the VM's `/var/lib/hermes` | **No** — agent memory and sessions survive only via this share |

The **irreplaceable** set is small: `age/key.txt`, `secrets.sops.yaml`, and
`agent-vault/`.

## Back up and restore

`just backup` wraps restic, skipping the large regenerable caches (`hf/`, `omlx/`,
`mlx-audio/`). Set the repo and password first — `YCLAW_RESTIC_REPO` is a B2/S3
URL or a local/NAS path:

```sh
export YCLAW_RESTIC_REPO=...        # e.g. a B2/S3 bucket or a local/NAS path
export RESTIC_PASSWORD=...
just backup
```

To restore onto a fresh host, install restic, pull the snapshot, then re-apply
the host config:

```sh
restic restore latest --target ~/.yclaw/state
just setup
```

## Operator actions not automated

- **Rotate the Tailscale API key** kept in the gitignored `.env` before going
  public.
- **Remove host Nix once the stack is proven** by running
  `scripts/uninstall-nix.sh` (destructive — it reboots the host).
