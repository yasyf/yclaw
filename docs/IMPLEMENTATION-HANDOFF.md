# Implementation Handoff — Hermes Home Server

> **You are the implementing agent.** This is your kickoff brief. The architecture is **decided** —
> do not re-litigate it. Your job is to turn it into committed, reproducible IaC and get as far as
> possible **without human intervention**, leaving clearly-marked placeholders at every human-only
> input and stopping cleanly at each human gate.

## 0. Read first (source of truth — authoritative, locked)

- **[`hermes-home-server.md`](hermes-home-server.md)** — architecture, topology, the **§10 decisions
  ledger** (every locked choice). This is the contract.
- **[`hermes-config-catalog.md`](hermes-config-catalog.md)** — every hermes setting + the chosen
  value. These become Nix values.
- **Reference clones** (read-only ground truth; re-`git clone --depth 1` into `/tmp` if missing):
  `/tmp/hermes-agent-ref` (github.com/NousResearch/hermes-agent),
  `/tmp/secret-ref-Infisical-agent-vault` (github.com/Infisical/agent-vault).
- Prior-art to codify verbatim (do **not** "fix"): `/Users/yasyf/Documents/Blog/drafts/openclaw.md`
  (tart VM creation, lume→tart `cp -c` boot-blob triple, Tailscale OSS join, `pf` VNC anchor,
  gateway race-fix wrapper).

## 1. Operating rules (non-negotiable)

1. **Scripts-first, no one-offs.** Everything is committed source: the Nix flake, NixOS/nix-darwin
   modules, scripts, `justfile`, config generators. Nothing is typed into a live box by hand.
2. **Debug the script, not the machine.** A failure is fixed *in source* and re-run — never a manual
   hot-patch on a VM.
3. **Destroy-and-rebuild is the acceptance test.** `just bootstrap` rebuilds the whole stack from
   zero; that is the gate for "done."
4. **Determinism = Nix flakes.** NixOS for the Linux VMs (`hermes`, `vault`, `ai`), nix-darwin for
   the host + macOS-VM packages, idempotent scripts only for the irreducibly-imperative macOS steps.
   `just` orchestrates.
5. **No secret is ever committed.** Use the placeholder convention (§3). Real secrets flow through
   the credential planes or the `bootstrap` prompt at run time.
6. **Work as workflows.** Run each phase (§5) as a dynamic `Workflow`; verify its output before the
   next. Keep your context holding conclusions, not file dumps.
7. **Verify before asserting.** `nix flake check`, build what you can, and log per-phase verification.
   Don't claim a phase works until you've evaluated/built it.

## 2. Target repo layout (produce this)

```
yclaw/
├── flake.nix                 # defines every NixOS host + the nix-darwin host; pins nixpkgs + inputs
├── justfile                  # bootstrap | build-images | deploy <node> | smoke | destroy | rebuild
├── nixos/
│   ├── hermes.nix            # imports hermes-agent nixosModule; config.yaml as Nix values (catalog)
│   ├── vault.nix             # agent-vault service, CA, OAuth provider entries, service rules
│   └── ai.nix                # Tailscale Aperture: 3 upstreams + per-model routing
├── darwin/host.nix           # nix-darwin: tart, Tailscale(OSS), MLX, CLIProxyAPI, launchd, pf anchor
├── packer/bluebubbles.pkr.hcl# tart macOS base image (pinned IPSW); Linux images come from the flake
├── scripts/                  # idempotent imperative glue ONLY (see §4 human gates)
│   ├── bootstrap.sh          # prompts for placeholders, writes runtime secret material, kicks the flake
│   ├── sip-disable.md        # documented recovery-mode step (human)
│   ├── bluebubbles-setup.sh  # BlueBubbles install + Private API helper + tailscale serve
│   └── gws-bridge.patch      # patch hermes google-workspace skill to use a DUMMY token (§ Gmail)
├── secrets/
│   ├── PLACEHOLDERS.md       # the manifest from §3 (human-readable)
│   └── *.age / *.sops.yaml   # sops-nix/agenix encrypted material (placeholder keys until human supplies)
└── docs/                     # these three docs
```

## 3. Placeholder convention + manifest (the human-only inputs)

**Convention:** wherever a value is human-only, emit the literal token `@@NAME@@` (in configs/scripts)
**and** add a row to `secrets/PLACEHOLDERS.md`. Never invent a real value. `bootstrap.sh` prompts for
each at run time (or reads it from sops/agenix if pre-seeded). Code must fail loud if a placeholder is
still unresolved at apply time — never silently default.

| Token | What | Consumed by | How the human supplies it |
|---|---|---|---|
| `@@TAILNET_DOMAIN@@` | MagicDNS suffix, e.g. `tailXXXX.ts.net` | every `*.<tailnet>.ts.net` name | auto-detect via `tailscale status --json` if the host is on the tailnet; else prompt |
| `@@TS_AUTHKEY@@` | Tailscale auth key (reusable/ephemeral) for VM join | each VM's tailscaled (cloud-init / nixos) | bootstrap prompt → sops |
| `@@HOST_NAME@@` / `@@HOST_RAM@@` / `@@IPSW_URL@@` | which Mac, RAM tier, pinned Sequoia IPSW | darwin/host, packer | prompt |
| `@@APPLE_ID@@` / `@@APPLE_ID_PW@@` | dedicated Apple ID for iMessage | bluebubbles VM sign-in | **interactive (human gate)** |
| `@@BLUEBUBBLES_PASSWORD@@` | BlueBubbles server password | vault static cred → hermes env | bootstrap prompt → vault |
| `@@AUTHORIZED_HANDLES@@` | iMessage allowlist (your + approved handles/groups) | bluebubbles `allow_from` / `*_ALLOWED_*` | prompt (list) |
| `@@OPENAI_API_KEY@@` | image-gen (gpt-image-2) + vision/web_extract aux | vault static → injected on `api.openai.com` | prompt → vault |
| `@@EXA_API_KEY@@` | web search | vault static → `api.exa.ai` | prompt → vault |
| `@@HONCHO_API_KEY@@` | memory (hosted Honcho) | vault static → `api.honcho.dev` | prompt → vault |
| `@@GITHUB_TOKEN@@` | GitHub PAT (or move to OAuth) | vault static → `api.github.com` | prompt → vault |
| `@@GOOGLE_OAUTH_CLIENT_ID@@` / `@@..._SECRET@@` | Google Cloud **Web** OAuth client (Gmail/Cal restricted scopes) | agent-vault `oauth/connect` | human creates in GCP console → prompt |
| `@@AGENT_VAULT_MASTER_PASSWORD@@` | agent-vault vault encryption | vault server | bootstrap prompt → sops |
| `@@APERTURE_STATIC_KEY@@` | static key Aperture presents to CLIProxyAPI | ai.nix ↔ CLIProxyAPI | generate (agent may mint a random one) → sops |

**Interactive one-time sign-ins (cannot be scripted — leave a `HUMAN:` note and continue):**
`cli-proxy-api --codex-login` (ChatGPT subscription), `cli-proxy-api --gemini-login` (personal
Google), the agent-vault **Google OAuth consent** (`/v1/credentials/oauth/connect` → browser),
Apple-ID iMessage sign-in (2FA), and **SIP disable** on the bluebubbles VM (recovery mode).

## 4. What you can do fully autonomously vs. human gates

**Autonomous (do all of this now):**
- Author the entire `flake.nix`, all `nixos/*.nix`, `darwin/host.nix`, `packer/*`, every script, the
  `justfile`, `bootstrap.sh`, and `secrets/PLACEHOLDERS.md`.
- Translate the [config catalog](hermes-config-catalog.md) into Nix values for `nixos/hermes.nix`
  (model + `fallback_providers`, `terminal.backend=docker`, stt/tts, memory=honcho, browser=local,
  autonomy=max + hard-stop, deny-private-URLs+allowlist, dashboard tailnet-only-no-auth, etc.).
- Write `nixos/vault.nix` (agent-vault: static service rules for openai/exa/honcho/github + Google
  OAuth provider entry with `@@..@@` client creds + the `*.googleapis.com` bearer service), and the
  CA-into-OS-trust-store step for the hermes VM (rustls ignores `SSL_CERT_FILE`).
- Write `nixos/ai.nix` (Aperture: upstreams `gpt-5.5`→CLIProxyAPI, `gemini-3.5`→CLIProxyAPI,
  `qwen-local`→host MLX; per-model routing; static key).
- Write the host MLX units (`mlx_lm.server` Qwen3.6-35B-A3B-4bit `:8080`, `parakeet-server` `:8765`)
  and the CLIProxyAPI unit (`:8317`, `api-keys: [@@APERTURE_STATIC_KEY@@]`).
- Patch `gws_bridge.py` to inject a **dummy** `GOOGLE_WORKSPACE_CLI_TOKEN` (agent-vault overwrites the
  bearer on the wire); ship it as `scripts/gws-bridge.patch`.
- Run `nix flake check`, evaluate/build NixOS configs where the builder allows, and produce a
  per-phase verification log.

**Human gates (reach them, leave `HUMAN: <do X>`, then keep going elsewhere):**
SIP disable; Apple-ID sign-in; the three browser OAuth logins (codex, gemini, google-workspace
consent); supplying the `@@..@@` secrets; confirming `@@HOST_*@@`/`@@IPSW_URL@@`.

## 5. Build order (each phase = one workflow; verify before the next)

| Phase | Produce | Verification gate |
|---|---|---|
| **0 Scaffold** | flake skeleton, justfile, dir layout, `PLACEHOLDERS.md`, sops/agenix wiring | `nix flake check` parses; layout matches §2 |
| **1 Host (nix-darwin)** | tart, Tailscale(OSS), MLX deps, CLIProxyAPI, launchd plists, `pf` anchor (verbatim from openclaw.md) | `darwin` config evaluates; pf anchor lints |
| **2 Linux VMs (NixOS)** | `hermes.nix` (+ hermes `nixosModule`, config.yaml values), `vault.nix`, `ai.nix` | each NixOS config builds via `nixos-generators`; config keys cross-checked vs `/tmp/hermes-agent-ref` |
| **3 macOS BB VM** | packer base (`@@IPSW_URL@@`), `bluebubbles-setup.sh`, `sip-disable.md`, `tailscale serve` | scripts idempotent; image builds; SIP + Apple-ID flagged as human |
| **4 Credential planes** | agent-vault service rules + OAuth provider; CLIProxyAPI config; `gws-bridge.patch`; CA→OS-trust-store | rules validate; dummy-token path reasoned through |
| **5 Model plane** | hermes `model`+`fallback_providers`; Aperture upstreams; MLX + CLIProxyAPI units | curl smoke design; fallback-chain config asserted |
| **6 Bootstrap + E2E** | `just bootstrap` (prompts → applies flake → builds images → smoke), `just destroy`/`rebuild` | `nix flake check` clean; dry-run builds; full E2E pending human gates |

## 6. Definition of done

On the host, after the human supplies the `@@..@@` placeholders and completes the interactive gates,
`just bootstrap` rebuilds **every** node from a wiped state; all smoke tests (§7) pass; and **no real
secret exists in the hermes VM filesystem or is committed to the repo**. Everything else is green
without a human in the loop.

## 7. Smoke tests (wire these into `just smoke`)

```bash
nix flake check                                                              # config integrity
curl http://ai/v1/chat/completions -d '{"model":"gpt-5.5","messages":[{"role":"user","content":"ping"}]}'  # model plane + Aperture routing
# fallback: disable the gpt-5.5 upstream → confirm hermes hops gemini-3.5 → qwen-local
# vault: a tool call needing Exa/OpenAI succeeds (bearer injected) and fails cleanly if vault is down
# gmail: `gws` with a dummy token round-trips through the vault proxy (real token never in the hermes VM)
# bluebubbles: send/receive in a DM AND a group, from an authorized handle (allowlist enforced)
hermes doctor                                                                # per-VM health
# acceptance: just destroy && just bootstrap  → full rebuild from zero passes
```

## 8. Conventions to honor

Match the repo's `AGENTS.md`/`STYLEGUIDE.md` (fail-fast, no defensive shims, minimal changes,
self-documenting). Commits atomic and scoped. When the architecture is genuinely ambiguous at the
*implementation* level (not the decided level), prefer the simplest choice that satisfies the §10
ledger and leave a `# TODO(human): confirm` rather than inventing policy. If you hit a true blocker,
surface it with what you tried — don't silently stub a decision the ledger doesn't cover.
