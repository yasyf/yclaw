# yclaw

![yclaw banner](docs/assets/readme-banner.webp)

Reproducible, always-on home server for the Nous [`hermes-agent`](https://github.com/NousResearch/hermes-agent) on Apple Silicon — the agent never touches your credentials.

## What and why

`yclaw` runs a personal agent that reaches you over iMessage and the open internet without ever holding an API key. The agent lives sandboxed in a Linux VM. A separate locked-down macOS guest is the sole credential custodian: it brokers every secret and injects it on the wire, and the LLM-subscription OAuth lives there too, out of the agent's reach. The whole stack rebuilds from this repo — that destroy-and-rebuild is the acceptance test.

## Topology

Four tailnet nodes, addressed by bare Tailscale MagicDNS names, supervised by a bare macOS host (`tart` + Tailscale + `launchd`, no Nix). All persistent state lives in `~/.yclaw/state`.

- **metal** — SIP-on, tailnet-only macOS guest, configured in-guest by nix-darwin. The sole credential custodian. Runs the local Qwen MLX server (`omlx`), the `granite-speech` STT service, CLIProxyAPI (the Codex/Gemini OAuth-to-static-key proxy), and the `agent-vault` broker plus its MITM forward proxy.
- **bluebubbles** — separate SIP-off macOS guest, its own tailnet node. The iMessage channel via the BlueBubbles server; holds no credentials.
- **hermes** — NixOS Linux gateway running `hermes-agent` in a Docker sandbox. Holds no API credentials and reaches the internet only through `agent-vault`'s proxy on metal. Its agent state is externalized to the host and backed up.
- **ai** — hosted Tailscale Aperture node (not a VM). Routes `http://ai/v1` by model id to the metal upstreams.

The model fallback chain is `gpt-5.5`, then `gemini-3-pro-preview`, then the local Qwen MLX model — all routed through Aperture at `http://ai/v1`. Real secrets never enter hermes: `agent-vault` injects the static keys and OAuth bearers on the wire, and CLIProxyAPI holds the subscription OAuth.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full topology, the model plane, and the credential custody model.

## Deploy

One wizard builds and boots everything:

```bash
just bootstrap
```

It runs preflight checks, prompts for the non-secret values, mints and `sops`-encrypts the runtime secrets into `~/.yclaw/state`, builds or pulls the VM images, and boots the guests. It ends by printing the **human gates** — the one-time interactive steps that cannot be scripted:

- Apple-ID iMessage sign-in (2FA) on bluebubbles, then `scripts/bluebubbles-setup.sh`.
- The CLIProxyAPI `--codex-login` and `--login` (Gemini) browser flows on metal.
- The `agent-vault` Google OAuth connect.

Full prerequisites, the step-by-step walkthrough, and what to back up are in [docs/DEPLOY.md](docs/DEPLOY.md).

## Hardware

Apple Silicon only. metal is sized for a 35B MLX model (~42 GB wired GPU memory on a 48 GB-RAM guest); smaller Macs should pick a smaller model id in `nixos/models.nix`. Budget ~20-25 GB for the model cache plus the VM disks (metal 200 GB, bluebubbles ~68 GB, hermes 8 GB). First boot is long — IPSW download, macOS install, and model downloads run for hours.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — topology, model plane, credential custody.
- [docs/DEPLOY.md](docs/DEPLOY.md) — prerequisites, the deploy walkthrough, backup and restore.
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — conventions for agents working in this repo.

## License

SPDX-License-Identifier: MIT. See [LICENSE](LICENSE).
