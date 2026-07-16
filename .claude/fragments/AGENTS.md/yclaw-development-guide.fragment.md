# yclaw Development Guide

Reproducible, always-on home server for the Nous `hermes-agent` on Apple Silicon — the agent
never holds a credential.

## Repository Structure

```
yclaw/
├── .claude/          # Claude Code settings and guard hooks
├── darwin/           # nix-darwin config for the metal guest (launchd daemons, pf anchor)
├── docs/             # DEPLOY.md, ARCHITECTURE.md, project assets
├── nixos/            # NixOS config for the hermes guest + models/secrets manifests
├── packer/           # macOS guest image builds (metal, bluebubbles) + first-boot activator
├── pkgs/             # Nix packages and patches (agent-vault, cli-proxy-api)
├── scripts/          # Host-side orchestration (bootstrap, deploy, destroy, smoke, ...)
│   └── lib/          # Shared bash library: common, manifest, wait, launchd, pf, ssh, secrets
├── tailnet/          # Tailnet ACL reference (policy.hujson)
├── tests/            # pytest suite for the yclaw CLI
├── yclaw/            # The yclaw debug CLI (Python, flat package)
├── machines.json     # Canonical fleet manifest: machines, services, ports, logs, debloat
├── justfile          # Thin recipes; non-trivial logic lives in scripts/
├── pyproject.toml    # The yclaw Python package (uv)
├── AGENTS.md         # This file — shared conventions
├── CLAUDE.md         # Claude-only rules; embeds AGENTS.md
├── STYLEGUIDE.md     # Concrete style rules
├── CHANGELOG.md      # Keep a Changelog format, SemVer
└── README.md         # Project overview
```
