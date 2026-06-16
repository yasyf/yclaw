# Hermes Config Values — Authoritative Extract

Concrete, locked values for the hermes VM, split into two surfaces:

1. **`~/.hermes/config.yaml`** — declarative Nix values (`services.hermes-agent.settings` in
   `nixos/hermes.nix`). **No secrets here.** Managed mode (`HERMES_MANAGED=true` on NixOS) makes
   `hermes config set` / dashboard "Save config" **inert** — everything is declared in the flake and
   applied via `nixos-rebuild`.
2. **`~/.hermes/.env`** — runtime/process env. Holds the agent-vault proxy hookup + CA paths +
   BlueBubbles wiring. All `*_API_KEY` values are **injected on the wire by the agent-vault MITM
   proxy** and are NOT set here; only the BlueBubbles password and similar are placeholders.

Placeholder convention (from `IMPLEMENTATION-HANDOFF.md` §3): every human-only value is the literal
token `@@NAME@@`. Code must fail loud if a placeholder is unresolved at apply time.

Sources: `docs/hermes-config-catalog.md` (catalog), `docs/hermes-home-server.md` (architecture),
`/tmp/hermes-agent-ref/cli-config.yaml.example`, `/tmp/hermes-agent-ref/.env.example`.

---

## Part A — `config.yaml` (Nix attrset / YAML-equivalent)

> This is the complete declarative config. Comments mark `🔒 LOCKED` (architecture/catalog decision)
> vs `default` (shipped default we keep). Source line cites use `catalog:NNN` /
> `home-server:NNN` / `cli-example:NNN`.

```yaml
# ── Model plane ──────────────────────────────────────────────────────────────
# home-server:163-169 (verbatim model block); catalog:91-93,105-107
model:
  provider: custom                 # 🔒 OpenAI-compatible endpoint (catalog:92)
  default: gpt-5.5                  # 🔒 Aperture upstream default (catalog:91)
  base_url: http://ai/v1           # 🔒 Tailscale Aperture; in NO_PROXY so it stays DIRECT (catalog:93)
  # api_key/key_env: UNSET — Aperture is tailnet-gated. If it requires a token,
  #   the static key is APERTURE_STATIC_KEY (see Part B) → set key_env accordingly.
  #   TODO(human): confirm whether Aperture requires a presented key on the hermes side.

fallback_providers:                # 🔒 top-level list, tried IN ORDER; failover lives HERE (catalog:105, home-server:167-169)
  - { provider: custom, model: gemini-3.5, base_url: http://ai/v1 }
  - { provider: custom, model: qwen-local, base_url: http://ai/v1 }
  # NOTE: all three models route through the SAME endpoint http://ai/v1; Aperture
  #   routes by model id to CLIProxyAPI (gpt-5.5, gemini-3.5) and host MLX (qwen-local).
  #   No per-entry key_env needed — Aperture holds the per-upstream static keys (home-server:85-87,147-149).

# ── Agent behaviour / loop budget ────────────────────────────────────────────
agent:
  max_turns: 90                    # 🔒 ~90 for autonomous home agent (catalog:42,156,960); cli-example ships 60, code default is 90
  api_max_retries: 1               # 🔒 fast failover gpt-5.5 → gemini-3.5 (catalog:130; home-server:170); default is 3
  reasoning_effort: medium         # default (catalog:142, cli-example:631); custom endpoint may ignore — fall back to providers.ai.extra_body
  verbose: false                   # default (cli-example:625)
  image_input_mode: auto           # default — gpt-5.5 is vision-capable, attaches natively (catalog:512)

# ── Terminal / Docker sandbox ────────────────────────────────────────────────
terminal:
  backend: docker                  # 🔒 in-VM Docker sandbox (catalog:192)
  cwd: /workspace                  # 🔒 path INSIDE the container (catalog:193)
  docker_image: "@@DOCKER_IMAGE_PIN@@"   # 🔒 PIN it (catalog:35,197). Base ref: nikolaik/python-nodejs:python3.11-nodejs20
                                   #   TODO(human): pick the exact pinned image (digest or own image).
  container_cpu: 2                 # 🔒 Rec 2 CPU (catalog:35,202); default 1
  container_memory: 8192           # 🔒 8 GB (catalog:35,203); default 5120 (5 GB)
  container_disk: 51200            # default 50 GB (cli-example:284)
  container_persistent: true       # 🔒 always-on stateful assistant (catalog:205); default already true
  docker_run_as_host_user: true    # 🔒 Rec true (catalog:36,199); default false
  docker_mount_cwd_to_workspace: false  # 🔒 Rec false — full container isolation (catalog:36,198); default false
  lifetime_seconds: 900            # 🔒 "persistent"/long-lived (catalog:37,195); default 300 — raised to avoid cold-start churn
  home_mode: auto                  # default — correct for docker (catalog:196)
  timeout: 180                     # default (cli-example:184)
  docker_forward_env: []           # 🔒 empty — secrets reach the agent via HTTPS_PROXY, not env (catalog:200)
  docker_extra_args: []            # default (catalog:201)
  env_passthrough: []              # 🔒 empty — secrets go through the proxy (catalog:207)
  # sudo_password: UNSET — run as root in the container, no sudo (catalog:206)

# ── Security ─────────────────────────────────────────────────────────────────
security:
  allow_private_urls: true         # 🔒 home-network trust boundary — agent must reach http://ai, STT host, LAN (catalog:872)
                                   #   Default false; flipped true deliberately. Host-substring guard stays on.
                                   #   Allowlist mechanism: there is NO host-allowlist key — allow_private_urls is the
                                   #   global gate; per-host denial is via security.website_blocklist.domains (below).
  allow_lazy_installs: false       # 🔒 deps come from the Nix flake, not runtime pip (catalog:31,904); default true
  redact_secrets: true             # 🔒 keep on — only thing keeping injected keys out of logs (catalog:895); default true
  tirith_enabled: false            # 🔒 START DISABLED (catalog:30,215). Enable fail-closed once policies written.
  # tirith_path: tirith            # default PATH lookup (catalog:216)
  # tirith_timeout: 5              # default (catalog:217)
  # tirith_fail_open: true         # default; set false (fail-closed) only after the binary is in the Nix image (catalog:218,905)
  website_blocklist:
    enabled: false                 # default — add domains only if you want guardrails (catalog:873)

tool_loop_guardrails:
  warnings_enabled: true           # default (cli-example:345)
  hard_stop_enabled: true          # 🔒 true for unattended operation (catalog:39,220,962); default false
  warn_after: { exact_failure: 2, same_tool_failure: 3, idempotent_no_progress: 2 }   # defaults (cli-example:347-350)
  hard_stop_after: { exact_failure: 5, same_tool_failure: 8, idempotent_no_progress: 5 }  # defaults (cli-example:351-354)

# ── Browser (local in-VM Chromium via agent-browser) ─────────────────────────
browser:
  # cloud_provider: UNSET → local/auto (catalog:261). Locked stack uses local Chromium.
  # engine: auto/chrome (default) (catalog:262)
  allow_private_urls: false        # 🔒 SSRF guard ON; local Chromium reaches private URLs anyway (catalog:265); default false
  inactivity_timeout: 120          # default (cli-example:335)
  record_sessions: false           # default — privacy (catalog:269)

# ── Web search & extract ─────────────────────────────────────────────────────
web:
  backend: exa                     # 🔒 Exa for both search and extract (catalog:280)
  # EXA_API_KEY injected via agent-vault (catalog:283)

# ── Memory: built-in + Honcho (hosted) ───────────────────────────────────────
memory:
  memory_enabled: true             # default; declare block so the false code-fallback never bites (catalog:351)
  user_profile_enabled: true       # default (catalog:352)
  memory_char_limit: 2200          # default ~800 tok (catalog:353)
  user_char_limit: 1375            # default ~500 tok (catalog:354)
  nudge_interval: 10               # default (catalog:355)
  flush_min_turns: 6               # default (catalog:356)
  write_approval: false            # 🔒 free writes for a personal agent (catalog:46,357,931); default false
  provider: honcho                 # 🔒 Honcho HOSTED is the chosen external provider (catalog:358)

# Honcho substantive config lives in ~/.hermes/honcho.json (see Part A.1 below).
# The config.yaml honcho: block is only Hermes-side overrides:
honcho: {}                         # cli-example:951-952; substantive config is honcho.json (catalog:364)

# ── STT: Parakeet on host via OpenAI-compatible shim ─────────────────────────
stt:
  enabled: true                    # 🔒 transcribe voice notes (catalog:472)
  provider: openai                 # 🔒 host Parakeet OpenAI-shim reached via this provider (catalog:473)
  openai:
    base_url: http://@@HOST_NAME@@:8765/v1   # 🔒 Parakeet on the host :8765 (catalog:474, home-server:72,299).
                                   #   Add this host to NO_PROXY. Use the host's tailnet name.
    api_key: "local"               # 🔒 dummy — Parakeet ignores the key (catalog:475)
    model: whisper-1               # default; set to the shim's model id if it validates (catalog:476)

# ── TTS: Piper (local VITS, no key) ──────────────────────────────────────────
tts:
  provider: piper                  # 🔒 fully local, no key (catalog:490)
  piper:
    voice: en_US-lessac-medium     # default balanced voice (catalog:492)
    use_cuda: false                # 🔒 no CUDA in Apple-Silicon Linux VM (catalog:494)
    length_scale: 1.0              # default — real speed knob (Piper ignores tts.speed) (catalog:491,495)

# ── Image generation: OpenAI gpt-image-2 ─────────────────────────────────────
# Enable plugin: hermes plugins enable image_gen/openai (declare in plugins.enabled on NixOS)
image_gen:
  provider: openai                 # 🔒 gpt-image-2 plugin (NOT the FAL entry) (catalog:521, home-server:301)
  openai:
    model: gpt-image-2-medium      # default tier (catalog:522); all tiers hit API model gpt-image-2
  use_gateway: false               # 🔒 direct OpenAI key (catalog:525)
  # OPENAI_API_KEY injected via agent-vault → routes through HTTPS_PROXY (external) (catalog:524, home-server:301)

# ── Auxiliary slot routing ───────────────────────────────────────────────────
# 🔒 Architecture decision (home-server:306, catalog:66): compression + session_search → main (http://ai);
#    vision + web_extract → openai key (via vault). NOTE: provider "auto" already resolves to main (= http://ai),
#    so compression/session_search need no override; session_search is no longer a model-routing slot (catalog:808).
auxiliary:
  compression:
    provider: main                 # 🔒 → http://ai (catalog:66,713); equivalent to auto
  vision:
    provider: openai               # 🔒 multimodal aux uses the openai key (catalog:66, home-server:306)
  web_extract:
    provider: openai               # 🔒 multimodal/extract aux uses the openai key (catalog:66, home-server:306)

# ── Compression thresholds ───────────────────────────────────────────────────
compression:
  enabled: true                    # default (cli-example:377)
  threshold: 0.50                  # default (cli-example:381)
  target_ratio: 0.20               # default (cli-example:387)
  protect_last_n: 20               # default (cli-example:392)
  protect_first_n: 3               # default (cli-example:404)

# ── Skills & autonomy ────────────────────────────────────────────────────────
skills:
  creation_nudge_interval: 10      # 🔒 Rec 10 (catalog:46,929); source default 10 (cli-example suggests 15)
  write_approval: false            # 🔒 free skill writes for a personal agent (catalog:46,931); default false
  guard_agent_created: false       # default (catalog:930)

curator:
  enabled: true                    # default — keep agent-created skills tidy (catalog:425,947)
  prune_builtins: true             # 🔒 default per decision ledger; keep prompt index lean (catalog:48,430,952)

delegation:
  max_iterations: 50               # default (cli-example:923)
  subagent_auto_approve: true      # 🔒 autonomy: MAXIMUM (catalog:43,330,967); default false (auto-deny)
                                   #   Justified by the docker sandbox; hard_stop_enabled is the runaway guard.
  max_spawn_depth: 1               # default flat (catalog:328,966)
  # delegation.model: UNSET — inherit parent (gpt-5.5) + its fallback chain (catalog:332)

# ── Privacy ──────────────────────────────────────────────────────────────────
privacy:
  redact_pii: true                 # 🔒 Rec: on (catalog:28,896); default false

# ── Platform toolsets ────────────────────────────────────────────────────────
# 🔒 Locked stack: CLI + BlueBubbles only. Set bluebubbles explicitly to the FULL messaging bundle (catalog:56,626).
platform_toolsets:
  cli: [hermes-cli]                # 🔒 full toolset (catalog:313)
  bluebubbles: [hermes-telegram]   # 🔒 full messaging bundle = terminal, file, web, vision, image_gen, tts,
                                   #   browser, skills, todo, cronjob, send_message (catalog:314,626).
                                   #   (hermes-bluebubbles preset == hermes-cli; hermes-telegram is the standard
                                   #    messaging bundle. TODO(human): pick hermes-telegram bundle vs explicit list.)
  # All other platforms (telegram/discord/slack/etc.) are OFF — leave keys unused (catalog:315)

# ── LSP (Nix-provided servers) ───────────────────────────────────────────────
lsp:
  enabled: true                    # default (catalog:239)
  install_strategy: manual         # 🔒 NixOS determinism — servers provided via Nix, nothing self-installs (catalog:242)
  wait_mode: document              # default (catalog:240)
  wait_timeout: 5.0                # default (catalog:241)
  # servers.<id>.command: pin each server's Nix store path (catalog:244).
  #   TODO(human): enumerate the language servers to ship via Nix (incl. nixd) and pin command paths.

# ── Dashboard: enabled, tailnet-only, no auth ────────────────────────────────
# There is NO dashboard.enabled key — the dashboard is launched by `hermes dashboard` (catalog:826).
# Locked stack: bind loopback, reach via Tailscale; no auth provider configured (no non-loopback bind).
# Launch flags (in the NixOS systemd unit, NOT config.yaml): --host 127.0.0.1 --port 9119 --no-open --skip-build
#   (catalog:830-834). Binding loopback means the OAuth gate never engages → no auth needed (catalog:24,839).
#   TODO(human): if you ever bind to the VM's tailnet IP, that counts as PUBLIC and forces an auth provider.
dashboard: {}                      # no dashboard.oauth.* set — nous Portal path is cloud-only (catalog:847)

# ── Observability: OFF ───────────────────────────────────────────────────────
# Langfuse + NeMo Relay are opt-in plugins; leave them OUT of plugins.enabled (catalog:32,856,860).
plugins:
  enabled:
    - image_gen/openai             # 🔒 required to activate gpt-image-2 (catalog:517)
    # NO observability/langfuse, NO observability/nemo_relay (catalog:856,860)

# ── Logging ──────────────────────────────────────────────────────────────────
logging:
  level: INFO                      # default (catalog:892)
```

### A.1 — `~/.hermes/honcho.json` (Honcho hosted provider)

> Substantive Honcho config lives here, NOT in config.yaml (catalog:364). Resolution:
> `$HERMES_HOME/honcho.json` > `~/.hermes/honcho.json` > `~/.honcho/config.json`. The API key is
> injected via agent-vault (`HONCHO_API_KEY`), NOT committed in this file.

```json
{
  "hosts": {
    "hermes": {
      "enabled": true,
      "recallMode": "hybrid",
      "dialecticDepth": 1,
      "contextCadence": 2,
      "dialecticCadence": 3,
      "dialecticReasoningLevel": "low",
      "pinUserPeer": true,
      "peerName": "@@HONCHO_PEER_NAME@@"
    }
  }
}
```

**🔒 LOCKED Honcho values (prompt + decision ledger catalog:52-53):**
`recallMode=hybrid` / `dialecticDepth=1` / `contextCadence=2` / `dialecticCadence=3` /
`dialecticReasoningLevel=low`.

> **BLOCKER (value conflict):** The decision ledger (catalog:52-53) and the task spec map the five
> knobs to **hybrid / depth 1 / 2 / 3 / low**, which reads as `dialecticDepth=1, contextCadence=2,
> dialecticCadence=3`. But the per-setting catalog tables give different DEFAULTS and recommendations:
> `contextCadence` default 1 / rec 1 (catalog:396), `dialecticCadence` default 1-2 / rec 2
> (catalog:397), `dialecticDepth` default 1 / rec 2 (catalog:398). The encoded JSON above follows the
> **locked ledger ordering hybrid/1/2/3/low** literally (depth=1, contextCadence=2, dialecticCadence=3).
> TODO(human): confirm the intended (key → value) mapping — the ledger lists values positionally and
> the per-setting recommendations disagree. The five LOCKED values themselves are not in dispute; only
> which value binds to `contextCadence` vs `dialecticCadence` vs `dialecticDepth`.

- `apiKey` / `HONCHO_API_KEY` — 🔒 hosted; injected via agent-vault, never in this file (catalog:368).
- `baseUrl` — UNSET (hosted → SDK targets Honcho Cloud) (catalog:369).
- `environment` — `production` (default) (catalog:370).
- `pinUserPeer: true` — 🔒 single operator; BlueBubbles + CLI land on one peer (catalog:375).
- `peerName` — `@@HONCHO_PEER_NAME@@` — durable human identity; pick once (catalog:373).

---

## Part B — `~/.hermes/.env` (runtime / secrets surface)

> `.env` does NOT override an already-set process env var (agent-vault-injected env wins). Under
> NixOS this file is owned by the systemd unit's env/secret file (agenix/sops) — never plaintext in
> the Nix store. All `*_API_KEY` values below are **injected on the wire by agent-vault**, NOT set
> here — they are listed only to document which key names the proxy must attach to which host.

### B.1 — Agent-vault egress hookup + CA trust (home-server:223-234)

```bash
# config-vs-env: ALL of these are .env (runtime), NOT config.yaml
HTTPS_PROXY=http://vault.@@TAILNET_DOMAIN@@:14322       # 🔒 agent-vault MITM forward proxy
HTTP_PROXY=http://vault.@@TAILNET_DOMAIN@@:14322        # 🔒 same proxy
NO_PROXY=ai,.ts.net,localhost,127.0.0.1                # 🔒 http://ai (Aperture) stays DIRECT.
                                                       #   MUST also cover the STT host (@@HOST_NAME@@:8765)
                                                       #   and the BlueBubbles host — both are local calls.
SSL_CERT_FILE=/etc/ssl/agent-vault-ca.pem              # 🔒 trust the proxy's MITM CA
NODE_EXTRA_CA_CERTS=/etc/ssl/agent-vault-ca.pem        # 🔒 Node clients
REQUESTS_CA_BUNDLE=/etc/ssl/agent-vault-ca.pem         # 🔒 Python requests
CURL_CA_BUNDLE=/etc/ssl/agent-vault-ca.pem             # 🔒 curl
GIT_SSL_CAINFO=/etc/ssl/agent-vault-ca.pem             # 🔒 git
```

> **🔒 CRITICAL (home-server:231-234, 278, 438-445):** Also install the CA into the **OS trust
> store** (`cp ca.pem /usr/local/share/ca-certificates/agent-vault.crt && update-ca-certificates`).
> Rust/**rustls** tools (the `gws` Google CLI) **ignore** `SSL_CERT_FILE`/`SSL_CERT_DIR` and read
> only the system store. The env vars above are necessary but NOT sufficient.

Optional (catalog:902-903): `HERMES_CA_BUNDLE=/etc/ssl/agent-vault-ca.pem` — point the hermes SSL
guard at a bundle that includes the MITM CA so the startup guard validates (keep
`HERMES_SKIP_SSL_GUARD` UNSET / guard on).

### B.2 — BlueBubbles wiring (home-server:324-331)

```bash
# config-vs-env: these are .env vars; send_read_receipts and mention_patterns are config-only (no env var)
BLUEBUBBLES_SERVER_URL="https://bluebubbles.@@TAILNET_DOMAIN@@"   # 🔒 BB VM via `tailscale serve` (home-server:326)
BLUEBUBBLES_PASSWORD="@@BLUEBUBBLES_PASSWORD@@"                   # 🔒 from vault (home-server:327; HANDOFF §3)
BLUEBUBBLES_WEBHOOK_HOST="hermes.@@TAILNET_DOMAIN@@"             # 🔒 hermes tailnet name — BB POSTs events here (home-server:328, catalog:597)
BLUEBUBBLES_WEBHOOK_PORT=8645                                    # default (catalog:598)
BLUEBUBBLES_WEBHOOK_PATH=/bluebubbles-webhook                    # default (catalog:599)
BLUEBUBBLES_REQUIRE_MENTION="false"                             # 🔒 respond to EVERY msg in DMs AND groups (home-server:329, catalog:602)
BLUEBUBBLES_ALLOWED_USERS="@@AUTHORIZED_HANDLES@@"              # 🔒 authorized-sender allowlist (catalog:585; HANDOFF §3)
BLUEBUBBLES_ALLOW_ALL_USERS="false"                            # 🔒 never true on personal iMessage (catalog:586)
BLUEBUBBLES_HOME_CHANNEL="@@AUTHORIZED_HANDLES@@"              # 🔒 cron/notification delivery target (catalog:600); your own number
```

**🔒 Authorization model (home-server:330,333-335):** DMs + groups, gated by an authorized-sender
allowlist: **`dm_policy: allowlist` / `group_policy: allowlist` + `allow_from: [handles]`**. With
`require_mention: false`, hermes responds to every authorized member's message in DMs and groups
(no wake word). These three keys (`dm_policy`, `group_policy`, `allow_from`) are how the architecture
expresses the allowlist.

> **TODO(human) / cross-check needed:** The architecture doc names `dm_policy` / `group_policy:
> allowlist` + `allow_from` (home-server:330,334) as the allowlist mechanism, but the catalog's
> BlueBubbles table (catalog:585-606) documents `BLUEBUBBLES_ALLOWED_USERS` /
> `BLUEBUBBLES_ALLOW_ALL_USERS` as the actual env-var keys read by `gateway/platforms/bluebubbles.py`,
> with no `dm_policy`/`group_policy`/`allow_from` keys appearing in the catalog's source-cited tables.
> The literal `dm_policy`/`group_policy`/`allow_from` names were NOT found in
> `/tmp/hermes-agent-ref/.env.example`. **TODO(human): confirm whether `dm_policy`/`group_policy`/
> `allow_from` are real BlueBubbles config keys (likely under `platforms.bluebubbles.extra.*`) or
> shorthand the architecture doc uses for the `BLUEBUBBLES_ALLOWED_USERS` + allow-all-off allowlist.**
> Encode `BLUEBUBBLES_ALLOWED_USERS` + `BLUEBUBBLES_ALLOW_ALL_USERS=false` (source-confirmed) and add
> `dm_policy`/`group_policy`/`allow_from` per the architecture once confirmed.

`send_read_receipts: true` (default, catalog:601) and `mention_patterns` are **config-only**
(`platforms.bluebubbles.extra.*`) — no env var. `MAX_TEXT_LENGTH=4000`,
`SUPPORTS_MESSAGE_EDITING=false` (so streaming is a no-op on iMessage) (catalog:607,632).

### B.3 — `*_API_KEY` names referenced (INJECTED BY VAULT — not set in .env)

These keys are attached on the wire by agent-vault service rules (home-server:239-243). The hermes VM
holds NONE of them. Listed so the vault config and the injection path are unambiguous:

| Env-var name | Host (agent-vault rule) | Purpose | Placeholder (HANDOFF §3) |
|---|---|---|---|
| `OPENAI_API_KEY` | `api.openai.com` | image gen (gpt-image-2) + vision/web_extract aux | `@@OPENAI_API_KEY@@` |
| `EXA_API_KEY` | `api.exa.ai` | web search/extract | `@@EXA_API_KEY@@` |
| `HONCHO_API_KEY` | `api.honcho.dev` | hosted Honcho memory | `@@HONCHO_API_KEY@@` |
| `GOOGLE_OAUTH_TOKEN` | `*.googleapis.com` | Gmail/Calendar via `gws` (OAuth, auto-refreshed) | `@@GOOGLE_OAUTH_CLIENT_ID@@` / `@@..._SECRET@@` |
| `GITHUB_OAUTH_TOKEN` (or PAT) | `api.github.com` | GitHub | `@@GITHUB_TOKEN@@` |

- All five route through `HTTPS_PROXY` (external hosts) — NOT `NO_PROXY` (catalog:517,524, home-server:239-243).
- `gws` is fed a **dummy** `GOOGLE_WORKSPACE_CLI_TOKEN` (e.g. `__google_oauth__`); agent-vault
  overwrites the `Authorization` header on the wire with the real Google bearer (home-server:266-274).
  Patch `gws_bridge.py` to set the dummy and delete its local refresh logic.
- `APERTURE_STATIC_KEY` (`@@APERTURE_STATIC_KEY@@`, HANDOFF §3) is the static key Aperture presents
  to CLIProxyAPI (ai.nix ↔ CLIProxyAPI) — host/ai-plane, not a hermes-VM secret.

---

## Part C — config.yaml vs .env quick map

| Surface | What lives here |
|---|---|
| **config.yaml (Nix values)** | model, fallback_providers, agent.*, terminal.*, security.*, tool_loop_guardrails.*, browser.*, web.backend, memory.* (+ provider=honcho), stt.* (incl. base_url + dummy key), tts.piper.*, image_gen.*, auxiliary.* routing, compression.*, skills.*, curator.*, delegation.*, privacy.redact_pii, platform_toolsets.*, lsp.*, plugins.enabled, logging.level |
| **honcho.json** | recallMode/dialecticDepth/contextCadence/dialecticCadence/dialecticReasoningLevel, pinUserPeer, peerName, enabled (NOT apiKey) |
| **.env (runtime, non-secret)** | HTTPS_PROXY, HTTP_PROXY, NO_PROXY, SSL_CERT_FILE, NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE, GIT_SSL_CAINFO, BLUEBUBBLES_SERVER_URL/WEBHOOK_HOST/WEBHOOK_PORT/WEBHOOK_PATH/REQUIRE_MENTION/ALLOWED_USERS/ALLOW_ALL_USERS/HOME_CHANNEL |
| **.env (secret placeholders)** | BLUEBUBBLES_PASSWORD (`@@..@@`) — only the BB password; everything else is vault-injected |
| **Injected by vault (in NO config file)** | OPENAI_API_KEY, EXA_API_KEY, HONCHO_API_KEY, GOOGLE_OAUTH_TOKEN, GITHUB_OAUTH_TOKEN; GOOGLE_WORKSPACE_CLI_TOKEN is a dummy set by hermes, overwritten on the wire |

---

## Part D — Notable defaults / non-obvious facts (for the authoring agent)

- `api_mode` for `custom` resolves to `chat_completions` via URL auto-detect — leave unset (catalog:95,172).
- There is **no** `model.temperature` / `model.top_p` key; pin sampling via `providers.<id>.extra_body` if ever needed (catalog:99,176).
- `agent.max_turns`: cli-example ships 60, code/docs default is 90 — we set 90 explicitly (catalog:156,175).
- Managed mode (NixOS) blocks `hermes config set`, `hermes setup`, `hermes gateway install`, dashboard "Save config" — everything is declarative (catalog:822).
- Dashboard has NO `enabled` config key; it's a CLI/process. Loopback bind → no auth gate engages (catalog:826,830,839).
- `session_search` is **no longer** an auxiliary model-routing slot (removed, PR #27590); the search tool reads the DB directly (catalog:808). The architecture's "session_search → main" is therefore a no-op slot.
- Observability plugins fail-open (no-op without creds); simply omit from `plugins.enabled` (catalog:852).
- Gateway autostart = `hermes gateway install --system` (systemd) — there is NO `autostart` config key (catalog:553).
- BlueBubbles streaming is a no-op (`SUPPORTS_MESSAGE_EDITING=false`); leave `streaming.enabled: false` (catalog:632).
```
