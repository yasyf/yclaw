# yclaw Architecture

> Status: implementation in progress. The target topology below is decided and
> stable; the code that realizes it is being built out.

yclaw runs the Nous `hermes-agent` always-on on an Apple Silicon Mac,
reproducibly. Every machine rebuilds from this repo and destroy-and-rebuild is
the acceptance test; the agent is isolated in a Linux VM and never holds a
credential.

## Topology

A bare macOS host boots two tart guests on one tailnet; a hosted node fronts the
model plane.

- **host** — bare macOS, no Nix. Homebrew provides `tart`, Tailscale, and
  `launchd`. It boots and supervises the two guests and holds nothing else; all
  persistent state and secrets live outside the repo in `~/.yclaw/state`.
- **metal** — a locked-down macOS guest, its own tailnet node, configured by
  nix-darwin internally. It is the single credential custodian and runs every
  host-class service:
  - **omlx** (`:8000`) — local Qwen MLX inference, per-model idle-TTL.
  - **parakeet** (`:8765`) — Parakeet STT, started lazily.
  - **cliproxy** (`:8317`) — CLIProxyAPI: Codex/Gemini OAuth in, static key out.
  - **agent-vault** (`:14321`/`:14322`) — credential broker and TLS-MITM forward
    proxy.
  - **BlueBubbles** — the iMessage channel, folded into this guest.
- **hermes** — a NixOS Linux gateway running `hermes-agent` in a Docker sandbox.
  It holds **no** credentials and reaches the internet only through
  agent-vault's proxy on metal.
- **ai** — a hosted Tailscale Aperture node. It routes `http://ai/v1` to the
  metal upstreams: `gpt-5.5` and `gemini-3.5` via cliproxy, `qwen-local` via
  omlx. Aperture routes by model id only; the fallback chain (`gpt-5.5`,
  then `gemini-3.5`, then `qwen-local`) lives in hermes.

## Credential custody

Real secrets never enter the hermes VM. hermes points `HTTPS_PROXY` at
agent-vault and trusts its CA; agent-vault injects static keys (Exa, Honcho,
OpenAI, GitHub) and OAuth bearers (Gmail, Calendar, GitHub) onto the wire. The
LLM-subscription OAuth (Codex, Gemini) is held only by cliproxy — those refresh
tokens are single-use and rotate, so a second holder would mutually revoke them.
Model traffic to `http://ai` is the deliberate `NO_PROXY` exclusion and goes
direct. Enforcement is cooperative: a secret-needing request that bypasses the
proxy simply has no credential and the task fails.

## State

All persistent state and secrets live in `~/.yclaw/state`, never in the repo:
the age key, the sops-encrypted `secrets.sops.yaml`, the cliproxy OAuth auth dir,
the agent-vault store, and the omlx model cache. Per-user non-secret values live
in `~/.yclaw/config.toml`. Secrets decrypt at runtime; nothing secret is
committed or written to the world-readable Nix store.
