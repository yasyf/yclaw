# Hermes Home Server — Architecture

> **Status:** draft v0.2 · base plan, iterating. Decisions marked **🔒 locked** reflect your
> calls; **❓ open** items are gathered in [§12 Open decisions](#12-open-decisions-need-your-input).
> This is a living document — we iterate on it before any code is written.
>
> **Goal:** run [NousResearch **hermes-agent**](https://github.com/NousResearch/hermes-agent)
> always-on, on an Apple-Silicon Mac home server, **reproducibly** — every machine and every
> credential plane rebuildable from committed scripts, with hermes itself isolated in a VM and
> secrets never living inside it.

## Contents

1. [Governing principle: total reproducibility](#1-governing-principle-total-reproducibility)
2. [Architecture at a glance](#2-architecture-at-a-glance)
3. [The machines](#3-the-machines)
4. [Model plane (the LLM brain)](#4-model-plane-the-llm-brain)
5. [Credential planes (custody, not containment)](#5-credential-planes-custody-not-containment)
6. [OAuth tools (Gmail / Calendar / GitHub)](#6-oauth-tools-gmail--calendar--github)
7. [Configuration surface (every provider slot)](#7-configuration-surface-every-provider-slot)
8. [BlueBubbles / iMessage plane](#8-bluebubbles--imessage-plane)
9. [Reproducibility & IaC plan](#9-reproducibility--iac-plan)
10. [Decisions table](#10-decisions-table)
11. [Risks & pitfalls](#11-risks--pitfalls)
12. [Open decisions (need your input)](#12-open-decisions-need-your-input)
13. [Workflow plan & verification](#13-workflow-plan--verification)

---

## 1. Governing principle: total reproducibility

Everything is a **committed, idempotent script** in this repo. There are no one-off manual
commands typed into a live box.

- **Scripts-first.** Host prep, Packer/tart image builds, VM provisioning, Tailscale join, the
  `pf` firewall anchor, BlueBubbles config, hermes config generation, the credential planes, and
  the launchd/systemd units are all generated from versioned source.
- **Debug the script, not the machine.** When a step fails, the fix lands *in the script* and we
  re-run. An un-committed hot-patch on a VM is a reproducibility leak and is forbidden.
- **Destroy-and-rebuild is the acceptance test.** A single `bootstrap` entrypoint rebuilds the
  whole stack from zero on a wiped machine. Tearing down and rebuilding is the verification gate
  for every milestone — not an afterthought.
- **Secrets are never committed.** They live in the credential planes ([§5](#5-credential-planes-custody-not-containment))
  and are injected at runtime.

The prior [`openclaw.md`](../../Documents/Blog/drafts/openclaw.md) experiment already models the
right instincts (idempotency guards like `grep -q 'anchor "vnc"'`, the poll-before-start wrapper).
We codify that prior art verbatim rather than "fixing" working behavior ([§9](#9-reproducibility--iac-plan)).

**Determinism backbone: 🔒 Nix flakes** — NixOS for the Linux VMs (hermes ships its own NixOS
module) and nix-darwin for the host + macOS VM packages, so each machine is a reproducible function
of committed source; the few irreducibly-imperative macOS steps stay as idempotent scripts.
**Orchestration driver: 🔒 `just`** — the `bootstrap` entrypoint and per-VM recipes are `just`
targets over the flake + those scripts.

---

## 2. Architecture at a glance

Five tailnet nodes + one set of host-side services. Each plane gets its own VM with its own
Tailscale (MagicDNS) name, so a compromise of one is contained.

```
                       TAILSCALE TAILNET  (WireGuard, MagicDNS, no public exposure)
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                            │
 │  ┌──────────────── APPLE-SILICON HOST (macOS Sequoia 15+, "this machine") ──────────────┐ │
 │  │  tart + launchd plists · Tailscale (OSS build) · pf anchor                            │ │
 │  │                                                                                       │ │
 │  │  HOST-SIDE SERVICES (need Apple Silicon / long-lived creds — cannot live in a VM):    │ │
 │  │    • mlx_lm.server        :8080  — local Qwen MLX (LLM fallback #3)                    │ │
 │  │    • parakeet-server      :8765  — Parakeet STT (OpenAI /v1/audio-compatible)         │ │
 │  │    • CLIProxyAPI          :8317  — OAuth→static-key proxy (Codex + Gemini)             │ │
 │  │                                                                                       │ │
 │  │  ┌── VM: hermes (Linux) ──┐  ┌── VM: vault (Linux) ──┐  ┌── VM: bluebubbles (macOS) ─┐ │ │
 │  │  │ hermes gateway (systemd)│  │ agent-vault           │  │ SIP off · dedicated AppleID│ │ │
 │  │  │ docker-in-VM sandbox    │  │  static keys + OAuth   │  │ BlueBubbles REST :1234     │ │ │
 │  │  │ HTTPS_PROXY → vault     │  │  MITM CA · :14321/22   │  │ tailscale serve :443→1234  │ │ │
 │  │  │ NO_PROXY = ai,.ts.net   │  │  OAuth callback (https)│  │ (iMessage; hermes = client)│ │ │
 │  │  └───────────┬─────────────┘  └───────────────────────┘  └────────────────────────────┘ │ │
 │  └─────────────┼─────────────────────────────────────────────────────────────────────────┘ │
 │                │ model calls: POST http://ai/v1   (excluded from the vault proxy)            │
 │                ▼                                                                             │
 │  ┌──────────── NODE: ai  (separate tailnet node) ───────────────────────────────────────┐  │
 │  │  Tailscale Aperture → http://ai/v1   (per-model ROUTING + per-upstream static keys)    │  │
 │  │    upstream gpt-5.5 ─┐  gemini-3.5 ─┐──→ CLIProxyAPI :8317 (host)                       │  │
 │  │    upstream qwen-local ──────────────→ host mlx_lm.server :8080                         │  │
 │  │    (failover is hermes's job via fallback_providers — Aperture only routes by id)      │  │
 │  └────────────────────────────────────────────────────────────────────────────────────────┘ │
 └─────────────────────────────────────────────────────────────────────────────────────────────┘
         ▼  gpt-5.5 (OpenAI Codex OAuth) · gemini-3.5 (Google personal OAuth)  — via CLIProxyAPI
       external providers
```

**Three credential custody domains, deliberately separate** (none of the real secrets ever sit in
the hermes VM):

| Domain | What | Where it lives |
|---|---|---|
| Static API keys | Exa, Honcho, `OPENAI_API_KEY`, GitHub PAT, … | **`vault` VM** (agent-vault MITM-inject) |
| Tool OAuth | Gmail, Calendar, GitHub | **`vault` VM** (agent-vault OAuth module) |
| LLM-subscription OAuth | Codex (gpt-5.5), Gemini personal | **host** (CLIProxyAPI → `http://ai`) |

---

## 3. The machines

| Node | OS | Runs | Notes |
|---|---|---|---|
| **host** | macOS Sequoia 15+ | tart, launchd, Tailscale (OSS), `pf`; MLX (`mlx_lm.server`, `parakeet-server`), CLIProxyAPI | "This machine." Sequoia required so an in-VM macOS guest can do iMessage. |
| **hermes** VM | NixOS (tart) | `hermes gateway run` under systemd `Restart=always`; Docker daemon (sandbox) | Holds **no** real secrets. `HTTPS_PROXY`→vault, `NO_PROXY` excludes `ai`. |
| **vault** VM | NixOS (tart) | agent-vault (single Go binary) | Own tailnet name. MITM CA + OAuth callback endpoint (needs HTTPS on its MagicDNS name). |
| **bluebubbles** VM | macOS (tart) | BlueBubbles server (REST :1234) | **SIP disabled**, dedicated Apple ID, signed into iMessage. |
| **ai** | (separate tailnet node) | Tailscale Aperture → `http://ai/v1` (per-model routing + upstream static keys) | Routes by model id to CLIProxyAPI + host MLX. **Failover is hermes's job, not Aperture's.** |
| ~~**integrations** VM~~ | — | *(dropped)* | Not needed — Gmail/Calendar unified on agent-vault via `gws` ([§6](#6-oauth-tools-gmail--calendar--github)). |

**Virtualization — 🔒 tart (Packer + OCI images).** It's the only Apple-Silicon tool that builds
macOS *and* Linux guests reproducibly from a declarative template, and it's what `openclaw.md`
already uses. Apple's `container`/container-machine is **rejected** for the service VMs — it's
Linux-*container*-only with no proper volume mounts/networking, wrong for a persistent
Tailscale-joined daemon. The *Linux* VMs run **NixOS images** built from the flake (via
`nixos-generators`) and executed by tart (Lima-vz also works); the macOS `bluebubbles` VM must be
tart (only tart runs macOS guests reproducibly on Apple Silicon).

**Host RAM budget.** The host carries the VMs **+** the local Qwen MLX (~18–20 GB resident for a
35B-A3B 4-bit MoE) **+** Parakeet **+** CLIProxyAPI. A 64 GB Mac is comfortable; 128 GB roomy.
The local model is the *last* LLM fallback, so it must stay resident and responsive.

---

## 4. Model plane (the LLM brain)

**🔒 Daily-driver fallback chain:** `gpt-5.5` (OpenAI Codex OAuth subscription) → `gemini-3.5`
(Google **personal** OAuth, not enterprise) → `Qwen3.6-35B-A3B-4bit` (local MLX backstop). The
fallback ordering **lives in hermes** — it has a first-class ordered chain (`fallback_providers`),
so **no external router (no LiteLLM) is needed**.

hermes targets a **single endpoint** — `http://ai/v1` — where the gateway is **Tailscale Aperture**,
doing what it's good at: multi-upstream **per-model routing** + **static-key injection** to each
upstream. Aperture *cannot* do OAuth and *cannot* fail over — both are handled elsewhere (OAuth by
CLIProxyAPI; failover by hermes), so neither limitation bites.

**Aperture's three upstreams (on the `ai` node):**

| Model id | Upstream | Auth |
|---|---|---|
| `gpt-5.5` | **CLIProxyAPI** (host `:8317`) | Codex-subscription OAuth → static key |
| `gemini-3.5` | **CLIProxyAPI** (host `:8317`) | Gemini-personal OAuth → static key |
| `qwen-local` | **host `mlx_lm.server`** (`:8080`) | none (self-hosted) |

**🔒 OAuth proxy: [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** (Go, MIT) on the
**host** (out-of-VM). It performs *and refreshes* OAuth for both Codex-subscription and
Gemini-personal accounts and re-exposes them OpenAI-compatibly behind a static key — the
**OAuth-in / static-key-out** boundary Aperture needs. It is the **single** holder of the ChatGPT
and Google OAuth refresh tokens — this matters: those refresh tokens are *single-use and rotate*, so
nothing else (not agent-vault, not a second daemon) may hold the same account, or the two refreshers
mutually revoke. Do the one-time interactive `--codex-login` / `--gemini-login` on the host; back up
the auth-dir; alert on `invalid_grant`.

**hermes config (the whole model plane is just this):**
```yaml
# ~/.hermes/config.yaml  (hermes VM)
model:
  provider: custom
  default: gpt-5.5
  base_url: http://ai/v1          # Tailscale Aperture; routes by model id
fallback_providers:               # top-level list, tried IN ORDER; failover lives HERE, not a router
  - { provider: custom, model: gemini-3.5, base_url: http://ai/v1 }
  - { provider: custom, model: qwen-local, base_url: http://ai/v1 }
# api_max_retries: 1              # optional — makes 5xx/timeout hops snappier (default 3)
```

**When hermes hops to the next model:** 429 / 402 immediately; 401 / 403 / 404 / content-policy
immediately; 5xx / timeout after the retry budget. Context-length overflow does **not** hop — it
triggers compression. Fallback is **turn-scoped** (each new user turn retries the primary first,
with a 60 s cooldown if the primary was rate-limited).

```bash
# host: local Qwen + the OAuth proxy (one-time logins)
mlx_lm.server --model unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit --host 0.0.0.0 --port 8080
cli-proxy-api --codex-login    # one-time, ChatGPT SUBSCRIPTION account
cli-proxy-api --gemini-login   # one-time, PERSONAL Gmail (free Code Assist)
```

> **Could we skip Aperture?** Yes — hermes's `fallback_providers` can target each upstream's
> `base_url` directly (gpt-5.5/gemini → CLIProxyAPI, qwen → host MLX). But you want everything to
> flow through `http://ai`, and Aperture adds a single front door + per-identity usage/spend ledger,
> so it stays. ([§12](#12-open-decisions-need-your-input) #4 covers where the `ai` node lives.)

> **ToS note.** Codex-subscription-as-API and Gemini-personal-OAuth via third-party software are
> ToS-gray. The defensible posture is **single-account, single-user, self-hosted, never public, no
> pooling**. The local Qwen backstop guarantees the agent keeps working if an upstream is cut off.

---

## 5. Credential planes (custody, not containment)

The threat model is **credential custody** — real secrets never live in the hermes VM — *not*
egress containment. Enforcement is **cooperative**: hermes sets `HTTPS_PROXY` at the `vault` VM
and trusts its CA. We do **not** require a hard default-DROP firewall; the failure mode is benign
by design — a secret-needing request that bypasses the proxy simply has no credential and the task
fails. (An in-guest firewall stays available as optional defense-in-depth.)

**🔒 Broker: Infisical [agent-vault](https://github.com/Infisical/agent-vault)** in the dedicated
`vault` VM. It is a single Go binary (MIT, pure-Go SQLite) that is **already a unified broker** —
verified against source, it does **both**:

1. **Static-key injection** — TLS-terminating forward proxy (its own CA) matches the target host
   and injects a bearer / api-key / `{{PLACEHOLDER}}` substitution. (`OPENAI_API_KEY`, Exa key, Honcho
   key, GitHub PAT, …)
2. **Full OAuth** — `internal/oauth/` ships RFC-6749 auth-code + **PKCE** + a `credential_oauth`
   refresh-token store + refresh-before-expiry on the injection path, with HTTP handlers
   (`/v1/credentials/oauth/connect`, `/v1/oauth/callback`) and a provider catalog
   (Google/GitHub/Slack/Microsoft + more). Wiring Gmail/Calendar/GitHub is a **config task, no new
   code**.

This means **no separate OAuth proxy, no Nango, no onecli, no integrations VM** for tool secrets —
the `vault` VM is the single custodian for static keys **and** tool OAuth. (Rejected alternatives:
onecli — same shape but adds Postgres + dashboard + per-container CA; Nango — Postgres/Redis,
non-OSI license, a known self-host refresh-rotation bug; the SaaS agentic-auth crowd
(Arcade/Composio/Descope/Stytch/WorkOS/Auth0) — disqualified by the offline/self-host posture.)

```bash
# hermes VM env — the egress hookup
HTTPS_PROXY=http://vault.<tailnet>.ts.net:14322
HTTP_PROXY=http://vault.<tailnet>.ts.net:14322
NO_PROXY=ai,.ts.net,localhost,127.0.0.1            # http://ai (Aperture) stays DIRECT
SSL_CERT_FILE=/etc/ssl/agent-vault-ca.pem          # + NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE / CURL_CA_BUNDLE / GIT_SSL_CAINFO
```

> **Install the CA in the OS trust store too**, not only via the env vars above. Some clients —
> notably Rust/**rustls** tools like the `gws` CLI ([§6](#6-oauth-tools-gmail--calendar--github)) —
> **ignore** `SSL_CERT_FILE`/`SSL_CERT_DIR` and read only the system store. On Linux:
> `cp ca.pem /usr/local/share/ca-certificates/agent-vault.crt && update-ca-certificates`.

```yaml
# agent-vault service rules (vault VM): attach injected creds to hosts
services:
  - { name: openai,     host: api.openai.com,       auth: { type: bearer, token: OPENAI_API_KEY } }      # static (gpt-image-2 image gen)
  - { name: exa,        host: api.exa.ai,          auth: { type: bearer, token: EXA_API_KEY } }       # static
  - { name: honcho,     host: api.honcho.dev,      auth: { type: bearer, token: HONCHO_API_KEY } }     # static
  - { name: googleapis, host: "*.googleapis.com",  auth: { type: bearer, token: GOOGLE_OAUTH_TOKEN } } # OAuth, auto-refreshed; overwrites the dummy bearer gws sends
  - { name: github,     host: api.github.com,      auth: { type: bearer, token: GITHUB_OAUTH_TOKEN } } # OAuth or PAT
```

> **Why the LLM plane is separate.** The Codex/Gemini subscription auths are *not* plain OAuth
> (Codex needs a JWT-derived `ChatGPT-Account-Id` header; Gemini needs a `loadCodeAssist`/
> `onboardUser` handshake), and their refresh tokens are single-use/rotating — so a second holder
> would mutually revoke the host's CLIProxyAPI. Those stay with CLIProxyAPI on the model plane.
> Collapsing them into agent-vault is an explicitly-declined option ([§12](#12-open-decisions-need-your-input) #5).

---

## 6. OAuth tools (Gmail / Calendar / GitHub)

🔒 **Decision: unify on agent-vault, using the official Google Workspace CLI
([`googleworkspace/cli`](https://github.com/googleworkspace/cli), binary `gws`) with the OAuth bearer
injected on the wire** — the Google token never enters the hermes VM. *(Verified feasible against
both `gws` source and hermes's skill.)*

hermes ships **no native Gmail/Calendar tools** — productivity is a *skill* that shells out to `gws`
(`skills/productivity/google-workspace/scripts/gws_bridge.py`). Today that bridge does the wrong
thing for custody: it refreshes the Google token itself and passes the **real** access token to
`gws` via `GOOGLE_WORKSPACE_CLI_TOKEN`, so the refresh token lives in the hermes VM. We invert that:

- `gws` reads `GOOGLE_WORKSPACE_CLI_TOKEN` as its highest-priority auth and **only checks it's
  non-empty** (no JWT/expiry validation) before sending `Authorization: Bearer <token>` to
  `*.googleapis.com`; it honors `HTTPS_PROXY`.
- So we feed `gws` a **dummy** token (e.g. `__google_oauth__`) and let **agent-vault overwrite the
  `Authorization` header on the wire** with the real, freshly-refreshed Google bearer for
  `*.googleapis.com`. agent-vault owns the Google OAuth + refresh; the hermes VM holds only the
  placeholder.
- **Patch `gws_bridge.py`** to set the dummy token and delete its local refresh logic (refresh now
  lives in agent-vault).

**Two sharp prerequisites:**
1. **agent-vault's CA must be in the hermes VM's OS trust store** (`update-ca-certificates`). `gws`
   uses **rustls with native roots**, which **ignores** `SSL_CERT_FILE` — the env-var-CA trick
   silently fails. This is the single most likely thing to break interception.
2. The `vault` VM needs **HTTPS on its tailnet name** (MagicDNS cert) so Google's non-localhost
   OAuth callback (`https://vault.<tailnet>.ts.net/v1/oauth/callback`) is accepted during the
   one-time consent (run it from a browser on any tailnet device).

GitHub stays a static PAT in `vault` today (or moves to agent-vault OAuth for server-side custody).
*(Alternative considered and not chosen: a typed Google-Workspace MCP server in a separate
`integrations` VM — cleaner typed tools, but a second broker/VM and OAuth split across two boxes.)*

---

## 7. Configuration surface (every provider slot)

🔒 = your locked pick · ❓ = see [§12](#12-open-decisions-need-your-input)

| Slot | Choice | Local / hosted | Notes |
|---|---|---|---|
| **Inference** | `http://ai/v1` chain (§4) | local + hosted | gpt-5.5 → gemini-3.5 → qwen-local, fallback in hermes 🔒 |
| **Memory** | **Honcho hosted API** | hosted | `HONCHO_API_KEY` via vault. 🔒 Validate vs built-in via a personal recall A/B (no in-repo eval harness). Fully-local fallback if it loses: `holographic` (SQLite). |
| **Web search** | **Exa** | hosted | `EXA_API_KEY` via vault. 🔒 (Exa also covers extract.) |
| **STT** | **Parakeet** (`parakeet-mlx`) | local (host) | 🔒 Runs host-side (MLX). hermes wires it via `stt.provider: openai` + `base_url` → `http://<host>:8765/v1` (no new code; key is a dummy). |
| **TTS** | **Piper** | local (VM) | 🔒 Neural VITS in the hermes VM. (hermes's default `edge` is secretly MS-cloud — avoided.) |
| **Image gen** | **`openai` (gpt-image-2)** | hosted | 🔒 `OPENAI_API_KEY` injected by agent-vault's static plane. openai-codex dropped — its single-use OAuth refresh token would collide with CLIProxyAPI's Codex holder (mutual revocation). |
| **Video gen** | drop the toolset | — | Hosted-only; enable `fal`/`xai` only if needed. |
| **Browser** | **local in-VM Chromium** | local | 🔒 Zero egress; hermes's default. |
| **Terminal sandbox** | **docker-in-VM** | local | 🔒 Hardened backend; host/compose egress isolation. Nesting is a non-issue (Linux namespaces inside the guest). |
| **Embeddings / session search** | local SQLite FTS5 | local | No provider slot; summarizer can ride `http://ai`. |
| **Auxiliary** | compression/session_search → `main` (`http://ai`); vision/web_extract → `openai` (key via vault) | mixed | 🔒 No Nous; local Qwen is text-only, so multimodal aux uses the `openai` key. |
| **Autonomy** | maximum (auto-approve tools + subagents, free skill writes) | local | 🔒 Justified by the docker sandbox; tool-loop hard-stop kept as a runaway/cost guard, not a permission gate. |
| **Private URLs** | deny by default, allowlist internal hosts | local | 🔒 `security.allow_private_urls`/`browser.allow_private_urls` off; permit named internal hosts as needed. |
| **Dashboard** | enabled, **tailnet-only, no auth** | local | 🔒 Bind to the tailnet iface; Tailscale ACLs are the gate (hermes only activates dashboard auth when keys are set). |
| **Observability** | off | local | 🔒 No tracing backend; revisit later. |
| **Nous Tool Gateway** | **not used (dropped)** | — | 🔒 Fully self-directed; multimodal aux tasks route to the `openai` key instead of Nous. |

**Voice needs no macOS VM** — STT (Parakeet, host) and TTS (Piper, VM) are both non-iMessage.
macOS is required *only* for the BlueBubbles VM.

---

## 8. BlueBubbles / iMessage plane

hermes is a **pure client** of an existing BlueBubbles server — it never runs iMessage itself.
BlueBubbles is a first-class hermes gateway: two env vars, and a **self-registered webhook** (not
polling).

```bash
# hermes VM ~/.hermes/.env
BLUEBUBBLES_SERVER_URL="https://bluebubbles.<tailnet>.ts.net"   # the BB VM, via `tailscale serve`
BLUEBUBBLES_PASSWORD="<from vault>"
BLUEBUBBLES_WEBHOOK_HOST="hermes.<tailnet>.ts.net"             # cross-machine: BB POSTs events here
BLUEBUBBLES_REQUIRE_MENTION="false"                           # respond to every message in DMs AND groups
# Authorized-sender allowlist (DMs + groups): dm_policy / group_policy: allowlist + allow_from: [handles].
```

🔒 **Interaction model:** works in **both DMs and group chats**, gated by an **authorized-sender
allowlist** (`dm_policy`/`group_policy: allowlist` + `allow_from`). With `require_mention: false`,
hermes responds to **every authorized member's message** — in DMs and groups alike (no wake word
needed). iMessage exposes no bot @-mention, so the configurable wake-word `mention_patterns` are the
only group-quieting lever if you ever want to silence a busy group; unused here.

The macOS `bluebubbles` VM requires: **SIP disabled** (to load BlueBubbles' private iMessage
extension), a **dedicated Apple ID** signed into iMessage, and Sequoia 15+ on both host and guest.
🔒 **Enable the Private API helper** (SIP is already off) for typing indicators, read receipts,
threaded replies, reactions, and new-chat-from-handle. **Keep the `openclaw.md` poll-before-start
wrapper** — both VMs boot together and an early gateway start silently leaves the channel
uninitialized.

---

## 9. Reproducibility & IaC plan

**Repo layout (proposed):**
```
yclaw/
├── flake.nix                     # determinism backbone: defines every NixOS host + the nix-darwin host
├── justfile                      # entrypoint: build images, deploy, smoke, teardown/rebuild (the acceptance target)
├── nixos/                        # NixOS config per Linux VM — hermes (imports hermes's own nixosModule), vault, ai
├── darwin/                       # nix-darwin: host packages (tart, Tailscale, MLX, CLIProxyAPI) + macOS-VM packages
├── packer/                       # tart base image for the macOS bluebubbles VM (pinned IPSW); Linux images come from the flake
├── scripts/                      # idempotent IMPERATIVE glue only: SIP-off, iMessage/Apple-ID sign-in, BlueBubbles, one-time OAuth logins
├── secrets/                      # sops-nix/agenix encrypted bootstrap secrets (e.g. Tailscale auth key) — runtime secrets stay in the credential planes
└── docs/hermes-home-server.md    # this doc
```

**Prior art to codify verbatim** (from `openclaw.md`, OpenClaw-agnostic, carries over):
- tart VM creation; the **lume→tart migration** (`cp -c` the boot-blob triple
  `hardwareModel`+`ecid`+`nvram.bin` — cryptographically bound, **never regenerate**).
- Tailscale OSS join (Homebrew build for `tailscale ssh`); per-node `tailscaled` (MagicDNS resolves
  per-node — the hermes VM must join the tailnet itself to resolve `ai`).
- The **`pf` VNC anchor** (`vnc_allowed` = CGNAT `100.64.0.0/10` + RFC1918; idempotent guard).
- launchd plists (`tart run … --no-graphics --net-bridged … --dir …`; full paths, no `~`).
- The gateway **race-fix wrapper** (poll BlueBubbles `/api/v1/server/info` before
  `exec hermes gateway run`).

**Per-VM flow (🔒 Nix flakes):**
- **Linux VMs (`hermes`, `vault`, `ai`) → NixOS.** Each is a host in `flake.nix`; the `hermes` host
  imports hermes-agent's own `nixosModule`, which manages the package, the systemd gateway service,
  and the declarative `config.yaml` (via its `configMergeScript`). Build a tart-bootable image with
  `nixos-generators` (or `nixos-rebuild switch` against the running VM). Because NixOS sets
  **managed mode**, `hermes config set` is intentionally inert — all config is the flake (the §7
  catalog choices become Nix values), which is exactly what we want.
- **Host + macOS `bluebubbles` VM → nix-darwin** for packages, on a Packer/tart base image, plus the
  idempotent `scripts/` for the irreducibly imperative macOS steps.
- The only non-scriptable steps are one-time interactive sign-ins (Codex, Gemini, the BlueBubbles
  Apple ID, the agent-vault Google OAuth consent).

> **Secrets + Nix.** The Nix store is world-readable, so **no secret goes in the store.** 🔒 The
> `bootstrap` (`just`) entrypoint **prompts at run time** for the inputs it needs — the Tailscale
> auth key, the dedicated Apple ID for iMessage sign-in, the Codex/Gemini OAuth logins, the
> agent-vault master password — and injects them at first boot; nothing secret is committed. Persist
> them with `sops-nix`/`agenix` if you want fully unattended rebuilds; runtime secrets otherwise live
> in the credential planes ([§5](#5-credential-planes-custody-not-containment)), never in the flake.
>
> **VM networking: 🔒 bridged** (`tart --net-bridged`) — each VM gets its own LAN IP and runs its own
> `tailscaled`, so it's a first-class tailnet node with its own MagicDNS name (needed to resolve `ai`
> and to address the `vault` proxy). Matches the `openclaw.md` prior art.

---

## 10. Decisions table

| Area | Decision | Status |
|---|---|---|
| Virtualization | tart (Packer + OCI); Lima-vz optional for Linux VMs; Apple `container` rejected | 🔒 |
| Sandbox | docker-in-VM (hardened) | 🔒 |
| Model chain | gpt-5.5 → gemini-3.5 → qwen-local | 🔒 |
| Gateway / fallback | Aperture = gateway (per-model routing + upstream static keys); failover in hermes (`fallback_providers`); **no LiteLLM** | 🔒 |
| LLM OAuth | CLIProxyAPI on host (out-of-VM); single holder of the Codex/Gemini refresh tokens | 🔒 |
| Local model | Qwen3.6-35B-A3B-4bit (MoE) default; 27B dense fallback | 🔒 (eval-pending) |
| Credential broker | agent-vault (unified static + OAuth) in `vault` VM | 🔒 |
| Enforcement | cooperative `HTTPS_PROXY`, no hard firewall; `NO_PROXY` excludes `ai` | 🔒 |
| Memory / Search / STT / TTS / Browser | Honcho / Exa / Parakeet / Piper / local | 🔒 |
| Gmail / Calendar | unify on agent-vault: `gws` CLI + wire-injected bearer (token never in VM) | 🔒 |
| Image gen | `openai` gpt-image-2 (platform key via vault); openai-codex dropped — OAuth refresh collision | 🔒 |
| Orchestration | `just` | 🔒 |
| In-VM IaC | Nix flakes — NixOS (Linux VMs) + nix-darwin (host/macOS) + idempotent scripts for imperative macOS glue | 🔒 |
| Local model | Qwen3.6-35B-A3B-4bit (MoE) — chosen default | 🔒 (quality eval pending) |
| `ai`-node placement | Aperture stays on the existing `ai` tailnet node | 🔒 |
| Dashboard | enabled, tailnet-only, no auth (Tailscale ACLs gate it) | 🔒 |
| iMessage interaction | DMs + group chats; respond to every authorized member (allowlist); Private API helper on | 🔒 |
| Nous Tool Gateway | not used (dropped) — fully self-directed | 🔒 |
| Observability | off | 🔒 |
| Autonomy | maximum (auto-approve, free skill writes); tool-loop hard-stop kept as runaway guard | 🔒 |
| Private URLs | deny by default, allowlist internal hosts | 🔒 |
| VM networking | bridged (each VM own LAN IP + tailscaled) | 🔒 |
| Tailscale auth key | `bootstrap` script prompts at run time; not committed | 🔒 |
| LLM-cred unification | not pursued — CLIProxyAPI stays sole Codex/Gemini holder | 🔒 |
| Voice macOS VM | not needed | 🔒 |

---

## 11. Risks & pitfalls

- **OAuth ToS / account risk (LLM plane).** Single-account, single-user, self-hosted, no pooling.
  The local Qwen backstop is the insurance if an upstream is cut.
- **Single-holder rule for rotating OAuth.** Codex/Gemini refresh tokens are single-use and rotate;
  two independent refreshers of one account mutually revoke (`refresh_token_reused`, terminal). So
  **only CLIProxyAPI holds them** — this is *why* image-gen uses the `openai` platform key rather than the Codex OAuth.
  `invalid_grant` forces interactive re-login — alert on it, back up the host auth-dir.
- **rustls ignores `SSL_CERT_FILE`.** `gws` (and other Rust tools) only trust the OS store —
  agent-vault's CA must be installed there or wire-injection silently fails ([§6](#6-oauth-tools-gmail--calendar--github)).
- **iMessage-in-VM is the feasibility gate.** Works only if host *and* guest are Sequoia 15+; VM
  identity binds to the host Secure Enclave. **Keep a real Mac mini as fallback** if sign-in proves
  flaky. SIP must be off on the bluebubbles VM.
- **Boot-blob fragility.** `hardwareModel`+`ecid`+`nvram.bin` are cryptographically bound — `cp -c`
  verbatim, never re-derive, or the guest won't boot.
- **Single-endpoint SPOF.** All LLM traffic flows through `http://ai/v1`; the local backstop sits
  *behind* Aperture. Supervise the `ai` node; consider a break-glass direct path to host `:8080`.
- **agent-vault TLS-MITM blast radius.** Trusting its CA lets the `vault` VM read all non-LLM
  plaintext from the hermes VM; `http://ai` is the deliberate exclusion. Protect the master
  password + CA key. agent-vault is a "research preview" — pin a commit.
- **Google OAuth scopes/verification.** Gmail/Calendar are restricted scopes — your own Google Cloud
  consent screen must be configured (and verified past the test-user cap) for them, regardless of
  broker.

---

## 12. Open decisions (need your input)

All major decisions are now **locked** — see the ledger in [§10](#10-decisions-table). The only item
left to *validate* (not decide):

- **Local-model quality.** `Qwen3.6-35B-A3B-4bit` is the chosen backstop default; confirm it's good
  enough on your real tasks via a head-to-head against the 27B dense (and against the gpt-5.5 /
  gemini-3.5 fallbacks) before relying on it. This is the one thing the research couldn't settle for
  you — it needs your eval.

Per-setting tuning (the ~120 knobs) lives in the [configuration catalog](hermes-config-catalog.md);
its recommended defaults are all safe to adopt as-is.

---

## 13. Workflow plan & verification

**Main agent** tracks state, dispatches research/implementation as workflows, and reports; it does
not execute build steps itself.

| Phase | Shape | Agents | Verification |
|---|---|---|---|
| Research (done) | parallel | topology, config-surface, secrets, model-plane, OAuth-integrations, unified-broker + targeted verifications | Syntheses reconciled into this doc; agent-vault OAuth, hermes `fallback_providers`, `gws` wire-injection, and the Codex refresh-collision all verified against source |
| Image build | parallel | per-VM Packer/tart builds (worktree-isolated) | image boots, deps present (`hermes doctor`, `tart run` smoke) |
| Provision + config | pipeline | per-VM provision → config-gen → service install | each VM reaches the tailnet; `hermes gateway` healthy |
| Credential planes | parallel | agent-vault (static + OAuth connect), CLIProxyAPI logins | injection smoke tests per host; OAuth callback round-trips |
| End-to-end | loop | bring-up → smoke → teardown → rebuild | **destroy-and-rebuild from zero passes** (the acceptance test) |

**Smoke tests:**
```bash
curl http://ai/v1/chat/completions -d '{"model":"gpt-5.5","messages":[{"role":"user","content":"ping"}]}'  # model plane + Aperture routing
# fallback: kill the gpt-5.5 upstream, confirm hermes hops to gemini-3.5 then qwen-local
# integration egress: a hermes tool call needing Exa/Gmail succeeds (vault injects) and fails cleanly if vault is down
# gmail: `gws` with a dummy token succeeds through the vault proxy (real token never in the hermes VM)
# bluebubbles: send/receive a test iMessage end-to-end
```
**Definition of done:** `bootstrap` rebuilds every node from a wiped machine, all smoke tests pass,
and no real secret is present anywhere in the hermes VM filesystem or committed to the repo.
