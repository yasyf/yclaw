# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial scaffolding.
- Hermes Home Server IaC: a Nix flake defining the `hermes` and `vault` NixOS VMs,
  the nix-darwin host, and the `agent-vault` + `cli-proxy-api` Go derivations.
- `nixos/hermes.nix` — the hermes gateway with the full declarative `config.yaml`
  (model fallback chain, Docker sandbox, Exa/Honcho/Parakeet/Piper, autonomy), the
  agent-vault MITM CA in the OS trust store, and a BlueBubbles readiness gate.
- `nixos/vault.nix` + `nixos/vault-services.yaml` — agent-vault service, static-key
  injection rules, and Google OAuth provisioning.
- `nixos/ai.nix` — a rendered Tailscale Aperture providers-config artifact.
- `darwin/host.nix` + `darwin/cliproxyapi-config.yaml` — Homebrew (`tart`, Tailscale),
  launchd agents for MLX/Parakeet/CLIProxyAPI and the tart VMs, and the `pf` anchor.
- `packer/bluebubbles.pkr.hcl` — the macOS base image for the iMessage VM.
- `scripts/` — `bootstrap.sh` (the destroy-and-rebuild entrypoint), `deploy-vm.sh`,
  `bluebubbles-setup.sh`, `sip-disable.md`, and `gws-bridge.patch` (dummy-token cutover).
- `justfile` orchestration (`bootstrap`, `build-images`, `deploy`, `smoke`, `destroy`,
  `rebuild`) and sops-nix secret wiring (`.sops.yaml`, `secrets/`).
- `secrets/PLACEHOLDERS.md` — the human-input manifest.
- `docs/build-notes/` — authoritative source extractions for hermes-agent, agent-vault,
  CLIProxyAPI, Aperture, and tart/Nix.

[Unreleased]: ../../commits/main
