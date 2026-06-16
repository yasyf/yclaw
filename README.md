# yclaw

![yclaw banner](docs/assets/readme-banner.webp)

Reproducible, always-on home server for the Nous [`hermes-agent`](https://github.com/NousResearch/hermes-agent) on Apple Silicon.

Every machine and every credential plane rebuilds from this repo. The agent runs sandboxed in a Linux VM that holds none of your API keys — a separate `vault` VM brokers credentials and injects them on the wire, and the LLM-subscription OAuth lives on the host, out of the agent's reach. `just bootstrap` rebuilds the whole stack from a wiped machine; that destroy-and-rebuild is the acceptance test.

## What's here

The stack is five tailnet nodes plus host-side services, all defined as code:

- **host** (macOS, nix-darwin) — `tart`, Tailscale, the local Qwen MLX server, Parakeet STT, and CLIProxyAPI (the Codex/Gemini OAuth-to-static-key proxy).
- **hermes** VM (NixOS) — the `hermes gateway`, with a Docker sandbox; reaches the internet only through the vault proxy.
- **vault** VM (NixOS) — Infisical `agent-vault`: static API keys + tool OAuth, injected via a TLS-terminating proxy so secrets never enter the hermes VM.
- **ai** — Tailscale Aperture, routing `http://ai/v1` to the three model upstreams.
- **bluebubbles** VM (macOS) — BlueBubbles for the iMessage channel.

The architecture is decided and documented; this repo is the implementation. The model fallback chain (`gpt-5.5`, then `gemini-3.5`, then local `qwen`), the credential custody model, and every config choice are spelled out in the docs below.

## Layout

```
flake.nix              # every NixOS host + the nix-darwin host; pins all inputs
justfile               # bootstrap | build-images | deploy <node> | smoke | destroy | rebuild
nixos/                 # hermes.nix, vault.nix, ai.nix (Aperture config artifact), common.nix
darwin/host.nix        # nix-darwin: tart, Tailscale, MLX, CLIProxyAPI, launchd, pf anchor
pkgs/                  # agent-vault + cli-proxy-api Go derivations
packer/                # tart macOS base image for the bluebubbles VM
scripts/               # bootstrap.sh, deploy-vm.sh, bluebubbles-setup.sh, gws-bridge.patch, sip-disable.md
secrets/               # PLACEHOLDERS.md (the human-input manifest) + sops-encrypted material
docs/                  # architecture, config catalog, build notes
```

## Bootstrap

You need an Apple Silicon Mac on macOS Sequoia 15+, a Tailscale tailnet, and [Nix](https://nixos.org/download) installed on the host (it drives nix-darwin, the image builds, and the secret tooling).

Run the entrypoint from a clone of this repo:

```bash
just bootstrap
```

It prompts for the human-supplied values in [`secrets/PLACEHOLDERS.md`](secrets/PLACEHOLDERS.md), mints and encrypts the runtime secrets with sops, applies the flake, builds the VM images, and ends by printing the **human gates** — the interactive one-time steps that cannot be scripted (SIP disable, Apple-ID sign-in, the Codex/Gemini browser logins, and the Google OAuth consent). Complete those, then verify:

```bash
just smoke
```

To tear down and prove reproducibility end to end:

```bash
just rebuild   # destroy, then bootstrap from zero
```

## Documentation

- [Architecture](docs/hermes-home-server.md) — topology, the model and credential planes, and the locked decisions ledger.
- [Configuration catalog](docs/hermes-config-catalog.md) — every hermes-agent setting and its chosen value.
- [Implementation handoff](docs/IMPLEMENTATION-HANDOFF.md) — the build brief and phase plan.
- [Build notes](docs/build-notes/) — the authoritative source extractions the modules are built from.
- [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) — conventions for agents working in this repo.

## Status

The full IaC is authored and verified as far as is possible without applying the host config: the flake locks, every output (`hermes`/`vault`/`host` configs, both VM images, the Aperture artifact) evaluates clean, and both Go services (`agent-vault`, `cli-proxy-api`) build with pinned `vendorHash`es. Still gated on the host: a full `nix flake check` and the VM image builds need the `aarch64-linux` builder (it comes up after `darwin-rebuild switch`), and the end-to-end rebuild depends on the human gates above. Items needing a human decision or a live-stack check are marked inline with `TODO(human):`.
