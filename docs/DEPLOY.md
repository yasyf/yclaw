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
- **A Tailscale OAuth client, set up before bootstrap.** `collect_secrets` no longer
  takes one reusable auth key; it mints a fresh ephemeral, single-use, tagged key per
  node from an OAuth client (stored in the yclaw keychain as `yclaw-ts-oauth-client-id`
  and `yclaw-ts-oauth-client-secret`). Two steps, in order:
  1. **Add the yclaw tags to the ACL.** `tailnet/policy.hujson` is the reference for the
     `tag:hermes`/`tag:metal`/`tag:bluebubbles` `tagOwners` + an admin-SSH rule. If the
     tailnet is **dedicated** to yclaw, you can apply the whole file. If it is **shared**
     with other nodes (the common case), add only that block **additively** — replacing the
     whole policy with the default-deny file would deauthorize your other tagged nodes.
     There is no CI workflow for this (a force-replace workflow is unsafe on a shared
     tailnet); apply it by hand in the admin console or via the Tailscale API. The full
     default-deny east-west lockdown only takes effect on a tailnet where every node has an
     explicit grant — see `docs/SECURITY-HANDOFF.md`.
  2. **Create an OAuth client** with the `auth_keys` write scope that owns those three
     tags (their `tagOwners` already list `autogroup:admin`). Supply its id and secret at
     the first `just bootstrap` prompt.

  Order matters: the ACL and `tagOwners` must exist before the first node advertises its
  tag, or `tailscale up --advertise-tags=tag:<node>` is rejected. The OAuth access token
  is short-lived (~1h); the minted node keys live two hours (`expirySeconds`) and are
  redeemed at each node's first boot.

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
3. **Mint the per-host age keys and encrypt the secrets.** `collect_secrets` mints
   (or reuses) one age key per host, generates the Aperture static key plus the per-VM
   admin passwords and the BlueBubbles server password into the dedicated yclaw
   keychain (`~/Library/Keychains/yclaw.keychain-db`), and writes each host's own
   encrypted bundle at `~/.yclaw/state/hosts/<host>/secrets.sops.yaml` — encrypted
   only to that host's recipient and carrying only that host's secrets, per
   `nixos/secrets-manifest.json`. The host persists no age key of its own; each VM
   decrypts only what it owns. It also exchanges the Tailscale OAuth client for a
   short-lived access token and mints one ephemeral, single-use, tagged auth key per
   node, so each guest joins the tailnet under its own `tag:<node>`.
4. **Assemble the hermes node-config share** at `~/.config/yclaw/vm-secrets`:
   hermes's `hosts/hermes/{key.txt,secrets.sops.yaml}` staged in as `key.txt` and
   `secrets.sops.yaml`, plus a `node.env` carrying the non-secret BlueBubbles
   allowlist and home channel. `seedNodeConfig` installs these into the guest on
   first boot. metal reads its own `hosts/metal/` over a narrow read-only share.
5. **Apply the host config** by running `scripts/setup.sh` — Homebrew tooling,
   `~/.yclaw/state`, and the `com.yclaw.tart-*` launchd runners.
6. **Build the macOS guests** (`metal`, then `bluebubbles`) with Packer, feeding
   inputs as `PKR_VAR_*` exports sourced from the yclaw keychain, then kickstarts
   their launchd agents to boot them.
7. **Build the hermes image.** It fetches the real agent-vault MITM CA from
   `http://metal:14321/v1/mitm/ca.pem` (retrying until metal is up), writes it
   into a gitignored `.build/` copy of the repo, builds the image from there
   (the tracked tree stays clean), and disk-replaces it into the `hermes` tart VM.
   With metal up, it also mints a per-host agent-vault proxy token
   (`agent rotate hermes --token-only` over `tailscale ssh`) and stages it into the
   `hermes` node-config share; `hermes` builds `HTTPS_PROXY` from it on first boot, so
   the credential-injection plane comes up working — brokered calls no longer 407.
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
   `scripts/bluebubbles-setup.sh` on the `bluebubbles` guest. `bluebubbles`
   enrollment is still a manual `tailscale up`, and it must now advertise its tag:
   `tailscale up --advertise-tags=tag:bluebubbles`.
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

## Validate and finish

Once the gates are clear, confirm the stack and close out the operator follow-ups:

- **Credential-injection plane.** A brokered tool call (Exa, Honcho, OpenAI) from
  `hermes` returns 200, not 407.
- **Code-exec sandbox.** `hermes` runs code under the gVisor `runsc` runtime —
  `docker info` shows `Default Runtime: runsc`.
- **Disable Screen Sharing on `bluebubbles`** once the one-time GUI bring-up is done
  and tailnet access works. Its VNC anchor is open to the LAN only for first-time
  bring-up; close it the way `metal` does:

  ```sh
  sudo launchctl disable system/com.apple.screensharing
  sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -deactivate -stop
  ```

## State layout

All host-resident persistent state lives under `~/.yclaw/state`, mounted into the
guests over virtiofs. The guests write through to the host, so the state survives
destroying and rebuilding a VM.

| Path | Holds | Replaceable? |
|------|-------|--------------|
| `hosts/<host>/key.txt` | that host's private age decryption key (one per host) | **No** — lose it and that host's secrets are unrecoverable |
| `hosts/<host>/secrets.sops.yaml` | that host's encrypted bundle (only its own secrets, per `nixos/secrets-manifest.json`) | **No** (without that host's key) |
| `agent-vault/` | credential-broker DB: owner account, static keys, the Google OAuth refresh token, minted agent tokens | **No** — re-provisioning re-mints tokens hermes would need re-injected |
| `cli-proxy-api/auth/` | Codex/Gemini OAuth sessions | Yes — re-run the `--login` flows |
| `hf/`, `omlx/` | model weights + KV cache (~20–25 GB) | Yes — re-downloaded on demand |
| `mlx-audio/` | the STT server venv | Yes — rebuilt on first STT start |
| `hermes/` | hermes agent state (honcho memory, sessions), externalized from the VM's `/var/lib/hermes` | **No** — agent memory and sessions survive only via this share |

The **irreplaceable** set is small: everything under `hosts/` (every per-host key
and bundle) and `agent-vault/`.

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

## Migrating an existing deployment

Older deployments were seeded with the single global age key and one monolithic
bundle. Seeding is idempotent — it writes only what's missing — so a plain rebuild
keeps the old artifacts and never picks up the new per-host keys. Migrate explicitly:

1. **Re-run secret collection** (`scripts/collect-secrets.sh`) to mint the per-host
   keypairs and bundles and the per-node tailnet keys. This needs the OAuth client
   from the prerequisites. The old artifacts under `~/.yclaw/state` —
   `age/key.txt`, the top-level `secrets.sops.yaml`, and `vm-secrets/` — are no longer
   produced; remove them so a stale share source can't be re-mounted.
   - On `metal`, remove the stale `/var/lib/sops-nix/key.txt` and the old bundle before
     `darwin-rebuild`, so first boot re-seeds the per-host key.
   - `hermes` disk-replaces on deploy (root resets), so it re-seeds on the next
     `just deploy hermes`. Deploy with a boot-and-reboot cycle; `switch` hits a
     virtiofs remount quirk.
2. **Drop the host age key.** The host no longer keeps an age key at
   `/var/lib/sops-nix/key.txt`; that vestigial install was removed.

## Operator actions not automated

- **Rotate the Tailscale API key** kept in the gitignored `.env` before going
  public.
- **Remove host Nix once the stack is proven** by running
  `scripts/uninstall-nix.sh` (destructive — it reboots the host).
