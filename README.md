# yclaw

![yclaw banner](docs/assets/readme-banner.webp)

Reproducible, always-on home server for the Nous [`hermes-agent`](https://github.com/NousResearch/hermes-agent) on Apple Silicon — the agent never touches your credentials.

## What and why

`yclaw` runs a personal agent that reaches you over iMessage and the open internet without ever holding an API key. The agent lives sandboxed in a Linux VM. A separate, locked-down macOS guest is the sole credential custodian: it brokers every secret and injects it on the wire, and the LLM-subscription OAuth lives there too, out of the agent's reach. The whole stack rebuilds from this repo — that destroy-and-rebuild is the acceptance test.

## Topology

Four nodes on your tailnet, reached by Tailscale MagicDNS names:

- **metal** — the locked-down macOS guest and sole credential custodian. Runs the local Qwen inference server (`omlx`), speech-to-text, the Codex/Gemini OAuth proxy (CLIProxyAPI), and the `agent-vault` credential broker.
- **bluebubbles** — a separate macOS guest that bridges iMessage. Holds no credentials.
- **hermes** — the Linux gateway that runs `hermes-agent` in a Docker sandbox. It holds no API credentials and reaches the internet only through `agent-vault` on metal; its agent state is backed up off-VM.
- **ai** — a hosted Tailscale Aperture node that routes model traffic by model id.

Models fall back from `gpt-5.5` to `gemini-3-pro-preview` to the local Qwen MLX model. Real secrets never reach the agent: `agent-vault` injects the API keys and OAuth bearers on the wire.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the model plane and the credential-custody model.

## Deploy

One command builds and boots everything:

```bash
just bootstrap
```

It runs preflight checks, prompts for the non-secret values, encrypts the runtime secrets, builds the VM images, and boots the guests — then prints the one-time interactive steps it can't script: the iMessage sign-in on bluebubbles, the Codex/Gemini browser logins on metal, and the `agent-vault` Google OAuth connect.

Prerequisites, the full walkthrough, and what to back up are in [docs/DEPLOY.md](docs/DEPLOY.md).

## Hardware

Apple Silicon only. metal is sized for a 35B MLX model (~42 GB of wired GPU memory on a 48 GB guest) — on a smaller Mac, point it at a smaller model. Budget ~20-25 GB for the model cache plus the VM disks, and expect a long first boot while macOS installs and the models download.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — topology, model plane, credential custody.
- [docs/DEPLOY.md](docs/DEPLOY.md) — prerequisites, the deploy walkthrough, backup and restore.
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — conventions for agents working in this repo.

## License

SPDX-License-Identifier: MIT. See [LICENSE](LICENSE).
