# yclaw Architecture

yclaw runs the Nous `hermes-agent` always-on on Apple Silicon, reproducibly.
Every machine rebuilds from this repo, destroy-and-rebuild is the acceptance
test, and the agent is isolated in a Linux VM that never holds a credential.

## Topology

A bare macOS host boots two `tart` guests and one Apple `container` on one tailnet
and serves the model plane itself. The host stays lean: Homebrew provides `tart`,
Tailscale, `gum`, `packer`, and `restic`, and `scripts/setup.sh` supervises the two
macOS guests via `com.yclaw.tart-*` launchd agents and the hermes container via a
resident `com.yclaw.container-hermes` LaunchAgent, and installs the on-host serving
stack — the rapid-mlx activator and the mlx-audio STT server, detailed below. All persistent
state and secrets live outside the repo in `~/.yclaw/state`; generated passwords
live in a dedicated keychain at `~/Library/Keychains/yclaw.keychain-db`.

Every node is addressed by its bare Tailscale MagicDNS name, so an image is
generic until first boot stamps in a `node.env`. That keeps the built images free
of host-specific identity and lets the same artifact serve any tailnet.

- **metal** — the credential guest: a macOS node with SIP **on** and the OS
  maximally locked down, configured in-guest by nix-darwin
  (`darwinConfigurations.metal` / `darwin/metal.nix`). It is the sole credential
  custodian and holds no model weights — **no iMessage**. Four OpenAI-compatible
  services bind tailnet-only:
  - **rapid-mlx** (`:8000`) — a thin `socat` relay to the host's rapid-mlx
    activator; no model runs on metal.
  - **mlx-audio** (`:8765`) — a thin `socat` relay to the host's STT server.
  - **cliproxy** (`:8317`) — CLIProxyAPI: Codex/Gemini OAuth in, a static key out.
  - **agent-vault** (`:14321` broker, `:14322` MITM forward proxy) — the
    credential broker and TLS-MITM proxy.

  The model plane lives on the host, so metal only forwards `:8000`/`:8765` to
  `yasyf-home` — hermes keeps calling `metal:8000`/`metal:8765` unchanged, and the
  relay carries no credential, no HF cache, and no model env. With inference
  offloaded, metal runs at 2 vCPU / 8 GB, down from 10 / 48. Lockdown is enforced
  by a pf tailnet-only anchor plus the macOS app firewall, with every sharing
  surface off and Remote Login disabled — the only admin path is `tailscale ssh`.
  metal reads its secrets and runtime state over narrow per-need virtiofs shares
  (its own age key and bundle, the agent-vault and cliproxy runtime dirs), never
  the whole `~/.yclaw/state` tree; the HF hub and STT shares left with the model
  plane.
- **bluebubbles** — a separate macOS guest on its own tailnet node, SIP **off**
  because BlueBubbles' Private API requires it. It is the iMessage channel: it
  runs only the BlueBubbles server and holds **no** credentials. Keeping iMessage
  on its own SIP-off node is what lets metal stay SIP-on and maximally locked
  down. Built by `packer/bluebubbles.pkr.hcl`.
- **hermes** — the agent gateway: a Linux OCI image running `hermes-agent`, hosted as
  an Apple `container` named `hermes` on the macOS host rather than a `tart` VM. The
  agent runs **unprivileged** — the entrypoint `setpriv`-drops from root to uid 1000
  with supplementary group 0, and group 0 is load-bearing: the virtiofs idmap maps the
  host-gid-1000 proxy socket to guest gid 0, so carrying group 0 through the drop is what
  keeps that socket reachable. `apple/container` has no boot-autostart or restart verb, so
  the resident `com.yclaw.container-hermes` LaunchAgent ticks every 60 s and recreates the
  container whenever it is absent — the lifecycle supervisor that keeps the agent
  always-on. hermes holds **no** API credentials and reaches the internet only through
  agent-vault's MITM proxy on metal (`HTTPS_PROXY=http://metal:14322`), trusting its CA.
  It carries two tailnet-internal credentials by design — `BLUEBUBBLES_PASSWORD`
  (BlueBubbles sits in `NO_PROXY` and cannot be wire-injected) and `CLIPROXY_API_KEY`
  (cliproxy's own inbound API key — hermes calls cliproxy directly and presents the bearer
  itself). Its code-exec sandbox mounts only the `hermes-docker-proxy` socket. Agent state
  is **bind-mounted** from the host, not virtiofs: `~/.yclaw/state/hermes` mounts at
  `/var/lib/hermes` (honcho memory, sessions) and `~/.yclaw/state/hermes-ts-state` at
  `/var/lib/tailscale` (tailnet identity), so both survive a container rebuild and are
  captured by `just backup`.

The MLX model plane runs on the host itself (`yasyf-home`), not in any guest,
because the host GPU serves roughly 86 tok/s against 17.9 in the VM.
`athome serve activator` binds the host's tailnet address on `:8000`
behind the `com.yclaw.rapid-mlx` launchd agent: it answers `/health` and
`/v1/models` locally without waking the ~20 GB Qwen model, spawns the real
`rapid-mlx` server on `127.0.0.1:18000` on the first inference request, and
SIGTERMs that child after 1800 s idle (a graceful stop saves the prefix cache and
dodges a known wired-Metal teardown pathology). The `mlx-audio` STT server
(`darwin/stt-server.py`, run from `~/.yclaw/state/mlx-audio/host-venv`) stays
resident on `:8765`. A model call therefore flows from hermes to metal's relay to
the host activator to the model, and back.

The model ids are not guessed anywhere — `nixos/models.nix` is the single source
for the Qwen and STT ids, and hermes' default plus fallback providers
(`gpt-5.5`, then `gemini-3-pro-preview`, then local Qwen) live in `nixos/hermes.nix`.

macOS's Virtualization.framework caps a host at two concurrent macOS guests;
metal and bluebubbles spend exactly that budget, and hermes runs as an Apple
`container` (a Linux micro-VM), not a macOS guest, so it does not count against it.

## Credential custody

Real upstream secrets never enter hermes. hermes points `HTTPS_PROXY` at agent-vault and
trusts its CA; agent-vault injects static keys (OpenAI, Exa, Honcho, GitHub) and
OAuth bearers (Gmail, Calendar) onto the wire. The LLM-subscription OAuth (Codex,
Gemini) is held only by cliproxy — those refresh tokens are single-use and
rotate, so a second holder would mutually revoke them.

Model traffic is a deliberate `NO_PROXY` exclusion and goes direct: hermes calls
metal's cliproxy (`http://metal:8317`) and rapid-mlx (`http://metal:8000`) without the
agent-vault hop. cliproxy **enforces** its inbound static bearer — a call without
it is a 401 — so hermes presents it on every model call via
`key_env = "CLIPROXY_API_KEY"` (cliproxy's own API-key allowlist entry). That key and
`BLUEBUBBLES_PASSWORD` (BlueBubbles is the other `NO_PROXY` case) are the two
tailnet-internal credentials hermes holds — neither is an upstream API key. rapid-mlx
(`:8000`) needs no key, and its traffic relays through metal to the host's activator
without touching a credential on that path; the pf gate scoping `:8317` to hermes +
the host is a second, independent layer.

Enforcement is cooperative, not a hard firewall: hermes respects `HTTPS_PROXY`,
and a secret-needing request that bypasses the proxy has no credential, so the
task fails. The boundary is the credential custody (only metal holds real
secrets), not the routing.

## Network lockdown

Two default-deny layers sit under the credential custody: a tailnet ACL and a
host firewall anchor.

The tailnet ACL (`tailnet/policy.hujson`, the repo's mirror of the hand-applied
live policy) grants explicit east-west flows instead of a broad
`autogroup:member` allow. Every node owns its own tag, and the only node-to-node
grants are hermes to metal on the credential and model ports (`8317`, `14321`,
`14322`, `8000`, `8765`), hermes to bluebubbles on `443`, bluebubbles to hermes on
`8645` (the new-message webhook), and metal to `yasyf-home` on `8000`/`8765` (the
relay's one northbound flow). hermes and bluebubbles get no grant to the host at
all, so a compromised agent VM cannot address the host directly — it reaches the
models only through metal's relay.

The host backs that with a pf anchor (`com.apple/000.yclaw.host`, installed by
`scripts/setup.sh host-pf` and refreshed every 300 s by the
`com.yclaw.host-pf-refresh` root LaunchDaemon). It passes only metal-to-host
traffic on the model ports and blocks every other fleet-to-host packet, including
the vmnet weak-host side-door: Darwin answers a bridge-ingress packet addressed to any host
address (the `192.168.64.1` gateway, the LAN IP, even the tailnet IP over a forced
route), so the anchor blocks the whole `192.168.64.0/24` bridge group ahead of the
fleet rules, sparing only DHCP/DNS and a WireGuard `:41641` carve-out for
host↔fleet magicsock's fast path. Attaching as a `com.apple/*` child gets it
evaluated the moment the stock `pf.conf` wildcard runs, and `000` sorts it ahead
of Apple's own children so its verdicts win.

## The manifest

`machines.json` at the repo root is the single source of truth for the fleet:
machines, services, launchd labels, ports, health endpoints, log paths, virtiofs
shares, keychain service names, host state paths, and the per-node debloat
lists. Three readers consume it, so a fleet fact is stated once and can never
drift between them:

1. **bash** — `scripts/lib/manifest.sh` (`manifest_get` / `manifest_list` /
   `manifest_has`, jq underneath, fail-loud on a missing key).
2. **Nix** — `darwin/metal.nix` via `builtins.fromJSON`; the pf anchor's port
   set and the debloat disable loops derive from the manifest.
3. **Python** — `yclaw/manifest.py`, backing every CLI command.

The ports in the manifest mirror `tailnet/policy.hujson`; those two are kept in
sync by hand and the manifest comment says so.

## launchd on metal

Every metal service is a system LaunchDaemon (`darwin/metal.nix`); the guest is
headless, so nothing depends on a GUI session — the credential and relay daemons
need no login context. The reboot-hardening design has four rules:

- **`/bin/wait4path` guards the /nix race.** `/nix` is a separate APFS volume
  mounted late at boot; a `RunAtLoad` daemon that loses the race exec-fails into
  launchd's "respawning too quickly" penalty box and stays down until a human
  kicks it. Each daemon's `ProgramArguments` is wrapped in
  `/bin/wait4path <prog> && exec <prog>` — the same shape nix-darwin uses for
  `nix-daemon` — which blocks on a kernel mount event with no timeout. It
  replaced a hand-rolled trampoline after surviving repeated cold-boot gates
  (~25 s from power-on to the node answering on the tailnet).
- **One wait library.** wait4path wakes only on mount events, so it guards
  only /nix store paths. Everything else that can be not-yet-ready at boot —
  virtiofs share sub-paths (they materialize on `stat` under one AppleVirtIOFS
  automount, no FS event), sops-decrypted secrets, sockets — uses the bounded,
  fail-loud helpers from `scripts/lib/wait.sh`, embedded verbatim into each
  wrapper. The same file is sourced by host scripts and piped into guests;
  there is exactly one blessed way to poll.
- **Oneshots self-heal via `KeepAlive.SuccessfulExit = false`.** The provision
  and boot-setup jobs relaunch until they exit 0, so a transient failure retries
  instead of stranding the boot; `ThrottleInterval` stays at the 10 s launchd
  default (lowering it plus a fast-exiting job is the penalty-box trap). The
  pf-refresh daemons (metal + bluebubbles) instead run as resident
  `KeepAlive = true` loops that self-pace with `sleep 300` — macOS Tahoe silently
  stops firing `StartInterval` timers, but launchd's process-liveness stays
  reliable.
- **`tailscaled install-system-daemon` runs on first install only.**
  `install-system-daemon` terminates a running tailscaled and its relaunch
  silently fails, which used to cut the node off the tailnet on every redeploy;
  the boot-setup script now guards it behind a plist-absence check.

launchd hands daemons an unset `HOME` and an unreadable CWD, so each wrapper
pins `HOME` to the real user home and `cd`s there. Nothing overrides `HOME` to
point elsewhere anymore: agent-vault takes its state root from
`AGENT_VAULT_HOME` (a state-dir override added by
`pkgs/agent-vault-state-dir.patch`), so the `agentvault` virtiofs share is a
state directory, not an identity. The agent-vault wrapper also clears the stale
pidfile the persistent share carries across reboots — a PID-reuse match would
otherwise crash-loop the broker ("already running") with launchd as the actual
single-instance supervisor.

## State

All persistent state and secrets live in `~/.yclaw/state`, never in the repo:

- `hosts/<host>/key.txt` — that host's private age key, one per host.
- `hosts/<host>/secrets.sops.yaml` — that host's sops-encrypted bundle, encrypted only
  to that host's recipient and holding only its own secrets (per `nixos/secrets-manifest.json`),
  so each VM decrypts only what it owns. `hermes` and `metal` get bundles; `bluebubbles` owns none.
- `agent-vault/` — the broker's credential store.
- `cli-proxy-api/auth/` — the cliproxy OAuth tokens.
- `mlx-audio/` — the host STT venv.
- `hermes/` — the externalized agent state (honcho memory, sessions), bind-mounted
  into the container at `/var/lib/hermes`.
- `hermes-ts-state/` — the hermes container's tailnet identity, bind-mounted at
  `/var/lib/tailscale` so the node keeps its registration across a container rebuild.

The model weights are not in the state tree at all: rapid-mlx and the STT server
read the host's regular Hugging Face hub cache (`~/.cache/huggingface/hub`,
~20–25 GB), which regenerates via `hf download`, so it never enters the backup.

The irreplaceable set is everything under `hosts/` (every per-host key and bundle) plus
`agent-vault/`: lose those and you cannot decrypt or re-broker anything. `just backup` runs a
`restic` backup of `~/.yclaw/state`, excluding the regenerable `mlx-audio/` venv.
Restore is `restic restore latest`, then `just setup` to rebuild the caches and
re-boot the guests. Secrets decrypt at runtime; nothing secret is committed or
written to the world-readable Nix store.
