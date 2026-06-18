# yclaw Architecture

yclaw runs the Nous `hermes-agent` always-on on Apple Silicon, reproducibly.
Every machine rebuilds from this repo, destroy-and-rebuild is the acceptance
test, and the agent is isolated in a Linux VM that never holds a credential.

## Topology

A bare macOS host boots three `tart` guests on one tailnet; a hosted node fronts
the model plane. The host stays minimal: Homebrew provides `tart`, Tailscale,
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
  - **omlx** (`:8000`) — local Qwen MLX inference, with per-model idle-TTL unload
    after 1800s of inactivity.
  - **mlx-audio** (`:8765`) — `ibm-granite/granite-speech-4.1-2b` STT, lazy-loaded
    and idle-unloaded.
  - **cliproxy** (`:8317`) — CLIProxyAPI: Codex/Gemini OAuth in, a static key out.
  - **agent-vault** (`:14321` broker, `:14322` MITM forward proxy) — the
    credential broker and TLS-MITM proxy.

  Lockdown is enforced by a pf tailnet-only anchor plus the macOS app firewall,
  with every sharing surface off and Remote Login disabled — the only admin path
  is `tailscale ssh`. metal reads its secrets and state from `~/.yclaw/state` over
  a virtiofs share.
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
  wire-injected) and `APERTURE_STATIC_KEY` (hermes calls metal's cliproxy directly,
  so it presents the bearer itself rather than having Aperture inject it). Agent state
  in `/var/lib/hermes` (honcho memory, sessions) is externalized to the host's
  `~/.yclaw/state/hermes` over virtiofs, so it survives a VM rebuild and is backed
  up.
- **ai** — a hosted Tailscale Aperture node, not a VM, that routes `http://ai/v1` by
  model id to the metal upstreams. hermes does **not** route model calls through it:
  the hosted node is a WAN round-trip (~150 ms) away and added ~0.5 s of TTFB per
  call, so hermes instead calls cliproxy (`http://metal:8317`, for `gpt-5.5` and
  `gemini-3-pro-preview`) and omlx (`http://metal:8000`, for the local Qwen) directly
  over the tailnet, presenting cliproxy's static bearer itself. Aperture is retained
  for the dashboard-managed routing config (`nixos/ai.nix`, `just deploy-ai`) but is
  out of the hot path. The fallback chain lives in hermes.

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
metal's cliproxy (`http://metal:8317`) and omlx (`http://metal:8000`) without the
agent-vault hop, presenting cliproxy's `APERTURE_STATIC_KEY` bearer itself. That
key and `BLUEBUBBLES_PASSWORD` (BlueBubbles is the other `NO_PROXY` case) are the
two tailnet-internal credentials hermes holds — neither is an upstream API key.

Enforcement is cooperative, not a hard firewall: hermes respects `HTTPS_PROXY`,
and a secret-needing request that bypasses the proxy has no credential, so the
task fails. The boundary is the credential custody (only metal holds real
secrets), not the routing.

## State

All persistent state and secrets live in `~/.yclaw/state`, never in the repo:

- `age/key.txt` — the age key that decrypts everything else.
- `secrets.sops.yaml` — the sops-encrypted secret bundle.
- `agent-vault/` — the broker's credential store.
- `cli-proxy-api/auth/` — the cliproxy OAuth tokens.
- `hf/` and `omlx/` — the model caches (~20–25 GB), regenerable on demand.
- `mlx-audio/` — the STT venv.
- `hermes/` — the externalized agent state (honcho memory, sessions).

The irreplaceable set is `age/key.txt`, `secrets.sops.yaml`, and `agent-vault/`:
lose those and you cannot decrypt or re-broker anything. `just backup` runs a
`restic` backup of `~/.yclaw/state`, excluding the regenerable `hf/`, `omlx/`, and
`mlx-audio/` caches. Restore is `restic restore latest`, then `just setup` to
rebuild the caches and re-boot the guests. Secrets decrypt at runtime; nothing
secret is committed or written to the world-readable Nix store.
