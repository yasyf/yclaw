# Deploying yclaw

Bring the whole stack up from a bare Apple Silicon Mac with one wizard, clear the
human gates that can't be scripted, and back up the irreplaceable state. This is
the shortest correct path for an operator who already has the repo cloned.

## Prerequisites

- An **Apple Silicon** Mac with the RAM headroom for the 35B MLX model
  (`unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit`). The model plane runs on the **host** now, not in a
  guest: the host's `rapid-mlx` activator loads the model on the first request — the model
  child holds ~20 GB while awake — and unloads it after 30 minutes idle, so the host
  reclaims that RAM between conversations. `metal` is a small **relay/credential**
  node (2 vCPU / 8 GB): its `rapid-mlx`/`mlx-audio` daemons relay to the host and serve nothing
  themselves. On a smaller Mac, point `qwen` in `nixos/models.nix` at a smaller model.
- Host tooling on `PATH`: `tart`, `tailscale`, `gum`, `packer`, `restic`, plus
  `age-keygen`, `sops`, `openssl`, `jq`, `python3`, `security`, `rsync`, `curl`,
  and `nix` (the hermes image builds inside a Linux builder VM). `just bootstrap`
  preflights all of them and stops if one is missing.
- Disk headroom: the model cache is ~20–25 GB, and the guest VM disks are `metal`
  200 GB and `bluebubbles` ~68 GB. hermes now ships as an Apple `container` OCI image
  built by `nix`, not a VM disk.
- A dedicated Apple ID for iMessage and a Tailscale tailnet the host already belongs to.
  (Both macOS guests clone digest-pinned cirruslabs Tahoe base images — `metal` the SIP-on
  `macos-tahoe-vanilla`, `bluebubbles` the SIP-off `macos-tahoe-base` — so no operator-supplied
  IPSW is needed.)
- **A Tailscale OAuth client, set up before bootstrap.** `collect_secrets` no longer
  takes one reusable auth key; it mints a fresh persistent, single-use, tagged key per
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
  is short-lived (~1h); each minted key is single-use with a 24h redemption window
  (`expirySeconds`), redeemed at that node's first boot. The nodes are **persistent**
  (non-ephemeral) and tagged — tagged devices have key-expiry disabled by default — so they
  keep their registration across a reboot, sleep, or network blip and reconnect from on-disk
  tailscaled state with no re-auth. That is what stops the always-on stack from being stranded
  off the tailnet. Because a persistent node no longer self-reaps, teardown (`just destroy` /
  `nuke`) deletes the old device registrations explicitly (`scripts/nuke-tailnet.sh`).

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
   short-lived access token and mints one persistent, single-use, tagged auth key per
   node, so each guest joins the tailnet under its own `tag:<node>`.
4. **Assemble the hermes container config** at `~/.config/yclaw/vm-secrets`:
   hermes's `hosts/hermes/{key.txt,secrets.sops.yaml}` staged in as `key.txt` and
   `secrets.sops.yaml`, plus a `node.env` carrying the non-secret BlueBubbles
   allowlist and home channel. The hermes container bind-mounts these read-only at
   runtime and the entrypoint decrypts the bundle in-container. metal reads its own
   `hosts/metal/` over a narrow read-only share.
5. **Apply the host config** by running `scripts/setup.sh` — Homebrew tooling,
   `~/.yclaw/state`, and the `com.yclaw.tart-*` launchd runners.
6. **Build the macOS guests** (`metal`, then `bluebubbles`) with Packer, feeding
   inputs as `PKR_VAR_*` exports sourced from the yclaw keychain, then kickstarts
   their launchd agents to boot them.
7. **Stage the hermes container secrets.** With metal up, it mints a per-host
   agent-vault proxy token (`agent rotate hermes --token-only` over `tailscale ssh`)
   and stages it into the hermes container config, and fetches the agent-vault MITM CA
   from `http://metal:14321/v1/mitm/ca.pem` (retrying until metal answers). The
   entrypoint builds `HTTPS_PROXY` from the token when the container starts.

When the autonomous steps finish, the wizard prints the human gates — including the
gated hermes container bring-up in the next section — and stops cleanly.

## Bring up the hermes container

hermes runs as an Apple `container`, not a `tart` VM, and `apple/container` has no
boot-autostart or restart verb, so bring-up is a deliberate, root-assisted step the
unattended wizard does not run. Do it once, in order:

1. **Build and load the image.** Build the OCI image from the same
   `nixosConfigurations.hermes` the settings live in, then load it into `container`:

   ```sh
   ./scripts/build-container-image.sh hermes-container-image hermes-agent:latest
   ```

2. **Author the supervisor and egress firewall.** `host-container` stages the
   container's secrets, builds the `hermes-docker-proxy`, and writes the
   `com.yclaw.container-hermes` supervisor and the `com.yclaw.container-pf-refresh`
   egress-`pf` daemon without loading them:

   ```sh
   ./scripts/setup.sh host-container
   ```

3. **Load the supervisor and egress firewall.** The previous step prints these two
   lines; run them to start the supervisor and the egress `pf` daemon:

   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yclaw.container-hermes.plist
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.yclaw.container-pf-refresh.plist
   ```

   The supervisor creates the `hermes` container on its first tick, then keeps it alive
   — it ticks every 60 s and recreates the container whenever it is absent.

4. **Seed the agent identity.** The image ships no `hermes-onboard` step; the agent
   reads its identity from the bind-mounted state dir. Write your profile (`USER.md`) and
   the agent persona (`SOUL.md`) into `~/.yclaw/state/hermes/.hermes/` on the host — the
   container sees them at `/var/lib/hermes/.hermes/` — then confirm the gate:

   ```sh
   uv run yclaw onboard --gate hermes-identity
   ```

## Clear the human gates

These are one-time interactive steps the wizard can't perform. Run the onboarding
TUI, which drives them all in order, idempotently (already-done gates are skipped),
inside a zellij session:

```sh
just onboard
```

It surfaces the Tailscale SSH re-auth URL, runs the two cli-proxy logins in their own
panes, connects Google OAuth, and walks the Apple-ID bring-up — then runs
`just validate` and `just smoke`. The manual equivalents below are the reference for
what each gate does. The hermes agent identity is seeded separately, during the
container bring-up above.

1. **Apple-ID iMessage sign-in (2FA) on `bluebubbles`** — the one irreducibly-human
   step. The image already ships BlueBubbles.app (from a pinned, sha256-verified GitHub
   release DMG — there is no Homebrew cask) with library validation disabled, so the
   Private-API helper can inject into Messages. Sign in with the dedicated Apple ID,
   complete 2FA, enable iMessage, then run `scripts/bluebubbles-setup.sh` on the
   `bluebubbles` guest. It seeds the server config in `config.db` (BlueBubbles ignores
   `config.json`), auto-grants the BlueBubbles GUI permissions (Full Disk Access +
   Accessibility in the system TCC db, possible because the guest is SIP-off), installs a
   launch-at-login agent so Messages + BlueBubbles come back up after a reboot, and
   auto-disables Screen Sharing once the server is healthy. If it prints a HUMAN FALLBACK,
   finish those GUI grants over Screen Sharing, then run `just bb-harden`. `bluebubbles`
   enrollment is still a manual `tailscale up`, and it must advertise its tag:
   `tailscale up --advertise-tags=tag:bluebubbles`.
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
host's regular Hugging Face cache (`~/.cache/huggingface/hub`), and the host's `rapid-mlx`
activator reads it directly via `HF_HUB_CACHE`. metal no longer mounts a model-cache share; it
relays model requests to the host instead of serving them.

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
guests over virtiofs and bind-mounted into the hermes container. Writes pass through
to the host, so the state survives destroying and rebuilding a VM or recreating the
container.

| Path | Holds | Replaceable? |
|------|-------|--------------|
| `hosts/<host>/key.txt` | that host's private age decryption key (one per host) | **No** — lose it and that host's secrets are unrecoverable |
| `hosts/<host>/secrets.sops.yaml` | that host's encrypted bundle (only its own secrets, per `nixos/secrets-manifest.json`) | **No** (without that host's key) |
| `agent-vault/` | credential-broker DB: owner account, static keys, the Google OAuth refresh token, minted agent tokens | **No** — re-provisioning re-mints tokens hermes would need re-injected |
| `cli-proxy-api/auth/` | Codex/Gemini OAuth sessions | Yes — re-run the `--login` flows |
| `stt/` | the host STT venv | Yes — rebuilt by `setup.sh host-serving` |
| `hermes/` | hermes agent state (honcho memory, sessions), bind-mounted into the container at `/var/lib/hermes` | **No** — agent memory and sessions survive only via this bind mount |
| `hermes-ts-state/` | the hermes container's tailnet identity, bind-mounted at `/var/lib/tailscale` | **No** — losing it forces a re-mint and re-auth of the `hermes` node |

The **irreplaceable** set is small: everything under `hosts/` (every per-host key
and bundle) and `agent-vault/`.

## Back up and restore

`just backup` wraps restic, skipping the large regenerable caches (`hf/`,
`stt/`). Set the repo and password first — `YCLAW_RESTIC_REPO` is a B2/S3
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

## Script library and manifest

Every `just` recipe stays thin; the logic lives in `scripts/`, built on the
shared library in `scripts/lib/`:

- `common.sh` — logging (`log`/`warn`/`die`), the `need` tool preflight, the
  build-mirror rsync.
- `manifest.sh` — `manifest_get` / `manifest_list` / `manifest_has` over
  `machines.json`, the canonical fleet manifest (machines, services, ports, log
  paths, shares, keychain names, debloat lists). Change a fleet fact there, not
  in a script.
- `wait.sh` — the one blessed set of bounded, fail-loud polling helpers. It is
  self-contained on purpose: host scripts source it, `darwin/metal.nix` embeds
  it into the launchd wrappers, packer ships it into the image, and `guest_pipe`
  pipes it into guests.
- `ssh.sh` — `ts_run` (exactly one command string per `tailscale ssh`) and
  `guest_pipe` (ships `wait.sh` + `pf.sh` + a manifest prelude + secret env to a
  guest over stdin, so secrets never hit argv).
- `launchd.sh` — `bootout_drain` and the runner reload helpers.
- `pf.sh` — `install_pf_anchor`, targeted `pfctl -a <name> -f` loads only
  (a full `/etc/pf.conf` reload flushes the vmnet NAT anchors the VMs need).
- `secrets.sh` — the keychain and per-host sops-bundle module.

For day-to-day poking, the `yclaw` CLI wraps the same manifest:
`uv run yclaw status` is the quick fleet check, and `uv run yclaw doctor`
adds the hardening probes.

## Host model serving and lockdown

The model plane lives on the host: `rapid-mlx` on `:8000` and the `stt` transcription
service on `:8765`, each behind its own idle-unload activator (`stt` wakes
`athome serve stt` — a transcribe.cpp Parakeet — on the first request). `just bootstrap`
installs the whole stack as part of its host-config step (the full `scripts/setup.sh` run
downloads the models and loads the `com.yclaw.{rapid-mlx,stt}` LaunchAgents), so a first
deploy needs nothing here. The
commands below maintain and lock down that plane afterward.

**Refresh the serving stack in place.** Re-run only the host-serving section — rebuild the
pinned `rapid-mlx`/`stt` venvs when absent, refresh the wrapper scripts and their
LaunchAgents, and re-download the STT model — without bouncing the live tart VM runners:

```sh
bash scripts/setup.sh host-serving
```

**Lock down the host model ports.** Install the host pf anchor (`com.apple/000.yclaw.host`) and
its refresh LaunchDaemon so only `metal` reaches `:8000`/`:8765` and no fleet VM reaches anything
else on the host — over the tailnet or through the vmnet side-door. This writes to
`/etc/pf.anchors` and `/Library/LaunchDaemons`, so it runs as root and is **not** part of the
full `setup.sh` run: it backstops the hand-applied tailnet ACL and stays operator-gated the same
way. `sudo` resets `PATH`, so pass the resolved `tailscale` binary in:

```sh
sudo TAILSCALE="$(command -v tailscale)" bash scripts/setup.sh host-pf
```

It runs one pf tick synchronously — the anchor is in force when the command returns — then prints
an apply-time verification block: the model plane passes over the tailnet while the vmnet and LAN
side-doors block.

**Resize a live metal guest.** metal is provisioned at 2 vCPU / 8 GB, but a guest built before
the model plane moved to the host still carries the old 10 vCPU / 48 GB footprint and the retired
`hfhub`/`mlxaudio` shares — the Packer literals only affect fresh image builds, never the live
VM. Shrink it in place from Terminal.app (gui-domain launchd; no sudo, no keychain):

```sh
just resize-metal
```

It boots out the runner, runs `tart set metal --cpu 2 --memory 8192 --display 800x600`, rewrites the
`com.yclaw.tart-metal` LaunchAgent with the reduced four-share set
(`metalsecrets`, `agentvault`, `cliproxy`, `repo`), kickstarts it, and waits for metal to answer
over `tailscale ssh`.

## Redeploy

`just redeploy [node]` (`scripts/redeploy.sh <host|metal|hermes|bluebubbles|all>`,
defaulting to `all`) pushes a config change to the running stack **in place**: every
node keeps its identity and persistent state, nothing disk-replaces, and no step needs
human input. One path per node:

- **host** — re-applies the host config (`scripts/setup.sh`): Homebrew tooling and the
  `com.yclaw.tart-*` launchd runners.
- **metal** — runs `metal-redeploy` in the guest (`darwin-rebuild switch`); the relay
  daemons restart and node identity survives.
- **hermes** — a container reload. `./scripts/redeploy.sh hermes` force-removes the
  `hermes` container (`container rm -f hermes`) and the `com.yclaw.container-hermes`
  supervisor recreates it from the current `hermes-agent:latest` image on its next tick;
  the bind-mounted state and tailnet identity survive, so node identity and agent memory
  persist. Config lives in the image, so to ship a change rebuild and reload the image
  first (`./scripts/build-container-image.sh hermes-container-image hermes-agent:latest`),
  then redeploy.
- **bluebubbles** — `scripts/bluebubbles-setup.sh reconfigure` in the guest; re-seeds
  `config.db` (a brief BlueBubbles restart) and never touches the iMessage session on the
  VM disk.

> **The BlueBubbles iMessage session is a single point of failure.** It lives only on the
> `bluebubbles` VM disk. Redeploy never touches that disk, so the session survives a
> redeploy — but it is **not** covered by `just backup`, which only snapshots
> `~/.yclaw/state`. A scoped virtiofs mount for the session is infeasible: SQLite-WAL does
> not work over a network/virtiofs filesystem, imagent's sandbox resolves symlinks before
> path-matching, and the IDS registration is bound to the guest's hardware identity plus a
> SEP-wrapped keychain. The workable backup — identity-pin the guest (`machineIdentifier`
> + NVRAM/`auxiliaryStorage` + `hardwareModel`) and snapshot the whole disk on the same
> host — is a deferred follow-up.

> **A metal redeploy can silently reapply stale repo-share files.** The guest's virtiofs cache
> pins files it read from the repo share earlier in the same boot, so `just redeploy metal` run
> right after you edit those files applies the pre-edit tree. Reboot the guest first
> (`yclaw ssh metal reboot`), then redeploy, and confirm the switch prints `reloading service …`
> lines — that output is the proof it picked up the change.

### Verifying a metal change (reboot gate)

metal's daemons only prove themselves across a cold boot — the /nix mount race,
the virtiofs automount, and the sops decrypt all happen at boot, not at
`darwin-rebuild switch`. Gate any change to metal's boot path on this battery:

1. `just redeploy metal`, then confirm the node stays online:
   `uv run yclaw status metal`.
2. Reboot the guest: `tailscale ssh root@metal -- reboot`. Expect it back on
   the tailnet in ~25 s (`uv run yclaw wait ssh metal`).
3. Run the daemon battery on the rebooted guest:
   - every `org.nixos.*` daemon is running: `launchctl print system/org.nixos.rapid-mlx`
     (and the rest of the labels in `machines.json`) — on metal, `rapid-mlx` and `mlx-audio`
     are now socat relays to the host, not model servers;
   - the relay reaches the host end to end: `uv run yclaw doctor hermes --live` runs a
     cross-container fetch of `http://metal:8000/v1/models` and reports it served by the
     host's `rapid-mlx` activator — nothing loads in-guest, and the first request after an
     idle unload warms the model on the host, so allow a generous timeout;
   - the provision oneshot's last exit was 0;
   - agent-vault answers: `curl -fs http://127.0.0.1:14321/health` (from the
     guest) — or `uv run yclaw status metal` from the host, which probes every
     service's manifest health check;
   - the mint helper works: `tailscale ssh root@metal --
     /run/current-system/sw/bin/metal-mint-hermes-token` returns a token.
4. Repeat steps 2–3 for a **second** reboot before deleting any boot-path
   mechanism (a wait, a guard, a KeepAlive) — one clean boot can be luck.

## Operator actions not automated

- **Rotate the Tailscale API key** kept in the gitignored `.env` before going
  public.
