# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` — the project is now MIT-licensed.
- A pre-commit secret guard (`.pre-commit-config.yaml`): a self-contained `pygrep`
  hook that blocks staged secret-shaped strings (Tailscale keys, OpenAI/GitHub
  tokens, AWS access keys, age and PEM private keys), matching the patterns the CI
  genericity guard already enforces. Install with `brew install pre-commit && pre-commit install`.
- Hermes agent state is externalized to the host. `honcho` memory, sessions, and
  the rest of `/var/lib/hermes` live in `~/.yclaw/state/hermes` over virtiofs, so
  conversation history survives a VM rebuild and is captured by backups.
- `just backup` — a `restic` backup of `~/.yclaw/state` that excludes the
  regenerable model caches (`hf/`, `omlx/`, `mlx-audio/`). Point it at a repo with
  `YCLAW_RESTIC_REPO` and `RESTIC_PASSWORD`; restore with `restic restore latest
  --target ~/.yclaw/state` followed by `just setup`.
- A dedicated `yclaw` keychain (`~/Library/Keychains/yclaw.keychain-db`) holding
  every generated password (agent-vault master, per-VM admin, BlueBubbles server),
  siloed from your login keychain and auto-unlocked via one
  `yclaw-keychain-password` entry.
- End-of-bootstrap onboarding. Once `hermes` is reachable, `just bootstrap`
  auto-launches an interactive `hermes-onboard` over `tailscale ssh` that seeds the
  user-specific context the declarative build can't supply: your profile (`USER.md`),
  the agent persona (`SOUL.md`), and the Honcho peer identity. It runs as the `hermes`
  user, only writes files that are absent (so the agent's own later edits are never
  overwritten), and is re-runnable: `tailscale ssh -t admin@hermes -- sudo -u hermes -H
  hermes-onboard`.

### Changed
- Lower iMessage reply latency. hermes now calls metal's model upstreams directly
  (cliproxy `:8317`, omlx `:8000`) instead of routing through the hosted Aperture
  node, removing a ~0.5 s WAN round-trip per call; it presents cliproxy's static
  bearer itself (`APERTURE_STATIC_KEY`, now also rendered into sops `hermes/env`).
  Reasoning effort drops `medium` → `low` (replies are sent only after the full
  completion, so reasoning time dominates perceived latency). The hermes-agent
  systemd unit gains `TimeoutStopSec=210s` so a graceful drain is not SIGKILLed
  mid-flight.
- Deploy is now a single wizard. `just bootstrap` runs end to end: preflight
  tooling, prompt for the non-secret values (tailnet, GitHub owner, IPSW URL, host
  RAM, authorized handles), mint the age key and generate per-VM passwords, encrypt
  state with sops, then build and boot all images. The agent-vault CA fetch from
  `metal` is automated; the remaining human gates (Apple-ID iMessage sign-in,
  `cliproxy` OAuth logins, agent-vault Google OAuth) are printed at the end.
- Honcho memory loads and targets the remote cloud. The `honcho` extra (`honcho-ai`)
  is baked into the hermes image — upstream dropped it from the eager-install set, so
  it would otherwise fail to lazy-install in the network-less Nix Python. The provider
  is declared (`memory.provider = "honcho"`, `environment = "production"`, no
  `base_url` → cloud, real key injected by agent-vault on `api.honcho.dev`), and
  `~/.honcho/config.json` is seeded as a writable copy rather than a read-only symlink,
  so the agent's own memory writes survive a rebuild.
- VM images are generic and reusable across tailnets. Nodes are addressed by bare
  Tailscale MagicDNS names (`metal`, `bluebubbles`, `hermes`, `ai`) and configured
  on first boot from an injected `node.env`, so a published image carries no
  site-specific identifiers. The `hermes` image's canonical source is CI; the wizard
  builds it locally as a fallback.
- Model ids have one source of truth, `nixos/models.nix`, consumed by
  `nixos/hermes.nix`, `nixos/ai.nix`, and `darwin/metal.nix`.
- Speech-to-text now lazy-loads and idle-unloads. `mlx-audio` STT on `metal` loads
  `granite-speech` on first use and unloads after an idle period, matching the omlx
  per-model idle TTL (1800s).
- Tailscale on the NixOS nodes is bumped to current (overlaid from
  `nixpkgs-unstable`).

### Removed
- The `vault` VM. `agent-vault` (the credential broker and MITM forward proxy) now
  runs on `metal`, the sole credential custodian, so there is no separate vault node.
- Host Nix. The macOS host no longer runs nix-darwin; `darwin/host.nix` and the host
  flake output are gone, and the host is provisioned by `scripts/setup.sh` (Homebrew
  `tart`, Tailscale, `gum`, `packer`, `restic`) alone. In-guest `metal` is still
  configured by nix-darwin (`darwinConfigurations.metal`).

### Security
- `metal` is hardened to SIP-on and tailnet-only. It is the sole credential
  custodian (omlx, `granite-speech` STT, CLIProxyAPI, and agent-vault all run
  inside it), locked down with a `pf` anchor plus the application firewall, with
  Remote Login off (reachable only via Tailscale SSH). Real secrets never enter
  `hermes`; agent-vault injects static keys and OAuth bearers on the wire, and
  `cliproxy` holds the Codex/Gemini subscription OAuth.
- BlueBubbles runs in its own SIP-off `bluebubbles` guest — a separate tailnet node
  that holds no credentials beyond the BlueBubbles server password it needs locally.
- Generated passwords are random and reused on re-run, never hardcoded, placeholder,
  or prompted. Packer reads each guest's admin password from the `yclaw` keychain via
  `PKR_VAR_vm_admin_pass`; the BlueBubbles password flows through sops.

[Unreleased]: ../../commits/main
