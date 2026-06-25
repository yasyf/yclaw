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
- A dedicated Apple ID for iMessage and a Tailscale tailnet the host already belongs to.
  (Both macOS guests clone digest-pinned cirruslabs Tahoe base images — `metal` the SIP-on
  `macos-tahoe-vanilla`, `bluebubbles` the SIP-off `macos-tahoe-base` — so no operator-supplied
  IPSW is needed.)
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
     explicit grant.
  2. **Create an OAuth client** with the `auth_keys` write scope that owns those three
     tags (their `tagOwners` already list `autogroup:admin`). Supply its id and secret at
     the first `just bootstrap` prompt.

  Order matters: the ACL and `tagOwners` must exist before the first node advertises its
  tag, or `tailscale up --advertise-tags=tag:<node>` is rejected. The OAuth access token
  is short-lived (~1h); the minted node keys live two hours (`expirySeconds`) and are
  redeemed at each node's first boot.

First boot is **long** — hours. It pulls the cirruslabs base images, builds the
guests, and pulls the model weights.

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
   asks for `HOST_RAM` (the GB tier for VM sizing) and `AUTHORIZED_HANDLES` (the
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
   tailscale ssh admin@hermes -- sudo -u hermes -H hermes-onboard
   ```

When the autonomous steps finish, the wizard prints the human gates and stops
cleanly.

## Clear the human gates

These are one-time interactive steps the wizard can't perform. Run the onboarding
TUI, which drives them all in order, idempotently (already-done gates are skipped),
inside a zellij session:

```sh
just onboard
```

It surfaces the Tailscale SSH re-auth URL, seeds the hermes identity, runs the two
cli-proxy logins in their own panes, connects Google OAuth, and walks the Apple-ID
bring-up — then runs `just validate` and `just smoke`. The manual equivalents below
are the reference for what each gate does.

1. **Apple-ID iMessage sign-in (2FA) on `bluebubbles`** — the one irreducibly-human
   step. Sign in with the dedicated Apple ID, complete 2FA, enable iMessage, then run
   `scripts/bluebubbles-setup.sh` on the `bluebubbles` guest. It auto-grants the
   BlueBubbles GUI permissions (Full Disk Access + Accessibility, possible because the
   guest is SIP-off) and auto-disables Screen Sharing once the server is healthy; if it
   prints a HUMAN FALLBACK, finish those GUI grants over Screen Sharing, then run
   `just bb-harden`. `bluebubbles` enrollment is still a manual `tailscale up`, and it
   must advertise its tag: `tailscale up --advertise-tags=tag:bluebubbles`.
2. **CLIProxyAPI Codex login on `metal`** (browser flow). `--no-browser` prints a URL
   you approve in any browser; the redirect to `localhost:1455` fails to load, so copy
   the full URL from the address bar and paste it back (the paste prompt arms after
   ~15s) — no SSH tunnel needed:

   ```sh
   cli-proxy-api --codex-login --no-browser
   ```

3. **CLIProxyAPI Gemini login on `metal`** (browser flow — the flag is `--login`,
   not `--gemini-login`). `--login --no-browser` has **no paste fallback** unless you
   pass `--project_id`, so its `localhost:8085` callback must be reachable; `just onboard`
   forwards it over `ssh -L`. By hand, run the login on `metal` with the port forwarded
   from where your browser is:

   ```sh
   ssh -L 8085:127.0.0.1:8085 root@metal -- cli-proxy-api --login --no-browser
   ```

4. **agent-vault Google OAuth connect** (run on the host):

   ```sh
   ./scripts/connect-google-oauth.py
   ```

   Open the printed consent URL, approve, and it finishes and verifies.

The Qwen MLX model is no longer a gate — `just bootstrap` auto-downloads it into the
host's regular Hugging Face cache (`~/.cache/huggingface/hub`), which `metal` mounts as
the `hfhub` share and serves via `HF_HUB_CACHE`.

`metal` clones the SIP-on cirruslabs `macos-tahoe-vanilla` base and `bluebubbles` the
SIP-off `macos-tahoe-base`, so neither guest needs a SIP recovery step.

## Validate and finish

Once the gates are clear, confirm the stack and close out the operator follow-ups:

- **Run the hardening probe.** `just validate` (on the host, with the VMs up) exercises
  the per-VM isolation + audit controls over `tailscale ssh` and reports PASS/FAIL.
- **Credential-injection plane.** A brokered tool call (Exa, Honcho, OpenAI) from
  `hermes` returns 200, not 407.
- **Code-exec sandbox.** `hermes` runs code under the gVisor `runsc` runtime —
  `docker info` shows `Default Runtime: runsc`.
- **Screen Sharing on `bluebubbles`** is disabled automatically by
  `scripts/bluebubbles-setup.sh` once BlueBubbles is healthy. If you completed the GUI
  grants via the fallback, run `just bb-harden` to disable it.

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

## Redeploy

`just redeploy [node]` (`scripts/redeploy.sh <host|metal|hermes|bluebubbles|all>`,
defaulting to `all`) pushes a config change to the running stack **in place**: every
node keeps its identity and persistent state, nothing disk-replaces, and no step needs
human input. One path per node:

- **host** — re-applies the host config (`scripts/setup.sh`): Homebrew tooling and the
  `com.yclaw.tart-*` launchd runners.
- **metal** — runs `metal-redeploy` in the guest (`darwin-rebuild switch`); the MLX
  services restart and the model-cache shares stay mounted.
- **hermes** — in-guest `nixos-rebuild switch` against `/var/lib/yclaw-repo#hermes`
  (the read-only repo share); node identity and `/var/lib/hermes` survive. Gated by a
  `nixos-rebuild dry-activate`: a code deploy leaves the `var-lib-hermes`/`var-lib-tailscale`
  virtiofs mounts untouched, but a change that would (re)mount a virtiofs tag mid-session hits
  Apple's tag re-enumeration limit (`virtio-fs: tag not found`), so the gate auto-routes those
  to the disk-replace fallback instead.
- **bluebubbles** — `scripts/bluebubbles-setup.sh reconfigure` in the guest; re-applies
  the server config and never touches the iMessage session on the VM disk.

> **The BlueBubbles iMessage session is a single point of failure.** It lives only on the
> `bluebubbles` VM disk. Redeploy never touches that disk, so the session survives a
> redeploy — but it is **not** covered by `just backup`, which only snapshots
> `~/.yclaw/state`. A scoped virtiofs mount for the session is infeasible: SQLite-WAL does
> not work over a network/virtiofs filesystem, imagent's sandbox resolves symlinks before
> path-matching, and the IDS registration is bound to the guest's hardware identity plus a
> SEP-wrapped keychain. The workable backup — identity-pin the guest (`machineIdentifier`
> + NVRAM/`auxiliaryStorage` + `hardwareModel`) and snapshot the whole disk on the same
> host — is a deferred follow-up.

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
   - `hermes` redeploys **in place** via in-guest `nixos-rebuild switch`, so it does not
     re-seed the per-host key (no disk-replace; node identity and `/var/lib/hermes` are
     preserved). A live `switch` is safe ONLY while it leaves the virtiofs mounts untouched:
     Apple's Virtualization.framework cannot re-enumerate a virtiofs tag once it is unmounted
     mid-session (`virtio-fs: tag not found`), so a `switch` that would start/stop/restart
     `var-lib-hermes.mount` or `var-lib-tailscale.mount` strands the mount and blocks
     `hermes-agent`. `scripts/redeploy.sh` reads `nixos-rebuild dry-activate` and auto-routes
     exactly those cases to the disk-replace fallback. Re-seeding the per-host key is one such
     reboot-class change, so migrate hermes with the fallback (`scripts/deploy-vm.sh`): it
     resets root and re-seeds on first boot.
2. **Drop the host age key.** The host no longer keeps an age key at
   `/var/lib/sops-nix/key.txt`; that vestigial install was removed.

## Operator actions not automated

- **Rotate the Tailscale API key** kept in the gitignored `.env` before going
  public.
- **Remove host Nix once the stack is proven** by running
  `scripts/uninstall-nix.sh` (destructive — it reboots the host).
