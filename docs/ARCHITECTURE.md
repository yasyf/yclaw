# yclaw Architecture

yclaw runs the Nous `hermes-agent` always-on on Apple Silicon, reproducibly.
Every machine rebuilds from this repo, destroy-and-rebuild is the acceptance
test, and the agent is isolated in a Linux VM that never holds a credential.

## Topology

A bare macOS host boots three `tart` guests on one tailnet. The host stays minimal: Homebrew provides `tart`, Tailscale,
`gum`, `packer`, and `restic`, and `scripts/setup.sh` supervises the guests via
`com.yclaw.tart-*` launchd agents. All persistent state and secrets live outside
the repo in `~/.yclaw/state`; generated passwords live in a dedicated keychain at
`~/Library/Keychains/yclaw.keychain-db`.

Every node is addressed by its bare Tailscale MagicDNS name, so an image is
generic until first boot stamps in a `node.env`. That keeps the built images free
of host-specific identity and lets the same artifact serve any tailnet.

- **metal** — the credential and inference guest: a macOS node with SIP **on** and
  the OS maximally locked down, configured in-guest by nix-darwin
  (`darwinConfigurations.metal` / `darwin/metal.nix`). It is the sole credential
  custodian and runs only the credential and inference services — **no iMessage**.
  Four OpenAI-compatible services bind tailnet-only:
  - **rapid-mlx** (`:8000`) — local Qwen MLX inference; the single model loads at
    startup (~101 s) and stays resident — no idle unload.
  - **mlx-audio** (`:8765`) — `ibm-granite/granite-speech-4.1-2b` STT, lazy-loaded
    and idle-unloaded.
  - **cliproxy** (`:8317`) — CLIProxyAPI: Codex/Gemini OAuth in, a static key out.
  - **agent-vault** (`:14321` broker, `:14322` MITM forward proxy) — the
    credential broker and TLS-MITM proxy.

  Lockdown is enforced by a pf tailnet-only anchor plus the macOS app firewall,
  with every sharing surface off and Remote Login disabled — the only admin path
  is `tailscale ssh`. metal reads its secrets and runtime state over narrow
  per-need virtiofs shares (its own age key and bundle, the agent-vault state
  dir, the shared HF hub cache), never the whole `~/.yclaw/state` tree.
- **bluebubbles** — a separate macOS guest on its own tailnet node, SIP **off**
  because BlueBubbles' Private API requires it. It is the iMessage channel: it
  runs only the BlueBubbles server and holds **no** credentials. Keeping iMessage
  on its own SIP-off node is what lets metal stay SIP-on and maximally locked
  down. Built by `packer/bluebubbles.pkr.hcl`.
- **hermes** — a NixOS Linux gateway running `hermes-agent` in a Docker sandbox.
  It holds **no** API credentials and reaches the internet only through
  agent-vault's MITM proxy on metal (`HTTPS_PROXY=http://metal:14322`), trusting
  its CA. It carries two tailnet-internal credentials by design —
  `BLUEBUBBLES_PASSWORD` (BlueBubbles sits in `NO_PROXY` and cannot be
  wire-injected) and `CLIPROXY_API_KEY` (cliproxy's own inbound API key — hermes
  calls cliproxy directly and presents the bearer itself). Agent state
  in `/var/lib/hermes` (honcho memory, sessions) is externalized to the host's
  `~/.yclaw/state/hermes` over virtiofs, so it survives a VM rebuild and is backed
  up.

The model ids are not guessed anywhere — `nixos/models.nix` is the single source
for the Qwen and STT ids, and hermes' default plus fallback providers
(`gpt-5.5`, then `gemini-3-pro-preview`, then local Qwen) live in `nixos/hermes.nix`.

macOS's Virtualization.framework caps a host at two concurrent macOS guests;
metal and bluebubbles spend exactly that budget, and hermes is Linux so it does
not count against it.

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
(`:8000`) needs no key; the pf gate scoping `:8317` to hermes + the host is a
second, independent layer.

Enforcement is cooperative, not a hard firewall: hermes respects `HTTPS_PROXY`,
and a secret-needing request that bypasses the proxy has no credential, so the
task fails. The boundary is the credential custody (only metal holds real
secrets), not the routing.

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
headless, so nothing depends on a GUI session — MLX GPU inference works from a
daemon context. The reboot-hardening design has four rules:

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
- `hf/` — the model weights cache (~20–25 GB), regenerable on demand.
- `mlx-audio/` — the STT venv.
- `hermes/` — the externalized agent state (honcho memory, sessions).

The irreplaceable set is everything under `hosts/` (every per-host key and bundle) plus
`agent-vault/`: lose those and you cannot decrypt or re-broker anything. `just backup` runs a
`restic` backup of `~/.yclaw/state`, excluding the regenerable `hf/` and
`mlx-audio/` caches. Restore is `restic restore latest`, then `just setup` to
rebuild the caches and re-boot the guests. Secrets decrypt at runtime; nothing
secret is committed or written to the world-readable Nix store.
