# Hermes Configuration Catalog

Every customizable hermes-agent setting, grouped by domain, each with a recommendation for our
locked home-server stack (see [`hermes-home-server.md`](hermes-home-server.md) for the architecture).
This is the companion "knobs" reference to that doc.

**Legend** — 🔒 already decided by the architecture · ❓ a choice you should make · ✅ sensible
default, leave as-is.

> **How these get applied.** Under NixOS (our determinism backbone), almost all of these are set
> **declaratively in the flake** — hermes's NixOS module generates `~/.hermes/config.yaml` via its
> `configMergeScript`, and **managed mode makes `hermes config set` inert by design**. So "set X" below
> means "set X as a Nix value in the flake," not "run a CLI command." Secrets (`*_API_KEY`,
> tokens) are never Nix values — they flow through the credential planes (§5 of the architecture doc).

## Decisions (resolved)

All the big choices are now **locked** — the authoritative ledger is
[`hermes-home-server.md` §10](hermes-home-server.md#10-decisions-table). The catalog's ~120 tunable
keys are otherwise 🔒 (fixed by the architecture) or ✅ (safe default). The groups below record each
decision (✅ = the chosen value) with rationale; per-setting detail is in the linked section:

**Security posture** ([Dashboard, observability & security](#dashboard-observability--security))
- **Web dashboard** — ✅ **enable, tailnet-only, no auth** (Tailscale ACLs gate it; hermes only
  activates dashboard auth when keys are set).
- **`security.allow_private_urls` / `browser.allow_private_urls`** — ✅ **deny by default, allowlist
  specific internal hosts** as needed.
- **`privacy.redact_pii`** — *Rec: on.*
- **`security.tirith_enabled` / `tirith_fail_open`** (policy engine) — *Rec: start disabled; enable
  fail-closed once you've written policies.*
- **`security.allow_lazy_installs`** — *Rec: `false` (deps come from the Nix flake, not runtime installs).*
- **Observability (Langfuse)** — *Rec: off to start; self-host Langfuse later if you want tracing.*

**Sandbox tuning** ([Tools & sandbox](#tools--sandbox))
- **`terminal.docker_image`** (pin it), **`container_cpu`/`container_memory`** (*Rec: 2 CPU / 8 GB*),
  **`docker_run_as_host_user`** (*Rec: true*), **`docker_mount_cwd_to_workspace`** (*Rec: false*),
  **`terminal.lifetime_seconds`** (*Rec: persistent*).
- **MCP servers** — which (if any) to add. *Rec: none initially; Gmail/Calendar go via `gws`+vault, not MCP.*
- **`tool_loop_guardrails.hard_stop_enabled`** — *Rec: `true` for unattended operation.*

**Agent behaviour** ([Core inference, model & runtime](#core-inference-model--runtime) · [Skills, autonomy & environment variables](#skills-autonomy--environment-variables))
- **`agent.max_turns` / `HERMES_MAX_ITERATIONS`** — *Rec: ~90.*
- **Autonomy** — ✅ **maximum**: `subagent_auto_approve: true`, free skill writes, no per-action
  approval prompts (justified by the docker sandbox); keep `tool_loop_guardrails.hard_stop_enabled:
  true` as a runaway/cost guard. `delegation.model` → the chain default.
- **`skills.creation_nudge_interval`** (*Rec: 10*), **`skills.write_approval`** (*Rec: free writes for a
  personal agent*), **`skills.disabled`** / bundles (*Rec: trim later*).
- **`curator.prune_builtins`** — *Rec: default.*

**Memory tuning** ([Memory & personalization](#memory--personalization))
- **Honcho cadence/depth** (`recallMode`, `dialecticDepth`, `contextCadence`, `dialecticCadence`,
  `dialecticReasoningLevel`) — *Rec: hybrid / depth 1 / 2 / 3 / low (the architecture-doc starting
  point); raise only if the recall A/B shows it's needed.*

**Messaging** ([Gateway & messaging platforms](#gateway--messaging-platforms))
- **`platform_toolsets.bluebubbles`** — *Rec: set explicitly to the full messaging bundle.*
- ✅ **`BLUEBUBBLES_REQUIRE_MENTION: false`** (respond to every message in **DMs and groups**),
  **`dm_policy` / `group_policy`: allowlist** + **`allow_from`** (authorized handles only),
  **`send_read_receipts`: on**, **Private API helper: on**, **`BLUEBUBBLES_WEBHOOK_HOST`**: the
  hermes tailnet name.

**Tools & routing** ([Auxiliary models & per-task routing](#auxiliary-models--per-task-routing))
- **Nous Tool Gateway** — ✅ **not used (dropped).** Fully self-directed; the multimodal aux tasks
  route to the `openai` key instead.
- **Auxiliary slot routing** — ✅ `compression` + `session_search` → `main` (`http://ai`);
  `vision` + `web_extract` → **`openai`** (key via vault), since there's no Nous and local Qwen is text-only.

## Contents

1. [Core inference, model & runtime](#core-inference-model--runtime)
2. [Tools & sandbox](#tools--sandbox)
3. [Memory & personalization](#memory--personalization)
4. [Voice & media](#voice--media)
5. [Gateway & messaging platforms](#gateway--messaging-platforms)
6. [Auxiliary models & per-task routing](#auxiliary-models--per-task-routing)
7. [Dashboard, observability & security](#dashboard-observability--security)
8. [Skills, autonomy & environment variables](#skills-autonomy--environment-variables)

---

I have everything needed. The default `api_mode` is `chat_completions` (from `providers/base.py:44`), confirmed for the `custom` provider which uses an OpenAI-compatible wire. Temperature/top_p are not user-facing config keys for the main model — Hermes does not send temperature by default (provider-managed), and there is no `model.temperature`/`model.top_p` key; sampling overrides for custom go through `providers.<id>.extra_body`. Now writing the deliverable.

## Core inference, model & runtime

> Locked stack: `model.provider=custom`, `base_url=http://ai/v1` (Tailscale/Aperture gateway), `default=gpt-5.5`, `fallback_providers=[gemini-3.5, qwen-local]`, failover in hermes. Keys via agent-vault MITM proxy (`HTTPS_PROXY`), `NO_PROXY` excludes `http://ai`. All keys arrive as env vars injected by the proxy, so `key_env` is the right binding everywhere below.

### A. Main model selection (`model:` block)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `model.default` (alias `model.model`; env `HERMES_MODEL`) | The model the agent thinks with on every turn (`cli-config.yaml.example:9-11`). | Any provider-qualified model id | `anthropic/claude-opus-4.6` (`:11`); `""` sentinel on fresh installs until `hermes model` upgrades it to a mapping (`configuring-models.md:20-22`) | 🔒 `gpt-5.5` — your Aperture gateway exposes it as the upstream default; set `model.default: "gpt-5.5"`. |
| `model.provider` (`--provider`) | Inference provider router; `custom` = any OpenAI-compatible endpoint, with `ollama`/`vllm`/`llamacpp` as aliases (`:13-42`). | `auto`, `openrouter`, `nous`, `anthropic`, `custom`, … (full list `:13-33`) | `auto` (`:42`) | 🔒 `custom` — required to point at `http://ai/v1`. Note `main` is **not** valid here (`fallback-providers.md:268`). |
| `model.base_url` (env `OPENAI_BASE_URL`) | Endpoint for `provider: custom` (`:44-46`; env `environment-variables.md:22`). | URL | `https://openrouter.ai/api/v1` (`:46`) | 🔒 `http://ai/v1`. Already in `NO_PROXY` so it bypasses the agent-vault MITM proxy — correct, the gateway is trusted/local. |
| `model.api_key` / `key_env` | Inline key, or the env-var name holding it. For `custom`, auth falls back to `OPENAI_API_KEY` (`:44-45`; `environment-variables.md:21`). | string / env-var name | unset → `OPENAI_API_KEY` | ❓ Aperture is a Tailscale-gated local gateway. If it needs a token, set `key_env` to an agent-vault-injected var (e.g. `key_env: AI_GATEWAY_KEY`); if open on the tailnet, leave unset. Recommend a token. |
| `model.api_mode` (alias `transport`) | Wire protocol for `base_url`: `chat_completions`, `codex_responses`, `anthropic_messages`; empty = auto-detect from URL (`configuration.md:1797`). | those 3 / empty | `chat_completions` (`providers/base.py:44`) | ✅ Leave empty/`chat_completions` — `http://ai/v1` is an OpenAI-wire endpoint; auto-detect resolves correctly. |
| `model.context_length` | TOTAL window (input+output); gates compression + request validation. Auto-detected from the provider's `/v1/models` (`:56-64`). | int (tokens) | unset → auto-detect | ❓ Set manually only if Aperture doesn't expose `/v1/models` or proxies a non-standard `num_ctx`. If gpt-5.5's window doesn't auto-resolve through the gateway, pin it (e.g. `400000`). Otherwise leave unset. |
| `model.max_tokens` | OUTPUT cap per response; unrelated to history length (`:66-73`). | int | unset → model's native ceiling (`:70`) | ✅ Leave unset — use gpt-5.5's native output ceiling. |
| `model.default_headers` | Extra HTTP headers on every OpenAI-wire request; user values override the OpenAI SDK's `User-Agent`/`X-Stainless-*` (`:75-87`). Not applied on native Anthropic/Bedrock. | header map | none | ✅ Leave unset unless Aperture's WAF rejects the SDK `User-Agent` (returns "502 Upstream access forbidden"); then set `User-Agent: "curl/8.7.1"`. |
| (no `model.temperature` / `model.top_p` key) | There is no main-model temperature/top_p config key. Hermes omits temperature by default (provider-managed); sampling overrides for a custom endpoint go via `providers.<id>.extra_body` (`providers/base.py:88-89`; row F). | — | temperature not sent | ✅ Leave default — let gpt-5.5/Aperture manage sampling. Use `providers.ai.extra_body` if you must pin `temperature`/`top_p`. |

### B. Fallback chain (`fallback_providers:`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `fallback_providers` (top-level list) | Per-turn cross-provider failover; each entry needs `provider`+`model`, tried in order on 429/5xx (after retries), 401/403/404 (immediate), or malformed responses (`fallback-providers.md:19-43,100-120`). Subagents + cron inherit it (`:165-171`). | list of `{provider, model, base_url?, key_env?}` | none (no env var — config only, `:172-175`) | 🔒 Set `[{provider, model: gemini-3.5}, {provider: custom, model: qwen-local, base_url, key_env}]`. Failover lives here, matching the stack. |
| `fallback_providers[].provider` / `.model` | Which backup provider+model (`:40`). | see provider table `:48-86` | — | 🔒 gemini-3.5 → use `gemini` (Google AI Studio, `GOOGLE_API_KEY`) or route it through your gateway as `custom`. qwen-local → `provider: custom` + its own `base_url`. |
| `fallback_providers[].base_url` / `.key_env` | Custom-endpoint failover target + env-var holding its key (`:88-98`). | URL / env-var name | — | 🔒 For qwen-local set `base_url` (its in-VM/host endpoint) and `key_env` (agent-vault var) if auth'd. |
| `fallback_model` (singular, legacy) | Legacy single-fallback key; honored for back-compat, superseded by `fallback_providers` (`:42-43`). | one entry | none | ✅ Ignore — `hermes fallback` migrates it; use the plural list. |
| Turn-scoping (behavioral, not a key) | Fallback is per-turn: primary restored each new message; fires at most once per turn (`:119-120`). | — | — | ✅ No action — desirable: every turn retries your local gpt-5.5 primary first. |

### C. Named provider overrides (`providers:` / legacy `custom_providers:`)

> The v12+ keyed `providers:` map and the legacy `custom_providers:` list normalize to the same shape (`config.py:3784-3939`, `inventory.py:8-19`). Per-provider keys: `api`/`url`/`base_url`, `api_key`, `key_env` (aliases `api_key_env`/`apiKeyEnv`), `api_mode`/`transport`, `model`/`default_model`, `models`, `context_length`, `rate_limit_delay`, `request_timeout_seconds`, `stale_timeout_seconds`, `discover_models`, `extra_body` (`config.py:3799-3804`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `providers.<id>.request_timeout_seconds` | Per-provider request timeout; wins over `HERMES_API_TIMEOUT`; applies to primary, fallback, and rebuilds (`cli-config.yaml.example:89-101`; `configuration.md:82`). Not wired for Bedrock (`:103-104`). | seconds | unset → 1800s | ❓ For a local gpt-5.5 with long prefills set `providers.ai.request_timeout_seconds: 600`; for cloud fallbacks (gemini) set ~120 for fast failover. Default 1800 is otherwise fine. |
| `providers.<id>.stale_timeout_seconds` | Non-streaming stale-call detector; wins over `HERMES_API_CALL_STALE_TIMEOUT`; auto-disabled on local endpoints unless explicitly set (`:98-101`; `configuration.md:826,833`). | seconds | unset → 300s (auto-disabled for local) | ✅ Leave unset for the local gateway (auto-disable avoids false kills during prefill). Set explicitly only if a hung local call needs a hard cap. |
| `providers.<id>.models.<model>.timeout_seconds` / `.stale_timeout_seconds` | Per-model timeout/stale overrides under a provider (`:112-118`). | seconds | inherits provider value | ✅ Leave unset; add only if a specific reasoning-heavy model needs a longer cap. |
| `providers.<id>.rate_limit_delay` (alias `rateLimitDelay`) | Minimum delay (seconds) the client paces between requests to that provider (`config.py:3792,3891-3893`). | float ≥ 0 | unset (no throttle) | ✅ Leave unset for a local single-user gateway — no rate limit to respect. Set a small delay only if a cloud fallback (gemini-3.5) free tier throttles you. |
| `providers.<id>.context_length` / `.models.<m>.context_length` | Per-provider/per-model window override consulted for display + compression when `model.context_length` is unset (`config.py:3887-3889,4006-4059`). | int > 0 | unset → auto-detect | ✅ Use instead of `model.context_length` if you keep multiple custom models on one `providers.ai` entry with different windows. |
| `providers.<id>.discover_models` | Whether to probe `/v1/models` to enumerate the provider's catalog (`config.py:3895-3897`). | bool | unset (default discovery) | ✅ Set `false` for `providers.ai` if Aperture doesn't serve `/v1/models` (avoids a failing probe); pair with explicit `models:` + `context_length`. |
| `providers.<id>.extra_body` | Verbatim OpenAI-wire request-body fields merged into every call to that provider (`config.py:3899-3901`; shape `configuration.md:1036-1047`). | dict | `{}` | ❓ This is the only path to pin main-model sampling on `custom`: e.g. `providers.ai.extra_body: {temperature: 0.7}` or reasoning toggles. Leave empty unless gpt-5.5 needs it. |
| `providers.<id>.api_key` / `key_env` / `api_mode` / `models` | Per-provider key, env-var name, wire protocol, curated model list (`config.py:3859-3885`). | strings / dict | `api_mode` → `chat_completions` | ❓ Optional: define a `providers.ai` block to give the gateway a friendly name, pin `key_env`, and list `models: {gpt-5.5: {}, ...}` so `/model` shows them. Cleaner than bare `model.base_url`. |

### D. Retries, backoff & rate-limit handling (`agent.api_max_retries`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `agent.api_max_retries` | Hermes-level retries on transient errors (429/connection/5xx) **before** fallback engages; SDK does its own low-level retries underneath (`cli-config.yaml.example:619-623`; default `config.py:842`, `agent_init.py:1232`). | int (0+) | `3` → 4 attempts total (`configuration.md:816`) | ❓ With your two fallbacks configured, set `agent.api_max_retries: 1` for fast failover gpt-5.5 → gemini-3.5 instead of churning 4 attempts on a flaky primary. Keep `3` if you prefer retrying the local primary. |
| Backoff (behavioral; `agent/retry_utils.py`) | Jittered exponential backoff between retries: `min(base·2^(n-1), cap)+jitter` (`retry_utils.py:19-57`). | `base_delay=5.0s`, `max_delay` cap, `jitter_ratio=0.5` | base 5s, jitter uniform [0, 0.5·delay] | ✅ Not user-configurable — defaults are sane. No action. |
| SDK low-level retries (behavioral) | Hermes forces the OpenAI SDK's own `max_retries=0` so its loop owns rotation/fallback/backoff (`run_agent.py:3632-3638`). | — | 0 (Hermes wrapper handles it) | ✅ No action — single source of retry truth. |
| `HERMES_API_TIMEOUT` (env) | Legacy global non-streaming API-call timeout; superseded by `providers.<id>.request_timeout_seconds` (`run_agent.py:1097`; `environment-variables.md:608`). | seconds | `1800` | 🔒 Prefer the per-provider config key (row C). Env var only as a global fallback. |
| `HERMES_API_CALL_STALE_TIMEOUT` (env) | Legacy global non-stream stale timeout; superseded by `providers.<id>.stale_timeout_seconds` (`run_agent.py:1121`; `environment-variables.md:609`). | seconds | `300` (auto-disabled for local) | ✅ Leave unset; use per-provider key if needed. |
| `HERMES_STREAM_READ_TIMEOUT` (env) | Streaming socket read timeout; auto-raised to `HERMES_API_TIMEOUT` for local endpoints (`environment-variables.md:610`; `configuration.md:824,829`). | seconds | `120` (→1800 for local) | ✅ Leave unset — auto-raise covers local gpt-5.5 long prefills. |
| `HERMES_STREAM_STALE_TIMEOUT` (env) | Kills streams getting keep-alive pings but no content; auto-disabled for local (`environment-variables.md:611`; `configuration.md:825,831`). | seconds | `180` (auto-disabled local) | ✅ Leave unset — auto-disable is correct for the local gateway. |

### E. Reasoning / thinking effort (`agent.reasoning_effort`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `agent.reasoning_effort` | How much the model "thinks" before answering (OpenRouter & Nous; adaptive models map it to OpenRouter `verbosity`) (`cli-config.yaml.example:628-631`; `configuration.md:1181-1198`). | `none`, `minimal`, `low`, `medium`, `high`, `xhigh` (max); `""`=medium | `medium` (`config.py` slot empty ⇒ medium, `:631`/`configuration.md:1185`) | ❓ gpt-5.5 reaches Hermes as an OpenAI-wire `custom` provider, which does **not** apply the OpenRouter/Nous effort path — verify the gateway accepts `reasoning_effort`/maps it. If unsupported, control reasoning via `providers.ai.extra_body` (e.g. `reasoning_effort`/`reasoning`). Default `medium` is a fine starting point. |
| `display.show_reasoning` / `/reasoning show` | Whether the reasoning box renders in the CLI (`cli-config.yaml.example:1047-1052`). | bool | `false` | ✅ Leave `false` (single-user local; toggle live with `/reasoning` when debugging). |

### F. Context window, compression & iteration budget

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `compression.enabled` | Auto-summarize middle turns near the context limit; off = errors on overflow (`cli-config.yaml.example:374-377`). | bool | `true` | ✅ Keep `true` — privacy-local but long sessions still need it. |
| `compression.threshold` | Fraction of `context_length` that triggers compression (`:379-381`). | 0–1 | `0.50` | ✅ `0.50` is fine. With gpt-5.5's large window, you could raise to `0.6–0.7` to compress later; default is safe. |
| `compression.target_ratio` | Recent tail preserved = `target_ratio × threshold × context_length`; summary capped at 12K (`:383-387`). | `0.10`–`0.80` | `0.20` | ✅ Leave `0.20`. |
| `compression.protect_last_n` | Most-recent messages never summarized (`:389-392`). | int | `20` (~10 turns) | ✅ Leave `20`. |
| `compression.protect_first_n` | Non-system head messages pinned forever (besides the system prompt) (`:394-404`). | int (0+) | `3` | ❓ For an always-on long-running agent, set `0` (cleanest rolling compaction — only system prompt + summary + tail survive). Keep `3` for short sessions. |
| `auxiliary.compression.provider` / `.model` | Model that writes compression summaries; must have a window ≥ main model's (`fallback-providers.md:344-353`; `configuration.md:771-772`). Legacy `compression.summary_model/_provider/_base_url` auto-migrate (config v17). | `auto`/`main`/`openrouter`/`nous`/`custom` + model | `auto` (uses main model) | ❓ Compression doesn't need reasoning — route it to a cheap, large-context model. Point at `provider: custom, model: qwen-local` (your local fallback) or `gemini-3.5` to keep summaries off gpt-5.5. Ensure its window ≥ gpt-5.5's. |
| `context.engine` | Context-management strategy; `compressor` = built-in lossy summarization, plugins (e.g. `lcm`) opt-in (`configuration.md:777-791`). | `compressor` / plugin name | `compressor` | ✅ Keep `compressor` unless you install a lossless context plugin. |
| `agent.max_turns` | Max tool-calling iterations per turn; budget-pressure warnings at 70%/90% (`cli-config.yaml.example:596-600`; `configuration.md:797-814`). | int (20–100 guidance) | `60` in example (`:600`); `90` is the code/docs default (`configuration.md:797,808`) — example ships a lower value | ❓ Reconcile the mismatch: example says 60, code default is 90. For an autonomous home agent set `60–90`; pick `90` for open exploration, `60` for focused/cost-bounded runs. |
| `agent.gateway_timeout` / `_warning` / `restart_drain_timeout` | Gateway-only inactivity timeout (0=unlimited), staged warning, graceful drain on restart (`cli-config.yaml.example:602-616`). | seconds | commented: 1800 / 900 / 60 | ✅ Defaults fine for an always-on server; leave commented unless runaway runs are a concern. |
| `prompt_caching.cache_ttl` | Anthropic prompt-cache prefix TTL tier; other values ignored → "5m" (`cli-config.yaml.example:411-417`; `config.py:1187-1188`). | `"5m"`, `"1h"` | `"5m"` | ✅ Only applies to Claude via OpenRouter/native Anthropic. gpt-5.5 over `custom` doesn't use it → no effect; leave `"5m"`. |
| `openrouter.response_cache` / `_ttl` | OpenRouter edge response cache (`cli-config.yaml.example:154-156`; `config.py:1196-1208`). | bool / 1–86400s | `true` / `300` | ✅ OpenRouter-only — not on your `custom` path. No action. |
| `provider_routing.*` | OpenRouter cross-provider routing (sort/only/ignore/order) (`cli-config.yaml.example:126-144`). | — | unset | 🔒 OpenRouter-only — irrelevant on `provider: custom`. No action. |

### G. Related runtime knobs adjacent to the model plane

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `model_aliases.<name>` (or `model.aliases.<name>`) | Short `/model` aliases → `(model, provider, base_url)`; checked before the catalog (`cli-config.yaml.example:1110-1129`; `configuring-models.md:181-203`). | map | none | ❓ Add aliases for your three models, e.g. `gpt55 → {model: gpt-5.5, provider: custom, base_url: http://ai/v1}`, `qwen → qwen-local`, so live `/model` swaps are one word. |
| `model_catalog.enabled` / `url` / `ttl_hours` / `providers` | Remote curated picker manifest for OpenRouter/Nous; falls back to in-repo snapshot offline (`model-catalog.md:67-89`). | bool / URL / hours / map | `true` / Nous URL / `1` | ✅ Harmless on `custom` (only curates OR/Nous picker lists). Privacy-conscious users can set `enabled: false` to stop the periodic fetch. |
| `agent.api_max_retries` interaction note | With fallbacks set, retries gate **before** failover (`configuration.md:816`). | — | — | (covered in D) — lower to `1` for snappy failover. |
| `delegation.provider` / `.model` / `.base_url` / `.api_key` | Override provider+model for subagents (else inherit parent + its fallback chain) (`cli-config.yaml.example:935-938`; `fallback-providers.md:363-375`). | provider/model/URL | empty = inherit parent | ❓ If you spawn subagents, route them to a cheaper model (qwen-local / gemini-3.5) to keep gpt-5.5 for the main loop; otherwise inherit. |

**Footnotes / non-obvious defaults**
- `api_mode` default `chat_completions` is the dataclass default in `providers/base.py:44`; the example/config is silent. `custom` over `http://ai/v1` resolves to it via URL auto-detect.
- `agent.api_max_retries` default `3` is set in `hermes_cli/config.py:842` and `agent/agent_init.py:1232`, confirmed in `configuration.md:816` ("four attempts total").
- Backoff constants (`base_delay=5.0`, `jitter_ratio=0.5`) are hardcoded in `agent/retry_utils.py:19-57` and not exposed as config.
- `agent.max_turns`: the shipped `cli-config.yaml.example:600` sets `60`, but the documented/code default is `90` (`configuration.md:797,808`) — the example overrides the code default. Treat `90` as the true unset default.
- There is no main-model `temperature`/`top_p` config key; Hermes omits temperature by default (provider-managed, `providers/base.py:88-89`). Pin sampling for `custom` via `providers.<id>.extra_body` only.
- `reasoning_effort` is applied on the OpenRouter/Nous paths; a `custom` OpenAI-wire endpoint may ignore it (unconfirmed for your Aperture gateway) — verify, and fall back to `providers.ai.extra_body` if so.


---

I have `agent.disabled_toolsets` as an additional global toolset-disable key. I now have complete, authoritative coverage. Writing the deliverable.

## Tools & sandbox

All defaults below are from `/tmp/hermes-agent-ref/cli-config.yaml.example` unless the source is cited explicitly (the example is silent on browser/web/file/lsp defaults, so those are taken from source).

### Terminal / shell sandbox (`terminal.*`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `terminal.backend` | Where shell commands execute (`terminal`, `process` tools). `cli-config.yaml.example:182` | `local`, `ssh`, `docker`, `singularity`, `modal`, `daytona` | `local` | 🔒 `docker` — locked stack runs the in-VM Docker sandbox. |
| `terminal.cwd` | Working dir. For `docker` it's the path **inside** the container. `cli-config.yaml.example:183,217` | any path | `.` (local); `/` for docker | 🔒 `/workspace` — standard mount point; pair with `docker_mount_cwd_to_workspace`. |
| `terminal.timeout` | Per-command wall-clock timeout (seconds). `cli-config.yaml.example:184` | seconds | `180` | ✅ Leave at 180; raise only if you run long builds. |
| `terminal.lifetime_seconds` | How long an idle sandbox/container stays alive before teardown. `cli-config.yaml.example:191` | seconds | `300` | ❓ `300` is fine for interactive; for an always-on assistant that re-runs commands frequently, consider `900`–`1800` to avoid cold-start churn. |
| `terminal.home_mode` | HOME used by tool subprocesses. `cli-config.yaml.example:185-189` | `auto`, `real`, `profile` | `auto` (containers use `HERMES_HOME/home`) | ✅ `auto` — correct for Docker backend. |
| `terminal.docker_image` | Image the docker backend runs. `cli-config.yaml.example:220` | any image ref | `nikolaik/python-nodejs:python3.11-nodejs20` (example) | ❓ Default image covers Python+Node. Pin a versioned/own image if you want determinism or extra toolchains. |
| `terminal.docker_mount_cwd_to_workspace` | Bind-mount the launch cwd into `/workspace`. SECURITY: off by default. `cli-config.yaml.example:190,221` | `true`/`false` | `false` | ❓ `true` if you want the agent to operate on host-VM files in cwd; `false` keeps the container fully isolated. For a coding/file assistant, `true`. |
| `terminal.docker_run_as_host_user` | Run container as host uid:gid so bind-mounted files aren't root-owned; also drops SETUID/SETGID caps. `cli-config.yaml.example:222-226` | `true`/`false` | `false` (runs as image default, usually root) | ❓ `true` if you enable the cwd mount (avoids root-owned files); leave `false` if the image expects root and you don't mount. |
| `terminal.docker_forward_env` | Allowlist of env vars forwarded into the container (from shell, then `~/.hermes/.env`). `cli-config.yaml.example:227-232` | list of var names | `[]` (none) | ✅ Empty — secrets reach the agent via the agent-vault `HTTPS_PROXY`, not env. Add only non-secret build tokens if a task needs them. |
| `terminal.docker_extra_args` | Extra flags appended verbatim to `docker run` after the security defaults. `cli-config.yaml.example:233-238` | list of strings | `[]` | ✅ Empty. Add `--cap-add SETUID` etc. only if an in-container `apt install` needs it. |
| `terminal.container_cpu` | CPU cores for container backends (ignored for local/ssh). `cli-config.yaml.example:282` | cores | `1` | ❓ `1` is tight for builds on Apple Silicon; bump to `2`–`4` given the always-on host has headroom. |
| `terminal.container_memory` | Container memory (MB). `cli-config.yaml.example:283` | MB | `5120` (5 GB) | ✅ 5 GB is reasonable; raise if browser-in-Docker or heavy builds OOM. |
| `terminal.container_disk` | Container disk (MB). `cli-config.yaml.example:284` | MB | `51200` (50 GB) | ✅ 50 GB default. |
| `terminal.container_persistent` | Persist container filesystem across sessions. `cli-config.yaml.example:285` | `true`/`false` | `true` | ✅ `true` — matches an always-on, stateful assistant; installed tools/venvs survive. |
| `terminal.sudo_password` | Password piped via `sudo -S`. Plaintext. Empty-string = try empty + never prompt. `cli-config.yaml.example:192-193,313` | string / `""` / unset | unset (interactive prompt) | 🔒 Run as root inside the Docker container (no sudo needed) — leave unset. The interactive prompt can't be answered in a headless gateway anyway. |
| `terminal.env_passthrough` | Allowlist of extra env vars passed into `terminal` **and** `execute_code` children (incl. otherwise-stripped `HERMES_*`). `code-execution.md:211-218,256-261` | list of var names | `[]` | ✅ Empty unless a specific non-skill task needs a `HERMES_*` var; secrets go through the proxy, not here. |
| `terminal.ssh_*` / `singularity_image` / `modal_image` / `daytona_image` | Backend-specific connection/image keys for the non-docker backends. `cli-config.yaml.example:205-208,250,262,275` | per-backend | — | 🔒 N/A — backend is `docker`. |

### Command-security scanning & loop guardrails

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| (built-in) dangerous-command approval | Pre-exec guard flags risky commands; interactive CLI prompts for approval, gateway uses ask-mode (`status: pending_approval`). Lives in the terminal tool's guard layer, not a config key. | — | always on | ✅ No config; keep on. In a headless gateway, flagged commands surface as pending-approval and need a UI/messaging confirm — relevant for BlueBubbles autonomy. |
| `security.tirith_enabled` | Optional pre-exec scanner (homograph URLs, pipe-to-shell, terminal injection, env manipulation) via the `tirith` binary. `cli-config.yaml.example:323-327` | `true`/`false` | unset → disabled (block commented out) | ❓ Recommended **on** for a privacy/security-focused box: `brew install`/nix the `tirith` binary, set `tirith_enabled: true`. Alternative: skip if you don't want the extra dependency. |
| `security.tirith_path` | Path to the `tirith` binary. `cli-config.yaml.example:325` | path | `tirith` (PATH lookup) | ✅ Leave default once installed on PATH in the VM. |
| `security.tirith_timeout` | Scan timeout (seconds). `cli-config.yaml.example:326` | seconds | `5` | ✅ 5s. |
| `security.tirith_fail_open` | Allow the command if tirith is unavailable. `cli-config.yaml.example:327` | `true`/`false` | `true` | ❓ `true` = availability over strictness (default). For a hardened box, `false` (fail-closed) so a missing scanner can't silently disable protection. |
| `tool_loop_guardrails.warnings_enabled` | Append soft guidance after repeated failing/non-progressing tool calls (tool still runs). `cli-config.yaml.example:344-345` | `true`/`false` | `true` | ✅ Keep on. |
| `tool_loop_guardrails.hard_stop_enabled` | Circuit-breaker that **stops** a runaway tool loop. `cli-config.yaml.example:346` | `true`/`false` | `false` | ❓ `true` for unattended cron/BlueBubbles sessions (stops burning the iteration budget); `false` for interactive CLI where you'd rather it keep trying. |
| `tool_loop_guardrails.warn_after.{exact_failure,same_tool_failure,idempotent_no_progress}` | Thresholds (call counts) that trigger soft warnings. `cli-config.yaml.example:347-350` | ints | `2 / 3 / 2` | ✅ Defaults. |
| `tool_loop_guardrails.hard_stop_after.{exact_failure,same_tool_failure,idempotent_no_progress}` | Thresholds that trigger the hard stop (only when `hard_stop_enabled`). `cli-config.yaml.example:351-354` | ints | `5 / 8 / 5` | ✅ Defaults if you enable hard stop. |

### File tools & file safety

`file_safety` is enforced in code (`agent/file_safety.py`, `tools/file_tools.py`) — protected-path blocks (`.env`, secrets, cross-profile dirs, Hermes internals, device paths, binary guard, secret redaction) are **always on and not config-tunable**. The only tunable file knob:

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `file_read_max_chars` (top-level) | Caps characters `read_file` returns to the model; oversized reads are blocked with a safety message. `file_tools.py:33-58` | int chars | `100000` (`_DEFAULT_MAX_READ_CHARS`) | ✅ 100k. Raise to ~200k (the documented example value) only if you routinely read very large files; costs context tokens. |
| `read_file` / `write_file` / `patch` / `search_files` | The `file` toolset's tools (read, write, byte-accurate patch, ripgrep search). `toolsets-reference.md:65` | enabled via `file` toolset | enabled in `hermes-cli` | 🔒 On — bundled in `hermes-cli`; the agent needs file access on a local-first box. |
| `write_file` / `patch` post-write check | Runs syntax check + LSP diagnostics on every successful write (see LSP below). | — | on (LSP gated on git repo) | ✅ Automatic; no separate file-safety key. |
| cross-profile write guard | Soft-blocks writes into another Hermes profile's dirs; agent overrides with `cross_profile=true` only after explicit user direction. `file_tools.py:1496-1498` | per-call arg, not config | guard on | ✅ Single-user, single-profile → never trips; leave as-is. |

### LSP / code semantic diagnostics (`lsp.*`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `lsp.enabled` | Master toggle for the language-server subsystem feeding diagnostics into `write_file`/`patch`. `lsp.md:124-127` | `true`/`false` | `true` | ✅ `true` — adds type/semantic errors after edits at ~ms cost; gated to git repos so it's dormant otherwise. |
| `lsp.wait_mode` | Diagnostic-wait granularity after a write. `lsp.md:130` | `document`, `full` | `document` | ✅ `document`. |
| `lsp.wait_timeout` | Seconds to wait for diagnostics after each write. `lsp.md:131` | seconds | `5.0` | ✅ 5s (rust-analyzer cold-index may exceed; that's fine — falls back). |
| `lsp.install_strategy` | How missing servers are obtained. `lsp.md:133-136` | `auto`, `manual` | `auto` (installs into `<HERMES_HOME>/lsp/bin`) | ❓ `auto` is convenient but does npm/go installs at runtime. On a deterministic NixOS VM prefer `manual` and provide the language servers (incl. `nixd`) via Nix; then nothing self-installs. |
| `lsp.servers.<id>.disabled` | Skip one server even when its extensions match. `lsp.md:154` | `true`/`false` | `false` | ✅ Default; disable individual servers you'll never use. |
| `lsp.servers.<id>.command` | Pin a custom binary path (bypasses auto-install). `lsp.md:156` | `[bin, ...args]` | auto-resolved | ❓ With `install_strategy: manual` + Nix, pin each server's Nix store path here. |
| `lsp.servers.<id>.env` | Extra env vars for the spawned server. `lsp.md:158` | mapping | `{}` | ✅ Default. |
| `lsp.servers.<id>.initialization_options` | Merged into the LSP `initialize` payload (e.g. pyright `typeCheckingMode`). `lsp.md:159-161` | mapping | `{}` | ✅ Default unless you want strict type-checking. |

### Code-execution sandbox (`code_execution.*`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `code_execution.mode` | Where `execute_code` scripts run / which interpreter. `code-execution.md:131-146` | `project`, `strict` | `project` | ❓ `project` (default) so `import`s and relative paths match `terminal()`. Use `strict` only if you want every script quarantined from the project tree with a fixed interpreter. |
| `code_execution.timeout` | Max seconds per script (SIGTERM then SIGKILL). `cli-config.yaml.example:914` | seconds | `300` | ✅ 5 min. |
| `code_execution.max_tool_calls` | Max RPC tool calls per script execution. `cli-config.yaml.example:915` | int | `50` | ✅ 50. |
| (capability gate) `execute_code` env scrubbing | Child env strips `KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL/AUTH`; only safe vars pass. `code-execution.md:199-205` | — | always on | 🔒 Keep — secrets must flow via the agent-vault proxy, never the sandbox env. Linux/macOS only (auto-disabled on Windows; N/A on the Linux VM). |

### Browser (`browser.*`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `browser.cloud_provider` | Force a cloud browser backend. When unset, auto-detected from credentials; if none, falls back to local `agent-browser`. `browser_tool.py:489-591` | `browserbase`, `browser-use`, `firecrawl`, (unset) | unset → local/auto (`browser_tool.py:516-590`) | 🔒 Leave unset — locked stack uses local in-VM Chromium via `agent-browser`. |
| `browser.engine` / `AGENT_BROWSER_ENGINE` | Local browser engine. `browser_tool.py:638-683`, `.env.example:267-274` | `auto`, `chrome`, `lightpanda` | `auto` (= Chrome) (`browser_tool.py:656`) | ✅ `auto`/`chrome` for full fidelity + screenshots. `lightpanda` is faster but has no screenshots — not worth it for a general assistant. |
| `browser.cdp_url` / `BROWSER_CDP_URL` | Attach browser tools to a running Chromium-family browser via CDP; also unlocks `browser_cdp` + `browser_dialog`. `browser_tool.py:289-307` | ws/http endpoint | unset | ✅ Unset — in-VM Chromium is launched by `agent-browser`. Set only if you point it at a specific persistent CDP endpoint. |
| `browser.inactivity_timeout` / `BROWSER_INACTIVITY_TIMEOUT` | Auto-close idle browser sessions (seconds). `cli-config.yaml.example:335`, `.env.example:280-282` | seconds | `120` (2 min) | ✅ 120s. |
| `browser.allow_private_urls` | Let the browser navigate to private/internal/LAN addresses (SSRF guard off). `browser_tool.py:1111-1133` | `true`/`false` | `false` | ❓ With local Chromium and no cloud provider, private URLs already work, so keep `false` (SSRF guard on). Set `true` only if you must hit LAN hosts the guard blocks. |
| `browser.auto_local_for_private_urls` | When a cloud provider is set, spawn a local sidecar for private URLs. `browser.md:89-110`, `browser_tool.py:971-983` | `true`/`false` | `true` | ✅ Moot with no cloud provider; leave default. |
| `browser.dialog_policy` | How native JS dialogs (alert/confirm/prompt) are handled. `browser.md:584-590`, `browser_supervisor.py:47` | `must_respond`, `auto_dismiss`, `auto_accept` | `must_respond` (`DEFAULT_DIALOG_POLICY`) | ✅ `must_respond` for interactive control. `auto_dismiss` only for unattended scraping. (Active only on a CDP-capable backend — i.e. if you use `cdp_url`.) |
| `browser.dialog_timeout_s` | Safety auto-dismiss after this long with no `browser_dialog()` response. `browser.md:588`, `browser_supervisor.py:48` | seconds | `300.0` (`DEFAULT_DIALOG_TIMEOUT_S`) | ✅ 300s. |
| `browser.record_sessions` | Record browser sessions to WebM in `~/.hermes/browser_recordings/`. `browser.md:625-630` | `true`/`false` | `false` | ✅ `false` — privacy-focused; enable only for debugging. |
| `BROWSER_SESSION_TIMEOUT` | Cloud-session lifetime (seconds). `.env.example:276-278` | seconds | `300` | 🔒 N/A (no cloud provider). |
| `AGENT_BROWSER_ARGS` | Extra Chromium launch flags; setting it disables Hermes's auto-injected `--no-sandbox`/`--disable-dev-shm-usage`. `browser.md:405-410` | comma/newline list | unset (auto-inject) | ❓ Leave unset so Hermes auto-injects the right flags for a containerized/root VM. Set explicitly only if a specific flag is required (and then re-add `--no-sandbox` yourself). |
| `browser.camofox.*`, `BROWSERBASE_*`, `BROWSER_USE_API_KEY`, `FIRECRAWL_*` (browser) | Camofox/Browserbase/Browser Use/Firecrawl cloud-browser config. `browser.md:40-301` | per-provider | unset | 🔒 N/A — local Chromium only. |

### Web search & extract (`web.*`)

Exa needs only `EXA_API_KEY` (no nested `web.exa` block). Source order: per-capability key → `web.backend` → env auto-detect (`web-search.md:349-353`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `web.backend` | Single backend for both search and extract. `web-search.md:330-333` | `firecrawl`, `searxng`, `brave-free`, `ddgs`, `tavily`, `exa`, `parallel`, `xai` | unset → auto-detect from env | 🔒 `exa` — locked stack uses Exa for both search and extract (Exa supports both per `web-search.md:26`). |
| `web.search_backend` | Per-capability override for `web_search`. `web-search.md:340-344` | same set | unset → `web.backend` | ✅ Redundant if `web.backend: exa`. Set only to split providers (e.g. SearXNG search + Exa extract). |
| `web.extract_backend` | Per-capability override for `web_extract`. `web-search.md:340-345` | `firecrawl`,`tavily`,`exa`,`parallel` | unset → `web.backend` | ✅ Covered by `web.backend: exa`. |
| `EXA_API_KEY` | Exa credential. `web-search.md:255-260`, `.env.example:133` | key | unset | 🔒 Provided via agent-vault proxy injection (locked stack). |
| `web.xai.{model,allowed_domains,excluded_domains,timeout}` | xAI Grok web-search knobs (only when `backend: xai`). `web-search.md:304-314` | per-keys | `grok-4.3`, none, none, `90` | 🔒 N/A — backend is Exa. |
| `auxiliary.web_extract.{provider,model,timeout}` | Model that summarizes long extracted pages (>5k chars). `web-search.md:59-70`, `cli-config.yaml.example:464-467` | provider/model | `auto` → main chat model; timeout `360`/`30` | ❓ Default routes long-page summaries through `gpt-5.5` (your main) — costly. Recommended: point at a cheap fast model (e.g. via the `gemini-3.5` fallback or `qwen-local`) to cut extract cost. |
| `WEB_TOOLS_DEBUG` | Verbose web-tool logging to `./logs`. `web_tools.py:24-27` | `true`/`false` | unset | ✅ Off. |

### MCP servers (`mcp_servers.<name>.*`)

Per-server config shape (`mcp-config-reference.md:16-62`). Default global: none configured.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `mcp_servers.<n>.command` / `args` / `env` | Stdio server: executable, args, and the **only** env vars (+ safe defaults) passed to the subprocess. `mcp-config-reference.md:48-50` | strings/list/map | — | ❓ Use stdio for local tools (filesystem, git). `env` is where a stdio server gets its secrets — prefer pulling them through the vault rather than inlining. |
| `mcp_servers.<n>.url` / `headers` | HTTP server endpoint + request headers (e.g. `Authorization`). `mcp-config-reference.md:51-52` | string/map | — | ❓ Use `url` for the Nous Tool Gateway and other hosted MCP. Note: `NO_PROXY` excludes `http://ai`, so MCP HTTP traffic still flows through the vault proxy unless you exclude its host too. |
| `mcp_servers.<n>.auth` | OAuth 2.1 PKCE for HTTP servers; tokens cached to `~/.hermes/mcp-tokens/<server>.json`. `mcp-config-reference.md:61,276-292` | `oauth` / unset | unset | ❓ Set `oauth` for providers that require it (first connect opens a browser — needs an interactive path in the VM). |
| `mcp_servers.<n>.ssl_verify` | TLS verification for HTTP/SSE. `mcp-config-reference.md:53` | `true`, `false`, CA-bundle path | `true` | ✅ `true`. Use a CA-path for a private CA; never `false` on real services. |
| `mcp_servers.<n>.client_cert` / `client_key` | mTLS client cert (PEM, `[cert,key]`, or `[cert,key,pass]`). `mcp-config-reference.md:54-55` | path/list | unset | ✅ Only if a server requires mTLS. |
| `mcp_servers.<n>.enabled` | Skip the server entirely without deleting config. `mcp-config-reference.md:56` | `true`/`false` | `true` | ✅ `true`; flip `false` to park a server. |
| `mcp_servers.<n>.timeout` / `connect_timeout` | Tool-call / initial-connection timeouts (seconds). `mcp-config-reference.md:57-58` | seconds | `120` / `60` | ✅ Defaults. |
| `mcp_servers.<n>.supports_parallel_tool_calls` | Allow this server's tools to run concurrently. `mcp-config-reference.md:59` | `true`/`false` | `false` | ✅ `false` unless a server is known-safe for concurrency. |
| `mcp_servers.<n>.tools.{include,exclude}` | Whitelist / blacklist server-native tools (`include` wins; use original hyphen/dot names). `mcp-config-reference.md:64-105` | string/list | none (all) | ❓ Recommended: `include` an allowlist on any write-capable server (least privilege), per the GitHub/Stripe examples. |
| `mcp_servers.<n>.tools.{resources,prompts}` | Enable/disable the `list_/read_resource` and `list_/get_prompt` utility wrappers. `mcp-config-reference.md:69-71` | bool-like | `true` (capability-gated) | ✅ Leave on; set `false` to trim tool surface. |
| `mcp_servers.<n>.sampling.{enabled,model,max_tokens_cap,timeout,max_rpm,allowed_models,max_tool_rounds,log_level}` | Policy for server-initiated LLM requests. `cli-config.yaml.example:836-849` | per-keys | `enabled: true`, model auto, cap/`4096`, `30`, `10`, `[]`, `5`, `info` | ❓ Sampling lets an MCP server drive your model — for a privacy box, set `enabled: false` on servers you don't trust, or cap `max_rpm`/`allowed_models`. |
| (runtime) `mcp-<name>` toolset | Each configured server auto-generates a toolset usable in `platform_toolsets`/`--toolsets`. `toolsets-reference.md:122-134` | — | created per server | ✅ Reference it to scope which platforms see a server's tools. |

### Toolset enable/disable & autonomy gating

Core toolsets (`toolsets-reference.md:53-87`): `browser`, `clarify`, `code_execution`, `cronjob`, `delegation`, `file`, `homeassistant`, `computer_use`, `context_engine`, `image_gen`, `video_gen`, `kanban`, `memory`, `messaging`, `moa`, `safe`, `search`, `session_search`, `skills`, `spotify`, `terminal`, `todo`, `tts`, `vision`, `video`, `web`, `x_search`, `yuanbao`, plus platform-specific (`discord`, `feishu_*`). Composites: `debugging` (file+terminal+web), `safe` (web+vision+moa+image_gen, read-only), `all`/`*` (everything except capability- and workflow-gated tools). The deprecated top-level `toolsets:` key is ignored — use `platform_toolsets`.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `platform_toolsets.cli` | Toolset(s) for interactive CLI sessions. `cli-config.yaml.example:699-700` | preset or list of toolsets | `[hermes-cli]` (full) | 🔒 `[hermes-cli]` — CLI is a locked messaging surface; keep the full toolset. |
| `platform_toolsets.<bluebubbles…>` | BlueBubbles uses the `hermes-bluebubbles` preset (= `hermes-cli`). Not a default key in the example; add it to scope. `toolsets-reference.md:108` | preset or list | `hermes-bluebubbles` (built-in) | ❓ Default mirrors CLI (full power over iMessage). For a phone surface, consider trimming to e.g. `[web, terminal, file, todo, image_gen, tts, send_message]` and dropping `browser`/`delegation`/`code_execution` to reduce blast radius. |
| `platform_toolsets.<other platforms>` | Per-platform toolsets for telegram/discord/slack/etc. `cli-config.yaml.example:701-710` | preset or list | per-platform presets | 🔒 Other messaging is OFF (locked stack: CLI + BlueBubbles only) — don't run those gateways; leave keys unused. |
| `custom_toolsets.<name>` | Define a named bundle of toolsets to reference. `toolsets-reference.md:144-154` | map of name → list | none | ✅ Optional; define one if you want a reusable BlueBubbles bundle. |
| `agent.disabled_toolsets` | Globally disable named toolsets regardless of platform config. `tools_config.py:1529-1536` | list of toolset names | `[]` | ❓ Use to hard-off anything you never want, e.g. `[x_search, spotify, homeassistant]` on a minimal box. |
| per-tool disable (`hermes tools`) | Curses UI toggles **individual** tools per platform; disabled tools are filtered even if their toolset is on. Persists to config. `toolsets-reference.md:165-167` | per-tool | all-on within enabled toolsets | ❓ Use for surgical removal (e.g. disable `browser_cdp` or a specific MCP tool) without dropping the whole toolset. |
| capability gates | `browser`, `computer_use`, `code_execution`, `cronjob`, Feishu, Home Assistant only appear when their backend/credential exists; **not** turned on by `all`/`*`. `toolsets-reference.md:160-163` | — | gated | ✅ Automatic — `browser`/`code_execution` light up because the Docker/Chromium backends are present. |
| `kanban` workflow gate | Mutates shared board state; never enabled by `all`/`*` — must be listed explicitly or set via `HERMES_KANBAN_TASK`. `toolsets-reference.md:163` | — | off | ✅ Leave off unless you adopt the kanban multi-agent flow. |

### Subagent delegation autonomy (`delegation.*`)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `delegation.max_iterations` | Tool-calling turns per child agent. `cli-config.yaml.example:923` | int | `50` | ✅ 50. |
| `delegation.max_concurrent_children` | Parallel children per batch (>10 multiplies API cost). `cli-config.yaml.example:924-925` | int ≥1 | `3` | ✅ 3; raise cautiously given `gpt-5.5` cost. |
| `delegation.max_spawn_depth` | Delegation-tree depth cap; >1 lets workers spawn workers (needs `role="orchestrator"`). `cli-config.yaml.example:926-928` | `1`–`3` | `1` (flat) | ❓ `1` is safe; raise to `2` only if you want orchestrator/worker trees. |
| `delegation.orchestrator_enabled` | Kill switch for `role="orchestrator"` children. `cli-config.yaml.example:929` | `true`/`false` | `true` | ✅ Default. |
| `delegation.subagent_auto_approve` | When a child hits a dangerous-command approval prompt: `false` = auto-**deny**, `true` = auto-approve once (can't block on stdin in a gateway). `cli-config.yaml.example:930-933` | `true`/`false` | `false` (auto-deny) | ❓ `false` (auto-deny) is the safe default. Flip to `true` only for trusted cron/batch pipelines where unattended progress matters more than the guard. |
| `delegation.inherit_mcp_toolsets` | When a child's toolsets are narrowed, also keep the parent's MCP toolsets. `cli-config.yaml.example:934` | `true`/`false` | `true` | ✅ `true` (set `false` for strict intersection). |
| `delegation.model` / `provider` | Override model/provider for subagents (empty = inherit parent). `cli-config.yaml.example:935-938` | model/provider | empty (inherit) | ❓ Default inherits `gpt-5.5` (costly for many children). Consider routing subagents to `gemini-3.5` or `qwen-local` to cut cost. |

Notes: the dangerous-command approval system and `file_safety` protected-path/secret-redaction guards are enforced in code with no enable/disable config key (only `delegation.subagent_auto_approve` and `security.tirith_*` tune adjacent behavior). The deprecated top-level `toolsets:` key is ignored — all toolset config is per-platform via `platform_toolsets` or globally via `agent.disabled_toolsets`. Source files: `/tmp/hermes-agent-ref/cli-config.yaml.example`, `/tmp/hermes-agent-ref/tools/browser_tool.py`, `/tmp/hermes-agent-ref/tools/browser_supervisor.py`, `/tmp/hermes-agent-ref/tools/web_tools.py`, `/tmp/hermes-agent-ref/tools/file_tools.py`, `/tmp/hermes-agent-ref/hermes_cli/tools_config.py`, and the docs under `/tmp/hermes-agent-ref/website/docs/`.


---

Confirmed: the canonical config key is `memory.write_approval` (the `ln` references were stale matches from a different module). I have all I need. The persisted key is `memory.write_approval`, default `false`, set via `hermes config set memory.write_approval`. I now have authoritative defaults for every setting in the domain. Assembling the deliverable.

## Memory & personalization

Hermes layers three independent subsystems in this domain: **built-in persistent memory** (MEMORY.md + USER.md, always-on file store), an **optional external memory provider** (`memory.provider` — Honcho here, additive), and **background personalization aux tasks** (curator, session search, title generation, which share the `auxiliary.*` plumbing). Built-in memory and Honcho run side by side; only one *external* provider may be active at a time.

### Built-in persistent memory (`memory.*`)

Source: `/tmp/hermes-agent-ref/cli-config.yaml.example:496-514`; defaults confirmed in `/tmp/hermes-agent-ref/agent/agent_init.py:1111-1127`. Note: the shipped example sets `memory_enabled`/`user_profile_enabled` to `true`, but the code fallback when the `memory:` block is absent is `false` — so you must declare the block.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `memory.memory_enabled` | Enables MEMORY.md — agent's personal notes (env facts, conventions, lessons) injected as a frozen system-prompt block at session start (`/tmp/hermes-agent-ref/website/docs/user-guide/features/memory.md:13-20`) | `true` / `false` | `true` (example) / `false` (code fallback) | ✅ `true` — core of cross-session continuity for an always-on assistant; declare the `memory:` block explicitly so the `false` code fallback never bites. |
| `memory.user_profile_enabled` | Enables USER.md — your profile (name, role, prefs, comm style) as a separate injected block (`memory.md:18`) | `true` / `false` | `true` (example) / `false` (code fallback) | ✅ `true` — single-user personalization is the whole point here. |
| `memory.memory_char_limit` | Hard cap on MEMORY.md (~2.75 chars/token). Writes that overflow return an error; agent must consolidate, no auto-compact (`agent_init.py:1125`, `memory.md:122-149`) | integer chars | `2200` (~800 tok) | ❓ Keep `2200`. With the gpt-5.5 context this is cheap; bump to ~3500–4000 only if you find the agent thrashing on consolidation. Recommended default: leave it. |
| `memory.user_char_limit` | Hard cap on USER.md (`agent_init.py:1126`) | integer chars | `1375` (~500 tok) | ❓ Keep `1375`; raise to ~2000 if you want a richer always-on profile. Recommended: leave it. |
| `memory.nudge_interval` | Reminds the agent to consider saving memories every N **user** turns; `0` disables. Only active when memory is enabled (`cli-config.yaml.example:507-509`, `agent_init.py:1121`) | integer ≥ 0 | `10` | ✅ `10` — sane cadence for long-running chats. Set `0` only if Honcho's auto-write makes built-in nudges feel redundant (it won't — they target different stores). |
| `memory.flush_min_turns` | On exit/`/reset`/`/new`/compression, gives the agent one turn to save memories — but only if the session had ≥ N user turns; `0` disables (`cli-config.yaml.example:511-514`) | integer ≥ 0 | `6` | ✅ `6` — prevents trivial sessions from triggering a flush while still capturing substantive ones before context loss. |
| `memory.write_approval` | Gate on ALL memory writes (foreground + background self-improvement review). `false` = write freely; `true` = stage for `/memory pending` approval (`memory.md:218-246`; key confirmed in `/tmp/hermes-agent-ref/hermes_cli/write_approval_commands.py:21-26`) | `true` / `false` | `false` | ❓ Start `false` (frictionless). Flip to `true` if the agent ever records a wrong fact about you and you want a yes/no gate on every save — strong fit for a privacy-focused single-user box. |
| `memory.provider` | Selects the one external memory provider running alongside built-in. Empty = built-in only (`agent_init.py:1139`, `memory-providers.md:21-26`) | `honcho`, `openviking`, `mem0`, `hindsight`, `holographic`, `retaindb`, `byterover`, `supermemory`, `memori`, or empty | empty | 🔒 `honcho` — locked: Honcho HOSTED is the chosen provider. |

> **`recall` / prefetch:** there is no `memory.recall` config key. Built-in recall is the automatic background `prefetch_all`/`queue_prefetch_all` flow (`/tmp/hermes-agent-ref/agent/memory_manager.py:431-473`) with no knobs; the "recall mode" knob lives in Honcho's `recallMode` (below). USER.md/MEMORY.md are injected as a frozen snapshot, not recalled per-turn.

### Honcho provider — connection & identity (`honcho.json`)

Config file resolution: `$HERMES_HOME/honcho.json` > `~/.hermes/honcho.json` > `~/.honcho/config.json` (`/tmp/hermes-agent-ref/plugins/memory/honcho/README.md:106-118`). Keys resolve **host block > root > env var > default**. Host key for the default profile is `hermes`. The example config's `honcho: {}` block (`cli-config.yaml.example:951-952`) is only for Hermes-side overrides — the substantive config is `honcho.json`.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `apiKey` / `HONCHO_API_KEY` | Honcho Cloud API key (README:126) | string | — | 🔒 Hosted Honcho — supply via **agent-vault** (`HONCHO_API_KEY` injected through the MITM proxy), not committed to `honcho.json`. |
| `baseUrl` / `HONCHO_BASE_URL` | Base URL; local URLs auto-skip key auth (README:127) | URL | — (cloud SDK default) | 🔒 Leave unset — hosted, so the SDK targets Honcho Cloud. |
| `environment` / `HONCHO_ENVIRONMENT` | SDK environment mapping (README:128) | `production` / others | `production` | ✅ `production`. |
| `enabled` | Master toggle per host block; auto-on when `apiKey`/`baseUrl` present (README:129) | `true` / `false` / auto | auto | ✅ Leave to auto (it enables once the vault key resolves); set `true` explicitly in the `hosts.hermes` block for clarity. |
| `workspace` | Shared workspace ID — all profiles in it see one user identity (README:130) | string | host key (`hermes`) | ✅ `hermes` (the default). Single-user, so one workspace is correct. |
| `peerName` | The human's peer identity (README:132) | string | — | ❓ Pick a stable handle (e.g. your first name / `yasyf`). This is your durable user identity across every profile — choose once, never churn it. |
| `aiPeer` | The AI peer identity, one per profile (README:133) | string | host key (`hermes`) | ✅ `hermes` (default). Only matters if you spin up extra profiles. |
| `pinUserPeer` (alias `pinPeerName`) | Collapses every gateway runtime user to `peerName` — single-operator pooling (README:140-141,161-167) | `true` / `false` | `false` | ❓ **`true`** — recommended. You're the only human; BlueBubbles + CLI should all land on one peer. (Alternatives: `false` + `userPeerAliases` only if you later expose the bot to others.) |
| `userPeerAliases` | Map of runtime IDs → peer IDs for hybrid multi-user routing (README:142) | object | `{}` | ✅ `{}` — unneeded once `pinUserPeer: true`. |
| `runtimePeerPrefix` | Namespaces unknown runtime IDs (README:143) | string | `""` | ✅ `""` — irrelevant under single-operator pinning. |

### Honcho — recall, observation & write behavior

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `recallMode` | How Honcho memory flows in: `hybrid` (auto-inject + tools), `context` (inject only, tools hidden), `tools` (tools only) (README:172-173, honcho.md:139-155) | `hybrid` / `context` / `tools` | `hybrid` | ❓ **`hybrid`** — recommended: passive context every turn plus the agent can query deeper on demand. Pick `tools` to cut per-turn token/LLM cost (agent must call memory explicitly); `context` if you never want the agent invoking memory tools mid-task. |
| `observationMode` | Preset for who-models-whom: `directional` (all four flags on, enables cross-peer dialectic) vs `unified` (shared-pool, AI models user only) (README:174, honcho.md:157-171) | `directional` / `unified` | `directional` | ✅ `directional` — full mutual modeling gives the richest single-user profile. |
| `observation` (object) | Per-peer override of the preset: `user.observeMe/observeOthers`, `ai.observeMe/observeOthers` (README:272-292) | object of 4 bools | all `true` (= `directional`) | ✅ Omit — let `observationMode: directional` drive it. Only override if you give the AI a fixed persona it shouldn't self-update (`ai.observeMe:false`). |
| `writeFrequency` | When to flush messages to Honcho: `async` (background thread), `turn` (sync), `session` (batch on end), or integer N turns (README:181) | `async` / `turn` / `session` / int | `async` | ✅ `async` — never blocks the turn; correct for an interactive assistant. |
| `saveMessages` | Persist raw messages to the Honcho API (README:182) | `true` / `false` | `true` | ❓ **`true`** for full server-side modeling. Privacy-focused alternative: `false` keeps raw transcripts off Honcho's servers (you lose session summaries/representation quality) — only consider if hosted-Honcho data retention concerns you. |
| `messageMaxChars` | Max chars per message to `add_messages()`; chunked beyond (Honcho cloud limit 25k) (README:261) | integer | `25000` | ✅ `25000` (cloud ceiling). |

### Honcho — dialectic reasoning & cost-control cadence

The three orthogonal knobs (`contextCadence`, `dialecticCadence`, `dialecticDepth`) are the main cost dials; in `tools` recall mode all dialectic cadence/depth/budget knobs are inert (`honcho.md:144-155`). Source: `/tmp/hermes-agent-ref/plugins/memory/honcho/README.md:245-271`.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `contextCadence` | Min turns between base-context refreshes (`context()` API calls: summary + representation + card) (README:267) | integer ≥ 1 | `1` | ❓ **`1`** (refresh every turn) for max continuity. Set `2`–`3` to halve base-layer API calls if cost matters. |
| `dialecticCadence` | Min turns between dialectic `.chat()` LLM firings (README:268) | integer (rec. 1–5) | `1` (README) / `2` (docs+example) | ❓ **`2`** — recommended balance. `1` = deepest awareness but an LLM call every turn (cost); `3`–`5` to economize. Note the source default is `1` but the published guidance and example both use `2`. |
| `dialecticDepth` | `.chat()` passes per dialectic firing: 1=single, 2=audit+synthesis, 3=+reconciliation (README:249) | `1`–`3` (clamped) | `1` | ❓ **`2`** — recommended: the self-audit pass markedly improves cold-start/prewarm quality, with conditional bail-out so it isn't always 2 calls. `1` for cheapest, `3` for max rigor on a quiet box. |
| `dialecticReasoningLevel` | Base reasoning level for `.chat()` (README:251) | `minimal`/`low`/`medium`/`high`/`max` | `low` | ❓ **`low`** (default) — bumped automatically by query length up to `reasoningLevelCap`. Raise to `medium` for deeper modeling at higher per-call cost. |
| `dialecticDepthLevels` | Explicit per-pass reasoning levels, overrides proportional defaults, e.g. `["minimal","low","medium"]` (README:250) | array of level strings | `null` | ✅ Omit — proportional defaults (`[minimal, base]` for depth 2) are well-tuned. |
| `dialecticDynamic` | Lets the model override reasoning level per-call via the `honcho_reasoning` tool param (README:252) | `true` / `false` | `true` | ✅ `true` — model self-scales depth to the query. |
| `dialecticMaxChars` | Max chars of dialectic result injected into the prompt (README:253) | integer | `600` | ✅ `600` — keeps the supplement bounded; raise only if dialectic output is being truncated mid-insight. |
| `dialecticMaxInputChars` | Max chars of query input to `.chat()` (Honcho cloud limit 10k) (README:254) | integer | `10000` | ✅ `10000` (cloud ceiling). |
| `contextTokens` | Token budget for auto-injected context per turn; truncates at word boundaries; `null` = uncapped (also gates prefetch truncation) (README:260, honcho.md:117) | integer / `null` | `null` (SDK default) | ❓ Leave `null` to start. With gpt-5.5's large context this is fine; set ~1200–1500 if you want a hard per-turn cap on injected memory tokens. |
| `injectionFrequency` | `every-turn` vs `first-turn` (inject only on the first user message) (README:269) | `every-turn` / `first-turn` | `every-turn` | ✅ `every-turn` — continuous awareness is the goal for a persistent assistant. |
| `reasoningLevelCap` | Hard ceiling for the query-length auto-scaling of reasoning level (honcho.md:103) | `minimal`/`low`/`medium`/`high` | `high` (honcho.md:103; README:270 shows it unset) | ✅ Leave unset (effective cap `high`). Set `medium` to bound worst-case dialectic cost on long queries. |

### Honcho — session mapping

Source: `/tmp/hermes-agent-ref/plugins/memory/honcho/README.md:184-216`. Gateway platforms (BlueBubbles) always isolate per-chat via the gateway session key regardless of `sessionStrategy`; the strategy only affects CLI sessions.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `sessionStrategy` | How CLI Honcho sessions map to work: `per-directory` (basename of `$PWD`), `per-repo` (git root), `per-session` (fresh each run), `global` (one bucket) (README:188, honcho.md:131-137) | 4 values | `per-directory` | ❓ **`per-directory`** (default) for general use; choose **`global`** if you mostly run from one home dir and want all CLI memory to accumulate in a single bucket — a clean fit for a single-user always-on box. `per-session` only if you prefer clean starts. |
| `sessionPeerPrefix` | Prepend the peer name to session keys (README:189) | `true` / `false` | `false` | ✅ `false` — single user, no need to disambiguate sessions by peer. |
| `sessions` (object) | Manual directory → session-name pins (README:190) | object | `{}` | ✅ `{}` — add entries later only if you want a named long-lived session for a specific project dir. |
| `HERMES_HONCHO_HOST` (env) | Overrides the derived host-block key (README:308) | string | derived (`hermes`) | ✅ Leave unset — default profile derivation is correct. |

### Curator (`curator.*` + `auxiliary.curator`)

Background maintenance fork for **agent-created** skills (usage tracking, `active→stale→archived`, periodic aux-model review). Not in the example config — defaults from `/tmp/hermes-agent-ref/agent/curator.py:56-59,138-182` and `/tmp/hermes-agent-ref/website/docs/user-guide/features/curator.md:43-51`. Runs only on session start / gateway cron tick when both interval and idle thresholds are met.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `curator.enabled` | Master on/off for the curator (`curator.py:138`) | `true` / `false` | `true` | ❓ **`true`** if you'll let the agent author skills; the first run is deferred a full interval so you can review first. Set `false` if you curate `~/.hermes/skills/` by hand and want zero background mutation. |
| `curator.interval_hours` | Min hours since last run before another fires (`curator.py:141,56`) | integer hours | `168` (7 days) | ✅ `168` — weekly is plenty for a personal skill library. |
| `curator.min_idle_hours` | Required agent idle time before a run (`curator.py:149,57`) | float hours | `2` | ✅ `2` — naturally confines runs to quiet stretches on an always-on box. |
| `curator.stale_after_days` | Days unused → skill marked `stale` (`curator.py:157,58`) | integer days | `30` | ✅ `30`. |
| `curator.archive_after_days` | Days unused → skill moved to `.archive/` (recoverable; never deleted) (`curator.py:165,59`) | integer days | `90` | ✅ `90`. |
| `curator.prune_builtins` | Also archive unused **bundled** built-in skills (hub skills always exempt) (`curator.py:173-182`, curator.md:13) | `true` / `false` | `true` | ❓ **`true`** to keep the catalog lean; set `false` if you want shipped skills never touched. |
| `curator.backup.enabled` | Take a tar.gz snapshot of `~/.hermes/skills/` before every mutating run (curator.md:120-129) | `true` / `false` | `true` | ✅ `true` — gates both auto and manual snapshots; keep on so rollback always works. |
| `curator.backup.keep` | How many snapshots to retain (curator.md:120-127) | integer | `5` | ✅ `5`. |
| `auxiliary.curator.provider` | Provider for the curator's LLM review pass (`auxiliary.curator` slot; `curator.py:1624-1634`) | `auto`/`openrouter`/`nous`/`gemini`/`main`/… | `auto` (= main chat model) | ❓ **Pin to a cheap aux model** (e.g. `gemini-3.5` fallback or `qwen-local`) so weekly reviews don't burn gpt-5.5 tokens. `auto` routes through gpt-5.5. |
| `auxiliary.curator.model` | Model for the review pass | model id / empty | empty (provider default) | ❓ Set alongside the provider above, e.g. `gemini-3.5` or your local Qwen. |
| `auxiliary.curator.timeout` | Review-pass call timeout (curator.md:73-76) | seconds | `30` (generic aux default; curator.md recommends `600`) | ❓ **`600`** — reviews legitimately take minutes; the generic 30s aux default will time out long passes. |
| `curator.auxiliary.{provider,model}` | **Legacy** one-off slot (deprecated; emits a warning) (curator.md:80-82) | — | — | ✅ Don't use — migrate to `auxiliary.curator.*`. |

### Session search & title generation (auxiliary personalization tasks)

Both are aux-model task slots sharing the `auxiliary.*` plumbing (`auto` = main chat model). Slot names confirmed in `/tmp/hermes-agent-ref/agent/auxiliary_client.py:5068-5069`. Session search itself (the `session_search` tool over `~/.hermes/state.db` FTS5) needs no enablement — it's automatic and free per `/tmp/hermes-agent-ref/website/docs/user-guide/features/memory.md:182-207`; only its *summarization* pass is an aux task.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.session_search.provider` | Provider for summarizing matched past sessions (`cli-config.yaml.example:476-485`) | `auto`/`openrouter`/`nous`/`gemini`/`main`/… | `auto` | ❓ **Pin to `gemini-3.5`/`qwen-local`** — summarizing search hits is light work; keep it off gpt-5.5. |
| `auxiliary.session_search.model` | Model for the summarization pass | model id / empty | empty (provider default) | ❓ Set with the provider above. |
| `auxiliary.session_search.timeout` | Per-call timeout (`cli-config.yaml.example:479`) | seconds | `30` | ✅ `30`. |
| `auxiliary.session_search.max_concurrency` | Cap on parallel summaries (curbs burst 429s) (`cli-config.yaml.example:480`) | integer | `3` | ✅ `3`. |
| `auxiliary.session_search.extra_body` | Provider-specific OpenAI-compatible request fields, e.g. `{enable_thinking: false}` (`cli-config.yaml.example:481-485`) | object | `{}` | ✅ `{}` unless your chosen aux provider needs reasoning toggles. |
| `auxiliary.title_generation.provider` | Provider for auto-generating session titles (slot `title_generation`; `auxiliary_client.py:5069`, `/tmp/hermes-agent-ref/agent/title_generator.py:29-39`) | `auto`/`openrouter`/`nous`/`gemini`/`main`/… | `auto` (prefers main runtime model, else cheapest aux) | ❓ **Pin to a cheap aux model** — titles are trivial; route to `gemini-3.5`/`qwen-local`. |
| `auxiliary.title_generation.model` | Model for title generation | model id / empty | empty (provider default) | ❓ Set with the provider above. |
| `auxiliary.title_generation.timeout` | Per-call timeout | seconds | `30` (generic aux default) | ✅ `30`. |

> **Insights:** `/tmp/hermes-agent-ref/agent/insights.py` is the `/insights` usage report (token/cost/tool stats over session history) — a read-only command, **not** a configurable memory/personalization surface. No config keys; nothing to set. The Honcho-side "conclusions/derived insights" are governed by the dialectic knobs above (`dialecticDepth`/`dialecticReasoningLevel`) and the `honcho_conclude` tool, not a separate `insights.*` block.


---

I have everything I need. The STT OpenAI path resolves: `stt.openai.api_key` + `stt.openai.base_url` first (this is exactly the Parakeet-on-host wiring — `provider: openai` + `base_url: http://host:8765` + a dummy/real key). This confirms the locked stack precisely.

Now I'll compose the deliverable. I have confirmed defaults from source for every setting.

## Voice & media

Hermes treats this domain as four registries (STT, TTS, image-gen, video-gen) plus image-input routing. All four share the same precedence rule: built-in name → `*.providers.<name>: type: command` → Python plugin → default. There is **no top-level `transcription:` key** — STT *is* the transcription surface (`stt.*`); `auxiliary.tts_audio_tags` is the only media-adjacent key living outside these blocks.

### Speech-to-Text (`stt.*`) — voice-message transcription

For the locked stack STT is wired to **Parakeet on the host**: `provider: openai` + `stt.openai.base_url` pointed at `host:8765`. The OpenAI STT path resolves `stt.openai.api_key`/`base_url` first, then `VOICE_TOOLS_OPENAI_KEY`/`OPENAI_API_KEY`, then the Nous gateway (`/tmp/hermes-agent-ref/tools/transcription_tools.py:1753`). Parakeet's OpenAI-compatible endpoint is local, so `NO_PROXY` must cover `host:8765` exactly as it does `http://ai`.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `stt.enabled` | Auto-transcribe inbound voice messages. When `false`, the gateway still caches the audio and passes its path to the agent (`/tmp/hermes-agent-ref/tools/transcription_tools.py:129`). | `true` / `false` | `true` (`is_stt_enabled` default-`True`, `cli-config.yaml.example:874`) | 🔒 `true` — you want voice notes transcribed. Off only disables auto-STT, not audio capture. |
| `stt.provider` | Active STT backend. Explicit value is honored with no silent cloud fallback (`/tmp/hermes-agent-ref/tools/transcription_tools.py:745`). | `local` \| `local_command` \| `groq` \| `openai` \| `mistral` \| `xai` \| `elevenlabs` \| `<plugin/command name>` | auto-detect `local`>`groq`>`openai`>`xai`>`elevenlabs` when unset (`DEFAULT_PROVIDER="local"`, line 86) | 🔒 `openai` — the host Parakeet OpenAI-shim is reached via this provider + `stt.openai.base_url`. |
| `stt.openai.base_url` | OpenAI-compatible STT endpoint. Wins over `STT_OPENAI_BASE_URL` env (`/tmp/hermes-agent-ref/tools/transcription_tools.py:1758`). | any URL | `https://api.openai.com/v1` (`OPENAI_BASE_URL`, line 98) | 🔒 `http://host:8765/v1` (Parakeet on the host). Add this host to `NO_PROXY`. |
| `stt.openai.api_key` | Per-provider key; checked before env keys (line 1757). | string | unset → falls to `VOICE_TOOLS_OPENAI_KEY`/`OPENAI_API_KEY` | ❓ Parakeet usually ignores the key — set a dummy (`"local"`) inline, or inject a real `VOICE_TOOLS_OPENAI_KEY` via agent-vault if your shim validates. Recommend dummy inline. |
| `stt.openai.model` | Model id sent to the STT endpoint. | `whisper-1` \| `gpt-4o-mini-transcribe` \| `gpt-4o-transcribe` (also `STT_OPENAI_MODEL` env) | `whisper-1` (`DEFAULT_STT_MODEL`, line 89) | ❓ Set to whatever model name your Parakeet shim expects (commonly its own id, e.g. `parakeet-tdt-0.6b-v2`). If the shim ignores `model`, leave `whisper-1`. |
| `stt.local.model` | faster-whisper size if you ever use the `local` provider. Cloud names auto-map to default (`/tmp/hermes-agent-ref/tools/transcription_tools.py:182`). | `tiny`\|`base`\|`small`\|`medium`\|`large-v3`\|`turbo` | `base` (~150 MB, `DEFAULT_LOCAL_MODEL`, line 87) | ✅ Unused under the locked stack (you route to Parakeet). Leave default; the in-VM `local` path is your no-network fallback if you ever flip `provider`. |
| `stt.local.language` | Force decode language for `local`/`local_command`; else auto-detect. Config > `HERMES_LOCAL_STT_LANGUAGE` env > `en` (line 1130, 1213). | ISO-639-1 (`en`,`es`,…) or empty | empty = auto (`DEFAULT_LOCAL_STT_LANGUAGE="en"` when forced, line 88) | ✅ Leave empty (auto-detect) unless you only ever speak one language. |
| `HERMES_LOCAL_STT_COMMAND` (env) | Legacy single-command STT escape hatch; built-in `local_command` provider runs it. Template placeholders `{input_path}`/`{output_dir}`/`{language}`/`{model}`, must emit a `.txt` (`/tmp/hermes-agent-ref/tools/transcription_tools.py:163`,`1201`). | shell command template | unset → auto-detects a `whisper` binary in `/opt/homebrew/bin`,`/usr/local/bin` (line 95,168) | ✅ Not needed — Parakeet is reached via the OpenAI provider, not this hatch. |
| `HERMES_LOCAL_STT_LANGUAGE` (env) | Language for the `local`/`local_command` path when config is silent. | ISO-639-1 | unset → `en` | ✅ Leave unset; prefer `stt.local.language` if ever needed. |
| `stt.providers.<name>` (`type: command`) | Declare multiple shell-driven STT engines (whisper.cpp, SenseVoice, a Parakeet CLI). Sub-keys `command`,`format`(`txt`/`json`/`srt`/`vtt`),`language`,`model`,`timeout`. Built-ins always win (`/tmp/hermes-agent-ref/tools/transcription_tools.py:311`,`616`). | per-provider block; `timeout` default `300`s, `format` `txt`, `language` `en` (lines 267-269) | none declared | ✅ Skip — the host Parakeet HTTP shim via `stt.openai` is cleaner than a CLI provider inside the VM. Use this only if you later run a Parakeet *CLI* in-VM instead of on the host. |
| `STT_GROQ_MODEL` / `STT_MISTRAL_MODEL` / `STT_ELEVENLABS_MODEL`, `GROQ_BASE_URL`, `XAI_STT_BASE_URL`, `ELEVENLABS_STT_BASE_URL` (env) | Per-provider model/endpoint overrides for the cloud STT backends. | strings | `whisper-large-v3-turbo` / `voxtral-mini-latest` / `scribe_v2`; provider URLs (lines 90-100) | ✅ Unused (those providers are off). Leave unset. |

### Text-to-Speech (`tts.*`) — Piper local

Locked to **Piper** (local VITS, no key, runs on CPU in-VM). Piper outputs WAV, so Telegram/Discord voice-bubble delivery needs **ffmpeg** in the VM (BlueBubbles/CLI play the file fine without it). Voices auto-download to `~/.hermes/cache/piper-voices/` on first use.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `tts.provider` | Active TTS backend (`/tmp/hermes-agent-ref/tools/tts_tool.py:340`). | `edge`\|`elevenlabs`\|`openai`\|`minimax`\|`mistral`\|`gemini`\|`xai`\|`neutts`\|`kittentts`\|`piper`\|`<plugin/command>` | `edge` (`DEFAULT_PROVIDER`, line 168) | 🔒 `piper` — fully local, privacy-preserving, no key. |
| `tts.speed` | Global speed multiplier; a provider's own `speed` overrides it. | float (provider-clamped) | `1.0` | ✅ `1.0`. Note Piper ignores `tts.speed`; use `tts.piper.length_scale` instead. |
| `tts.piper.voice` | Voice model name (auto-downloaded) **or** absolute path to a `.onnx` (`/tmp/hermes-agent-ref/tools/tts_tool.py:1885`). | any catalog name (44 langs, `x_low`/`low`/`medium`/`high` tiers) or `.onnx` path | `en_US-lessac-medium` (`DEFAULT_PIPER_VOICE`, line 176) | ❓ `en_US-lessac-medium` (balanced) is a solid default; pick `en_US-*-high` for richer audio or another locale's voice to taste. |
| `tts.piper.voices_dir` | Where downloaded voices are cached (`/tmp/hermes-agent-ref/tools/tts_tool.py:1886`). | path | `~/.hermes/cache/piper-voices/` (`_get_piper_voices_dir`, line 1809) | ✅ Default. |
| `tts.piper.use_cuda` | GPU inference via onnxruntime-gpu (line 1888). | `true`/`false` | `false` | 🔒 `false` — no CUDA in an Apple-Silicon Linux VM. |
| `tts.piper.length_scale` | Duration multiplier = inverse speed; `2.0` = half speed (line 1912). | float | `1.0` | ✅ `1.0`; this is your real speed knob since Piper ignores `tts.speed`. |
| `tts.piper.noise_scale` | VITS audio variation (line 1913). | float | `0.667` | ✅ Default. |
| `tts.piper.noise_w_scale` | VITS phoneme-duration variation (line 1914). | float | `0.8` | ✅ Default. |
| `tts.piper.volume` | Output gain; `0.5` = half-loud (line 1915). | float | `1.0` | ✅ Default. |
| `tts.piper.normalize_audio` | Loudness normalization (line 1916). | `true`/`false` | `true` | ✅ Default. |
| `tts.piper.max_text_length` | Per-request char cap before truncation (`PROVIDER_MAX_TEXT_LENGTH["piper"]`, line 223). | positive int | `5000` | ✅ Default; raise only for long monologues. |
| `tts.providers.<name>` (`type: command`) | Wire any TTS CLI (VoxCPM, MLX-Kokoro, XTTS) without Python. Keys `command`,`output_format`(`mp3`/`wav`/`ogg`/`flac`),`voice`,`model`,`speed`,`timeout`,`voice_compatible`,`max_text_length` (`/tmp/hermes-agent-ref/tools/tts_tool.py:389-392`). | per-provider; `timeout` `120`s, `output_format` `mp3`, `voice_compatible` `false`, `max_text_length` `5000` | none | ✅ Skip — Piper's native backend covers local TTS. Reach for this only to add a second voice engine. |
| `auxiliary.tts_audio_tags.provider` / `.model` / `.timeout` | Auxiliary LLM that inserts hidden `[whispers]`-style audio tags before TTS — **Gemini-3.1-TTS only** (`/tmp/hermes-agent-ref/cli-config.yaml.example:469`). | provider name / model / seconds | `auto` / `""` (= main chat model) / `30` | 🔒 N/A for Piper — audio tags are a Gemini-TTS feature; this auxiliary task never fires. Leave default. |

Off-by-architecture TTS keys (`tts.edge.*`, `tts.openai.*`, `tts.elevenlabs.*`, `tts.minimax.*`, `tts.mistral.*`, `tts.gemini.*`, `tts.xai.*`, `tts.neutts.*`, `tts.kittentts.*`) and `tts.use_gateway`: ✅ leave unset — only `tts.piper.*` is in play. (NeuTTS/KittenTTS are the other local options if you ever want a different voice without ffmpeg's WAV→Opus step — they also output WAV, so no advantage there.)

### Image input routing (`agent.image_input_mode`)

Governs how user-attached images on a turn reach the model (`/tmp/hermes-agent-ref/agent/image_routing.py:316`). Not present in `cli-config.yaml.example`; lives under the existing `agent:` block (`cli-config.yaml.example:596`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `agent.image_input_mode` | `native` = attach pixels as `image_url` parts; `text` = run `vision_analyze` and prepend a text summary; `auto` = native if the active model reports `supports_vision`, unless an explicit `auxiliary.vision` backend is set (then text) (`/tmp/hermes-agent-ref/agent/image_routing.py:316-346`). | `auto`\|`native`\|`text` | `auto` (`_coerce_mode`, line 254) | ✅ `auto` — gpt-5.5 is vision-capable, so `auto` attaches natively; falls back to text only on a non-vision fallback (qwen-local). Force `native` only if you set a custom provider whose vision caps aren't in models.dev. |
| `model.supports_vision` / `providers.<p>.models.<m>.supports_vision` | Override the vision-capability lookup for custom/local models so `auto` routes them natively (`/tmp/hermes-agent-ref/agent/image_routing.py:176`). | `true`/`false` (strict YAML bool) | unset → models.dev lookup | ❓ Set `true` for `qwen-local` if it's a vision model and your local server isn't in models.dev — otherwise `auto` downgrades qwen-local turns to `text`. Leave unset if qwen-local is text-only. |

### Image generation (`image_gen.*`) — OpenAI gpt-image-2

Locked to the **`openai` image-gen plugin** (NOT the FAL `fal-ai/gpt-image-2` entry). This plugin calls OpenAI `images.generate` directly with `OPENAI_API_KEY`, exposing three virtual tier IDs that map to one API model (`gpt-image-2`) at different `quality` values (`/tmp/hermes-agent-ref/plugins/image_gen/openai/__init__.py`). Enable with `hermes plugins enable image_gen/openai`. `OPENAI_API_KEY` is injected via agent-vault; that traffic goes to OpenAI (not `http://ai`), so it must traverse `HTTPS_PROXY`, not `NO_PROXY`.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `image_gen.provider` | Active image backend; selects the registered plugin (`/tmp/hermes-agent-ref/agent/image_gen_registry.py:78`). | `openai`\|`fal`\|`krea`\|`openai-codex`\|`xai`\|`<plugin>` | unset → single-registered-provider fallback | 🔒 `openai` — the gpt-image-2 plugin. |
| `image_gen.openai.model` (or `image_gen.model`) | Quality tier; checked after `OPENAI_IMAGE_MODEL` env (`/tmp/hermes-agent-ref/plugins/image_gen/openai/__init__.py:96`). All three hit API model `gpt-image-2`. | `gpt-image-2-low` (~15s) \| `gpt-image-2-medium` (~40s) \| `gpt-image-2-high` (~2min) | `gpt-image-2-medium` (`DEFAULT_MODEL`, line 74) | ❓ `gpt-image-2-medium` (balanced). Go `-high` for fidelity, `-low` for fast cheap iteration. |
| `OPENAI_IMAGE_MODEL` (env) | Tier override for scripts/tests; wins over config (line 98). | one of the three tier IDs | unset | ✅ Leave unset — set the tier in config instead. |
| `OPENAI_API_KEY` (env) | Auth for `images.generate`; `is_available()` returns false without it (line 136). | string | unset | 🔒 Inject via agent-vault. Routes through `HTTPS_PROXY` (OpenAI is external). |
| `image_gen.use_gateway` | Route via Nous Tool Gateway instead of direct creds (`prefers_gateway`, `/tmp/hermes-agent-ref/tools/tool_backend_helpers.py:149`). | `true`/`false` | `false` | ❓ `false` (direct OpenAI key). Flip to `true` only if you want gpt-image-2 billed through the paid Nous gateway instead of your own OpenAI key. |

Note on size/quality: this plugin does **not** expose `size` or `quality` as config keys — `quality` is fixed by the chosen tier, and `size` is derived from the agent's `aspect_ratio` arg (`landscape`→`1536x1024`, `square`→`1024x1024`, `portrait`→`1024x1536`, line 76). `n` is hard-pinned to 1. So there is nothing else to set here. (The FAL `fal-ai/gpt-image-2` path — `image_size` presets + `quality: medium` pinned, `/tmp/hermes-agent-ref/tools/image_generation_tool.py:222` — is a *different* backend you are not using.)

### Video generation (`video_gen.*`)

`video_generate` ships **no in-tree provider** — it dispatches only to a plugin you enable (`/tmp/hermes-agent-ref/tools/video_generation_tool.py:7`). Nothing is configured by the locked stack.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `video_gen.provider` | Active video backend; selects a registered `VideoGenProvider` plugin. | `<plugin name>` (enable via `hermes plugins enable video_gen/<name>`) | none registered → tool is inert | ✅ Leave unset — video gen isn't in your stack. Enable a plugin later if you want it (FAL Veo3/Kling/Pixverse are the typical backends). |
| (tool call args, not config) `aspect_ratio` / `resolution` / `duration` / `audio` / `negative_prompt` / `seed` | Per-call params the agent passes; providers clamp to their supported set (`/tmp/hermes-agent-ref/agent/video_gen_provider.py:63`). | `aspect_ratio` ∈ {16:9,9:16,1:1,4:3,3:4,3:2,2:3}; `resolution` ∈ {480p,540p,720p,1080p} | `aspect_ratio` `16:9`, `resolution` `720p` (lines 64,67) | ✅ Not config — defaults only matter once a video plugin is enabled. |


---

I have everything I need. Here is the deliverable.

## Gateway & messaging platforms

The gateway daemon (`hermes gateway`) is the always-on process that runs your messaging adapters, ticks the cron scheduler every 60s, and hosts the session store. For the locked stack you run exactly two adapters — CLI and BlueBubbles — inside the headless Linux VM. All other platforms below are inventoried only so you know what is available; leave them off.

Sources cited as `/tmp/hermes-agent-ref/<path>:<line>`. Top-level keys live in `~/.hermes/config.yaml`; env vars live in `~/.hermes/.env`.

### Gateway lifecycle & service install (autostart)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `hermes gateway install [--system]` | Installs the gateway as a systemd (Linux) / launchd (macOS) background service so it survives reboots. `--system` installs a boot-time system unit for headless servers; bare install is a per-user unit. (`cli-commands.md:225`, `cron.md:206-207`) | per-user / `--system` | not installed | 🔒 Always-on headless VM → `sudo hermes gateway install --system` (NixOS: wrap as a systemd service via your module). This *is* "autostart" — there is no `autostart:` config key. |
| `hermes gateway run` | Run in the foreground (no service). Recommended for WSL/Docker/Termux. (`cli-commands.md:219`) | — | — | ✅ Use only for debugging; the installed system service is your steady state. |
| `hermes gateway start/stop/restart/status` | Control the installed service. (`cli-commands.md:220-223`) | — | — | ✅ Operational verbs, not config. |
| `--all` | Act on every profile's gateway at once. (`cli-commands.md:233`) | flag | off | 🔒 Single-user, single-profile → irrelevant; omit. |
| `HERMES_GATEWAY_NO_SUPERVISE` / `--no-supervise` | Opt out of s6-overlay auto-supervision inside the Docker image. (`cli-commands.md:234`) | `1` / unset | unset | 🔒 You run the VM-native systemd service, not the s6 Docker image → leave unset. |
| `agent.restart_drain_timeout` | Graceful-drain window (s) on gateway stop/restart: stop taking new work, let in-flight agents finish, then interrupt. `0` = interrupt immediately. (`cli-config.yaml.example:612-616`) | int seconds, `0`=off | `60` (commented) | ✅ 60s is fine for a single user; bump only if you run long unattended jobs you don't want killed mid-flight. |
| `PlatformConfig.gateway_restart_notification` (per-platform) | Whether the gateway sends "♻️ Gateway online / restarted" pings on that platform. (`gateway/config.py:336`) | `true` / `false` | `true` | ❓ Personal iMessage thread → recommend `false` for `bluebubbles` so reboots don't spam you; keep `true` only if you want restart visibility. |

### Sessions, concurrency & reset policy

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `max_concurrent_sessions` (top-level) | Caps simultaneously active chat sessions across CLI, TUI, dashboard, and gateway. Takes precedence over `gateway.max_concurrent_sessions`. `null`/`0`/omit = unlimited. (`cli-config.yaml.example:543-550`; `gateway/config.py:538`) | positive int / `null` | `null` (unlimited) | ✅ Single user → leave `null`. Set a small cap (e.g. 4) only if you want a hard guard against runaway parallel cron + chat load. |
| `group_sessions_per_user` | In group/channel chats, give each participant their own session when a user ID is available (prevents context/cost bleed between people). (`cli-config.yaml.example:556`; `gateway/config.py:536`) | `true` / `false` | `true` | ✅ Keep `true` (secure default). For a solo iMessage setup it rarely fires, but harmless. |
| `gateway.thread_sessions_per_user` | When `false`, threads are shared across all participants; `true` isolates per user in threads. (`gateway/config.py:537`) | `true` / `false` | `false` | ✅ Leave default. |
| `session_reset.mode` | When messaging sessions auto-clear (saving memories first). (`cli-config.yaml.example:529-541`; `gateway/config.py:285`) | `both` / `idle` / `daily` / `none` | `both` | ❓ With Honcho carrying long-term memory, `both` (default) keeps cost down and is a fine pick; choose `none` only if you want one continuous iMessage thread and rely on compression. |
| `session_reset.idle_minutes` | Inactivity timeout before reset. (`gateway/config.py:287`) | int minutes | `1440` (24h) | ✅ 24h suits a personal assistant; lower to ~240 if you want tighter cost control. |
| `session_reset.at_hour` | Local hour (0–23) for the daily reset boundary. (`gateway/config.py:286`) | 0–23 | `4` | ✅ 4 AM is fine. |
| `session_reset.notify` | Send a chat notification when an auto-reset fires. (`gateway/config.py:288`) | `true` / `false` | `true` | ✅ Keep `true` so you know context was wiped. |
| `session_reset.notify_exclude_platforms` | Platforms that never get reset notices. (`gateway/config.py:289`) | list | `("api_server","webhook")` | ✅ Default; no action. |
| `reset_triggers` | Slash phrases that manually reset a session. (`gateway/config.py:514`) | list | `["/new","/reset"]` | ✅ Default. |
| `gateway.session_store_max_age_days` | Prune `SessionEntry` records older than N days from `sessions.json`. `0` = disabled. (`gateway/config.py:551`) | int days, `0`=off | `90` | ✅ 90 days keeps the store bounded; no action. |
| `gateway.sessions_dir` | Where session state is persisted. (`gateway/config.py:520`) | path | `~/.hermes/sessions` | 🔒 Lives on the VM's persistent volume — ensure `~/.hermes` is on durable (non-tmpfs) storage so sessions survive reboots. |
| `agent.gateway_timeout` / `HERMES_AGENT_*` | Inactivity timeout (s) for a gateway agent run; only fires after the agent is idle (not mid-tool/stream). (`cli-config.yaml.example:602-605`) | int seconds, `0`=unlimited | `1800` (commented) | ✅ 30 min is reasonable; raise if local Qwen/long tool runs stall idle. |
| `agent.gateway_timeout_warning` | Send a warning before escalating to the full timeout. `0`=off. (`cli-config.yaml.example:607-610`) | int seconds, `0`=off | `900` (commented) | ✅ Default. |

### Inbound access control, pairing & notices

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `unauthorized_dm_behavior` (top-level; per-platform override under `platforms.<p>.extra`) | What happens to a DM from an unauthorized user: `pair` replies with a one-time pairing code; `ignore` silently drops. (`gateway/config.py:95-101,541,733-738`; `configuration.md:1543-1551`) | `pair` / `ignore` | `pair` | ❓ Single-user private assistant → recommend `ignore` (don't hand pairing codes to random texters), or keep `pair` if you'll onboard family by texting your iMessage. |
| `notice_delivery` (per-platform) | Whether operator notices go to the channel (`public`) or DM the user (`private`). (`gateway/config.py:104-110,6570-6575`) | `public` / `private` | `public` | ✅ DM-only iMessage → no effect; leave default. |
| `BLUEBUBBLES_ALLOWED_USERS` | Comma-separated pre-authorized phones/emails. (`bluebubbles.md:79,116`; `environment-variables.md:392`) | CSV of `+E164` / email | — (none) | 🔒 Set to your own number/Apple ID via agent-vault so you skip pairing entirely. |
| `BLUEBUBBLES_ALLOW_ALL_USERS` | Allow every sender, no allowlist. (`bluebubbles.md:84,117`) | `true` / `false` | `false` | 🔒 Privacy-focused → keep `false`. Never set `true` on a personal iMessage. |
| `GATEWAY_ALLOW_ALL_USERS` | Global "allow all" across platforms; if no allowlist and no allow-all is set, the gateway warns at startup. (`gateway/run.py:4925-4964`) | `true`/`1`/`yes` / unset | unset | 🔒 Leave unset; rely on `BLUEBUBBLES_ALLOWED_USERS`. |

### BlueBubbles (iMessage) — full env/config set 🔒 (your one real chat platform)

Connection requires `SERVER_URL` + `PASSWORD`; everything else has source defaults below. The runtime reads `platforms.bluebubbles.extra.<key>` first, then the env var (`gateway/platforms/bluebubbles.py:117-147`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `BLUEBUBBLES_SERVER_URL` | URL of the BlueBubbles macOS server (auto-prefixes `http://`, strips trailing `/`). (`bluebubbles.py:96-102,120-121`) | URL | — (required) | 🔒 Point at the BlueBubbles server on the Apple-Silicon host (Tailscale/LAN address). NO_PROXY note: it is *not* `http://ai`, so it goes through the agent-vault MITM proxy — add the BlueBubbles host to `NO_PROXY` too, since it's a local host call that shouldn't be MITM'd. |
| `BLUEBUBBLES_PASSWORD` | Server password; appended as `?password=` on every REST call. (`bluebubbles.py:123,158-160`) | string | — (required) | 🔒 Inject via agent-vault, never inline in `config.yaml`. |
| `BLUEBUBBLES_WEBHOOK_HOST` | Bind address for the local inbound webhook listener. (`bluebubbles.py:42,124-127`) | IP | `127.0.0.1` | ❓ `127.0.0.1` works only if BlueBubbles can reach the VM on loopback (it can't across host↔VM). Set to the VM's Tailscale/LAN IP (e.g. `0.0.0.0` bound + firewalled) so the host's BlueBubbles server can POST webhooks in. |
| `BLUEBUBBLES_WEBHOOK_PORT` | Port for the webhook listener. (`bluebubbles.py:43,128-131`) | int | `8645` | ✅ Default unless it collides. The agent **self-registers** this webhook on startup (scoped to `?password=` + `new-message`/`updated-message`). Do **not** also add it manually in BlueBubbles → Settings → API → Webhooks — a manual entry defaults to `*` events, so every message is delivered twice and the duplicate (chat-GUID-less) delivery misroutes replies (see [hermes-home-server.md](hermes-home-server.md) self-registered-webhook note). |
| `BLUEBUBBLES_WEBHOOK_PATH` | URL path of the webhook (leading `/` auto-added). (`bluebubbles.py:44,132-137`) | string | `/bluebubbles-webhook` | ✅ Default. |
| `BLUEBUBBLES_HOME_CHANNEL` | Phone/email used as the default cron/notification delivery target (`deliver="bluebubbles"`). (`bluebubbles.md:115`; `environment-variables.md:391`; `cron.md:253`) | `+E164` / email | — | ❓ Set to your own number so cron jobs and proactive notices land in your iMessage. Required if you want any `deliver:"bluebubbles"` or `"all"` cron routing. |
| `platforms.bluebubbles.extra.send_read_receipts` | Auto-mark inbound messages read after processing (needs Private API helper). **No env var.** (`bluebubbles.py:138`; `bluebubbles.md:121`) | `true` / `false` | `true` | ❓ `true` reads-receipts everything Hermes processes; set `false` if you don't want senders to see blue "Read" under bot-handled messages. |
| `BLUEBUBBLES_REQUIRE_MENTION` / `extra.require_mention` | In group chats, only respond when a wake word matches; DMs always respond. (`bluebubbles.py:139-142`; `bluebubbles.md:118`) | bool | `false` | 🔒 `false` — respond to every authorized member's message in DMs **and** groups (gated by the sender allowlist). Set `true` only if you later want to quiet a busy group via wake words. |
| `BLUEBUBBLES_MENTION_PATTERNS` / `extra.mention_patterns` | Regex wake words for group mention gating (JSON array, or comma/newline list). (`bluebubbles.py:143-147,162-196`; `bluebubbles.md:119`) | regex list | Hermes defaults (`@?hermes`, `@?hermes agent`) (`bluebubbles.py:51-54`) | ✅ Defaults are fine; override only to rename the agent (e.g. `(?<![\w@])@?amos\b`). |
| `platforms.bluebubbles.reply_to_mode` | Threading of multi-part replies to the user's message. (`gateway/config.py:329`) | `off` / `first` / `all` | `first` | ✅ `first` is the natural iMessage feel. |
| `platforms.bluebubbles.gateway_restart_notification` | (see lifecycle table) | bool | `true` | ❓ Recommend `false` here to silence reboot pings. |

Notes (`bluebubbles.md:135-154`): tapbacks, typing indicators, and read receipts require the BlueBubbles **Private API helper** on the host; without it, text + media still work. Markdown is stripped to plain text; `MAX_TEXT_LENGTH=4000` (`bluebubbles.py:45`). `SEND_READ_RECEIPTS` is config-only — there is intentionally no env var.

### Other available platforms (inventory only — keep OFF) 🔒

Each is enabled by setting its token/credentials; you have none configured, which is correct for the locked stack. Listed so you know the surface. (Tokens/allowlists from `environment-variables.md`; per-platform `require_mention`/`free_response_*` bridging in `gateway/config.py:944-1249`.)

| Platform | Enable via (key env vars) | Notable knobs | Recommendation |
|---|---|---|---|
| **CLI** | (built-in, no creds) — `platform_toolsets.cli: [hermes-cli]` (`cli-config.yaml.example:700`) | full toolset incl. cronjob mgmt | 🔒 On. Your second active surface alongside BlueBubbles. |
| Telegram | `TELEGRAM_BOT_TOKEN`; `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`, `TELEGRAM_CRON_THREAD_ID` (`environment-variables.md:244-250`) | `require_mention`, `guest_mode`, `reply_to_mode`, `free_response_chats`, `extra.disable_link_previews/rich_messages` (`cli-config.yaml.example:718-727`) | 🔒 Off. |
| Discord | `DISCORD_BOT_TOKEN`; `DISCORD_ALLOWED_USERS/ROLES`, `DISCORD_HOME_CHANNEL` (`environment-variables.md:261-267`) | top-level `discord:` block: `require_mention` (def `true`), `auto_thread` (def `true`), `free_response_channels`, `reactions`, `history_backfill`(+`_limit` def `50`) (`cli-config.yaml.example:731-737`) | 🔒 Off. |
| Slack | `SLACK_BOT_TOKEN` (`xoxb-`), `SLACK_APP_TOKEN` (`xapp-`, Socket Mode); `SLACK_ALLOWED_USERS`, `SLACK_HOME_CHANNEL` (`environment-variables.md:282-285`) | `SLACK_REQUIRE_MENTION`, `free_response_channels` (`gateway/config.py:1036-1042`) | 🔒 Off. |
| Signal | `SIGNAL_HTTP_URL` (signal-cli daemon), `SIGNAL_ACCOUNT` (E.164); `SIGNAL_ALLOWED_USERS`, `SIGNAL_ALLOW_ALL_USERS`, `SIGNAL_GROUP_ALLOWED_USERS` (`environment-variables.md:320-326`) | `SIGNAL_REQUIRE_MENTION`, `SIGNAL_IGNORE_STORIES` | 🔒 Off. |
| Email | `EMAIL_ADDRESS`, `EMAIL_PASSWORD`, `EMAIL_IMAP_HOST/PORT`, `EMAIL_SMTP_HOST/PORT`; `EMAIL_ALLOWED_USERS`, `EMAIL_HOME_ADDRESS`, `EMAIL_POLL_INTERVAL`, `EMAIL_ALLOW_ALL_USERS` (`environment-variables.md:338-348`) | polling adapter | 🔒 Off. |
| SMS (Twilio) | `TWILIO_ACCOUNT_SID/AUTH_TOKEN/PHONE_NUMBER`; `SMS_ALLOWED_USERS`, `SMS_HOME_CHANNEL` (`environment-variables.md:327-337`) | shared with telephony skill | 🔒 Off. |
| WhatsApp / WhatsApp Cloud | `WHATSAPP_ALLOWED_USERS` / `WHATSAPP_CLOUD_ALLOWED_USERS`, `WHATSAPP_CLOUD_HOME_CHANNEL` (`environment-variables.md:300-315`) | `require_mention`, `free_response_chats` | 🔒 Off. |
| Matrix | `MATRIX_*`; `MATRIX_ALLOWED_USERS`, `free_response_rooms` (`gateway/config.py:1223-1249`) | `require_mention`, `auto_thread` | 🔒 Off. |
| Google Chat / Teams / DingTalk / Feishu / WeCom / Weixin / QQ Bot / Mattermost / Home Assistant / webhook / api_server | various `*_ALLOWED_USERS`, `*_HOME_CHANNEL` (`environment-variables.md:290-400`) | per-platform | 🔒 Off (largely China-market or enterprise). |

`platform_toolsets` (`cli-config.yaml.example:699-711`) maps each platform to a toolset preset; only `cli: [hermes-cli]` matters for you. There is no `bluebubbles:` line by default → it falls back to its built-in default toolset; add `bluebubbles: [hermes-telegram]` (the standard messaging bundle: terminal, file, web, vision, image_gen, tts, browser, skills, todo, cronjob, send_message) if you want the full messaging toolset on iMessage. ❓ Recommend setting it explicitly for clarity.

### Streaming & response pacing (messaging UX)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `streaming.enabled` | Progressive token streaming via message edits. (`cli-config.yaml.example:565-566`; `gateway/config.py:394`) | `true` / `false` | `false` | 🔒 BlueBubbles `SUPPORTS_MESSAGE_EDITING = False` (`bluebubbles.py:114`) → editing-based streaming is a no-op on iMessage. Leave `false`. |
| `streaming.transport` | `auto` (native draft, Telegram only) / `edit`. (`gateway/config.py:411`) | `auto` / `edit` | `auto` | 🔒 Irrelevant on iMessage. |
| `streaming.edit_interval` / `buffer_threshold` / `cursor` | Edit cadence, flush threshold, streaming cursor. (`gateway/config.py:386-414`) | float / int / str | `0.8` / `24` / `" ▉"` | 🔒 Irrelevant. |
| `human_delay.mode` | Human-like delay between message chunks. (`cli-config.yaml.example:888-891`) | `off` / `natural` / `custom` (+`min_ms`/`max_ms`) | `off` | ✅ Leave `off` for a snappy personal assistant. |
| `display.interim_assistant_messages` | Send completed mid-turn status as separate chat messages. (`cli-config.yaml.example:996-1001`) | `true` / `false` | `true` | ✅ Keep `true` (or `false` to reduce iMessage noise during long tool runs). |
| `display.long_run_heartbeat` (the "⏳ Working — N min" pings) | Periodic heartbeat edits; suppressed if `false`. (`cli-config.yaml.example:1003-1006`) | `true` / `false` | `true` | ✅ iMessage has no edit support, so heartbeats would post as new messages — consider `false` to avoid spam. |
| `agent.gateway_notify_interval` / `HERMES_AGENT_NOTIFY_INTERVAL` | Seconds between long-running-status notifications; `0` disables. (`gateway/run.py:1226-1227,15275-15293`) | int seconds, `0`=off | `180` (3 min) | ✅ Default; set `0` if you don't want progress pings on iMessage. |
| `gateway.filter_silence_narration` | Drop hallucinated "silence" outputs (`*(silent)*`, 🔇, bare `.`) pre-send. (`gateway/config.py:530`) | `true` / `false` | `true` | ✅ Keep `true`. |
| `gateway.stt_enabled` / `stt.enabled` | Auto-transcribe inbound voice messages. (`gateway/config.py:533`; `cli-config.yaml.example:874`) | `true` / `false` | `true` | 🔒 On — wired to Parakeet via `stt.provider=openai` + host `:8765`; inbound iMessage voice notes get transcribed. |

### Cron / scheduler

The gateway daemon ticks the scheduler every 60s; jobs live in `~/.hermes/cron/jobs.json`, outputs in `~/.hermes/cron/output/{job_id}/`, lock at `~/.hermes/cron/.tick.lock` (`cron.md:201-226,641-643`). Resolution order for tunables: **env var → `config.yaml` `cron:` → built-in default**.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `cron.wrap_response` | Wrap delivered cron output with a "Cronjob Response: …" header/footer. (`cron.md:280-299`; `scheduler.py:682-691`) | `true` / `false` | `true` | ✅ Keep `true` so scheduled-task messages are distinguishable in your iMessage thread. |
| `cron.max_parallel_jobs` / `HERMES_CRON_MAX_PARALLEL` | Max jobs run concurrently per tick. `1` = serial. (`scheduler.py:2020-2038`) | int, `1`=serial | unbounded | ❓ Single-user local box → cap at `2`–`4` so a burst of due jobs doesn't saturate the gpt-5.5 gateway or local Qwen. Workdir jobs always serialize regardless (`cron.md:124-126`). |
| `cron.script_timeout_seconds` / `HERMES_CRON_SCRIPT_TIMEOUT` | Timeout for pre-run/no-agent scripts. (`cron.md:314-324`; `scheduler.py:860-876`) | int seconds | `120` | ✅ Raise to `300` only if you use jittered-delay scripts. |
| `HERMES_CRON_TIMEOUT` | Per-job **inactivity** timeout (agent killed after this idle). `0`=unlimited. (`scheduler.py:1763-1779`) | int seconds, `0`=unlimited | `600` (10 min) | ✅ 10 min is sane; raise for long local-model jobs. |
| `gateway.always_log_local` | Always save cron outputs to local files (audit), even when delivered to chat. (`gateway/config.py:523`) | `true` / `false` | `true` | ✅ Keep `true` — local-first/privacy fits, gives an audit trail in `~/.hermes/cron/output/`. |
| Cron delivery target (`deliver=`) | Where a job's output goes. (`cron.md:228-267`) | `origin`/`local`/`bluebubbles`/`bluebubbles:<addr>`/`all`/comma-list | `local` (CLI), `origin` (messaging) | 🔒 Use `local` for silent monitors, `bluebubbles` (needs `BLUEBUBBLES_HOME_CHANNEL`) to ping yourself. `all` fans out to every configured home channel — for you that's just BlueBubbles. |
| Cron toolset | Toolset the cron agent gets per tick. (`cron.md:503-522`; `scheduler.py:65-109`) | `hermes tools` cron-platform config; per-job `enabled_toolsets=[...]` | built-in default (no `moa`) | ❓ Set a lean cron toolset (e.g. `[web, file, terminal]`) via `hermes tools` → cron, to keep the tool-schema prompt cheap on every scheduled LLM call. |
| Pre-run gate (`wakeAgent`) / `no_agent` | Script decides whether to spend tokens; `no_agent` runs script-only, stdout delivered verbatim. (`cron.md:326-346,524-546`) | per-job | wake=`true` | ✅ Use `no_agent`/`wakeAgent:false` for watchdogs to keep cost at $0 on quiet ticks. |
| Cron provider recovery | Cron inherits `fallback_providers` + credential rotation. (`cron.md:423-430`) | — | — | 🔒 Already covered — failover (gpt-5.5 → gemini-3.5 → qwen-local) lives in hermes and applies to cron runs automatically. |

### Slash commands & quick commands

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `quick_commands.<name>` | User-defined slash commands that bypass the LLM: `type: exec` runs a host shell command (zero tokens, 30s timeout) and returns stdout; `type: alias` rewrites to another slash command. Works in CLI + every messaging platform. (`configuration.md:1553-1584`) | per-command: `type: exec\|alias` + `command`/`target` | none | ❓ Great fit for a home server — define `/status`, `/disk`, `/restart` (alias → `/gateway restart`), `/gpu` etc. so you can poke the VM from iMessage without burning tokens. Note: `exec` runs on the **host the gateway runs on** (your Linux VM), so scope commands to VM-side checks. |
| `display.tool_progress_command` | Enables the `/verbose` slash command in the messaging gateway. (`slash-commands.md:1298`) | `true` / `false` | `false` | ✅ Default; flip `true` if you want to toggle tool-progress verbosity from iMessage. |
| `reset_triggers` | Phrases that reset a session (also slash-shaped). (`gateway/config.py:514`) | list | `["/new","/reset"]` | ✅ Default. |
| Built-in slash commands | `/cron`, `/model`, `/personality`, `/footer`, `/stop`, `/reset`, `/new`, etc. — available in CLI and messaging. (`slash-commands.md`, `cron.md:34-41`) | — | — | ✅ No config; available out of the box on BlueBubbles + CLI. |

**Unconfirmed:** none in this domain — all defaults above are confirmed from source or the example config.


---

I have all the authoritative details confirmed. Here is the deliverable.

## Auxiliary models & per-task routing

Hermes runs lightweight side tasks (image analysis, web-page summarization, screenshot analysis, title generation, compression, etc.) through a separate "auxiliary" resolution chain so they need not hit your main reasoning model. Every slot shares the same four knobs — `provider`, `model`, `base_url`, `api_key` — plus per-slot `timeout` and `extra_body`. The full default slot dict lives in `/tmp/hermes-agent-ref/hermes_cli/config.py:1258-1393`; the resolution chain is `/tmp/hermes-agent-ref/agent/auxiliary_client.py:1-41`.

**Critical default-behavior correction (read first):** the example-config comment (`/tmp/hermes-agent-ref/cli-config.yaml.example:440`) claims `auto` = "OpenRouter → Nous Portal → main endpoint." That is stale. The current authoritative behavior (`/tmp/hermes-agent-ref/website/docs/user-guide/configuration.md:884`) is: **`provider: "auto"` routes every auxiliary task to your main chat model** — for everyone, not just aggregator users. So with the locked stack, leaving any text slot at `auto` sends that task to `gpt-5.5` over `http://ai`. That is already your "point at main" outcome with zero config — but it means a cheap side task runs on your premium model. Where I recommend ✅ auto below, I'm accepting main-model cost as fine for that task's low volume; where I recommend ❓, the choice is "cheap aux model vs main model."

**Provider option vocabulary** (`/tmp/hermes-agent-ref/website/docs/user-guide/configuration.md:945`, `/tmp/hermes-agent-ref/agent/auxiliary_client.py:165-182`): valid per-slot `provider` values are `auto`, `main` (explicit alias for "whatever my main agent uses" — resolves to your `custom` → `http://ai`), `custom` (direct `base_url`+`api_key`), plus any registry provider (`openrouter`, `nous`, `codex`/`openai-codex`, `gemini`, `ollama-cloud`, etc.). The prompt's `main` option = the `main` alias here; the example config's bare `custom` and the docs' `main` both land on your `http://ai` endpoint, the difference being `main` follows your live main-provider selection while `custom`/`base_url` pins a literal endpoint. **For this stack, `auto` and `main` are functionally identical** (main provider = `custom` = `http://ai`), so I phrase recs as 🔒 auto≡main where that's the point.

**EXPERIMENTAL marker:** the entire `auxiliary:` block is flagged Advanced/Experimental (`/tmp/hermes-agent-ref/cli-config.yaml.example:420`, `:430-433`) — overriding to providers other than OpenRouter/Nous "may not work" (vision support, summary quality, API-format mismatches). The locked stack mostly leaves these at `auto`, which sidesteps the experimental surface.

**Proxy note (applies to every slot):** `NO_PROXY` excludes `http://ai`, so any slot resolving to main/auto/custom-pointed-at-`http://ai` bypasses the agent-vault MITM proxy. Any slot you point at OpenRouter/Nous/Gemini/Exa instead goes *through* `HTTPS_PROXY` and needs its key in agent-vault.

### Vision & multimodal

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.vision.provider` / `AUXILIARY_VISION_PROVIDER` | Backend for the `vision_analyze` tool + browser screenshot analysis. On a vision-capable main model, raw pixels pass through natively; on a text-only main model, a fallback vision model describes the image as text (`/tmp/hermes-agent-ref/website/docs/reference/tools-reference.md`, vision auto-chain at `auxiliary_client.py:17-23`). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini`/`codex`/`ollama-cloud` | `auto` | ❓ `gpt-5.5` is multimodal, so `auto` passes images natively over `http://ai` — works and is the simplest. Recommended default: leave `auto`. Alternative if you want vision off the premium model: `openrouter` + `google/gemini-3-flash-preview` (key via agent-vault, goes through proxy). |
| `auxiliary.vision.model` / `AUXILIARY_VISION_MODEL` | Pins the vision model; empty = provider default | model string | `""` | 🔒 Leave empty — main (`gpt-5.5`) handles vision natively. |
| `auxiliary.vision.base_url` / `AUXILIARY_VISION_BASE_URL` | Direct OpenAI-compatible vision endpoint (overrides provider) | URL | `""` | ✅ Empty. |
| `auxiliary.vision.api_key` / `AUXILIARY_VISION_API_KEY` | Key for `base_url` (falls back to `OPENAI_API_KEY`) | string | `""` | ✅ Empty. |
| `auxiliary.vision.timeout` | LLM call timeout (vision payloads are large) | seconds | `120` (`config.py:1264`) | ✅ 120s is generous for `http://ai`. |
| `auxiliary.vision.download_timeout` | HTTP image-download timeout | seconds | `30` (`config.py:1266`) | ✅ 30s fine for local/LAN images. |
| `auxiliary.vision.extra_body` | Provider-specific request fields | dict | `{}` | ✅ Empty. |

### Web extraction

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.web_extract.provider` / `AUXILIARY_WEB_EXTRACT_PROVIDER` | LLM that summarizes scraped pages + browser page-text extraction (`config.py:1268`). Distinct from `web.extract_backend` (the *scraper*, e.g. Exa/native at `config.py:1026`). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini`/`ollama-cloud` | `auto` | ❓ This is the highest-volume text slot. `auto` runs every page summary on `gpt-5.5`. Recommended: route to a cheap model — `openrouter` + `google/gemini-3-flash-preview` (proxied, key via agent-vault). Alternative: leave `auto`/`main` if you'd rather keep all traffic on `http://ai` and accept the cost. |
| `auxiliary.web_extract.model` / `AUXILIARY_WEB_EXTRACT_MODEL` | Summarization model | model string | `""` | ❓ If you pick `openrouter` above, set `google/gemini-3-flash-preview`; else empty. |
| `auxiliary.web_extract.base_url` / `AUXILIARY_WEB_EXTRACT_BASE_URL` | Direct endpoint for the summarizer | URL | `""` | ✅ Empty (Exa is the *scraper*, configured under `web:`, not here). |
| `auxiliary.web_extract.api_key` / `AUXILIARY_WEB_EXTRACT_API_KEY` | Key for `base_url` | string | `""` | ✅ Empty. |
| `auxiliary.web_extract.timeout` | Per-attempt summarization timeout | seconds | `360` (`config.py:1273`) | ✅ 360s; lower it only if you move to a fast cloud model. |
| `auxiliary.web_extract.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Context compression

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.compression.provider` | Model that writes rolling-summary compactions of long conversations. Thresholds live under the separate top-level `compression:` block; the model lives here (`config.py:1276`, docs `environment-variables.md` "compression"). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ Compression quality matters for long sessions on this always-on box. Recommended: leave `auto` (= `gpt-5.5`) — a capable model gives better summaries, and compaction is infrequent. Alternative: `openrouter` + a flash model if cost on long-runner sessions bites. |
| `auxiliary.compression.model` | Compression model | model string | `""` | ❓ Empty (uses main) unless you route to a flash model above. |
| `auxiliary.compression.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.compression.timeout` | Summarization timeout (big contexts) | seconds | `120` (`config.py:1281`) | ✅ 120s. (Legacy `compression.summary_model/provider/base_url` auto-migrate here — `environment-variables.md`.) |
| `auxiliary.compression.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Curator (skill-usage review)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.curator.provider` | Background skill-review fork: prunes/consolidates/archives agent-created skills (`config.py:1366-1378`, `cli-commands.md`). `auto` = main model. | `auto`/`main`/`custom`/`openrouter`/`nous` | `auto` | ❓ Review can run minutes over hundreds of skills, but it's rare. Recommended: leave `auto` (`gpt-5.5`) for quality. Alternative: `openrouter` + `google/gemini-3-flash-preview` to keep the long fork off your premium model. |
| `auxiliary.curator.model` | Curator model | model string | `""` | ❓ Empty (main) unless routing to flash. |
| `auxiliary.curator.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.curator.timeout` | Review timeout (umbrella-building is slow) | seconds | `600` (`config.py:1376`) | ✅ 600s — deliberately generous, keep it. |
| `auxiliary.curator.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Title generation

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.title_generation.provider` | Generates a 3–7 word session title after the first exchange, in a background thread (`config.py:1312`, consumer `agent/title_generator.py:58`, `sessions.md`). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ Tiny, frequent call — a perfect candidate for a cheap model. Recommended: `openrouter` + `google/gemini-3-flash-preview` (proxied) to keep titling off `gpt-5.5`. Acceptable alternative: leave `auto` (cost is small per call). |
| `auxiliary.title_generation.model` | Title model | model string | `""` | ❓ `google/gemini-3-flash-preview` if routing to OpenRouter; else empty. |
| `auxiliary.title_generation.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.title_generation.timeout` | Call timeout | seconds | `30` (`config.py:1317`) | ✅ 30s. |
| `auxiliary.title_generation.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### TTS audio tags

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.tts_audio_tags.provider` | Hidden rewrite pass that inserts expressive `[square-bracket]` audio tags into the TTS script without showing them in chat (`config.py:1320`, `cli-config.yaml.example:856`). Empty model = main chat model. | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | 🔒 You use Piper (local TTS), which does **not** consume Gemini-style audio tags. This slot only matters for `tts.audio_tags: true` on a Gemini TTS engine. Leave `auto`; it stays dormant. |
| `auxiliary.tts_audio_tags.model` | Tag-rewrite model | model string | `""` | ✅ Empty (slot inert under Piper). |
| `auxiliary.tts_audio_tags.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.tts_audio_tags.timeout` | Call timeout | seconds | `30` (`config.py:1325`) | ✅ 30s. |
| `auxiliary.tts_audio_tags.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Kanban: triage specifier & decomposer

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.triage_specifier.provider` | Expands a one-liner Triage card into a concrete spec, then promotes it to `todo` — `hermes kanban specify` / dashboard ✨ button (`config.py:1328-1340`, `cli-commands.md`). Docs say a cheap/capable model (Gemini Flash) is recommended; main is overkill. | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ Recommended: `openrouter` + `google/gemini-3-flash-preview` (cheap, fast — matches the slot's intent). Alternative: leave `auto` if you rarely use Kanban triage. |
| `auxiliary.triage_specifier.model` | Specifier model | model string | `""` | ❓ `google/gemini-3-flash-preview` if routing to OpenRouter; else empty. |
| `auxiliary.triage_specifier.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.triage_specifier.timeout` | Spec-expansion timeout | seconds | `120` (`config.py:1338`) | ✅ 120s. |
| `auxiliary.triage_specifier.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |
| `auxiliary.kanban_decomposer.provider` | Fans a triage task into a graph of child tasks routed to specialist profiles — `hermes kanban decompose` + auto-decompose dispatcher tick (`config.py:1341-1353`, `cli-commands.md`). Uses more tokens than the specifier. | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ Decomposition benefits from reasoning. Recommended: leave `auto` (`gpt-5.5`) for graph quality. Alternative: a strong cheaper model if the auto-decompose tick fires often (`kanban.auto_decompose: true` is the default). |
| `auxiliary.kanban_decomposer.model` | Decomposer model | model string | `""` | ❓ Empty (main) unless overriding. |
| `auxiliary.kanban_decomposer.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.kanban_decomposer.timeout` | Task-graph timeout (token-heavy) | seconds | `180` (`config.py:1351`) | ✅ 180s. |
| `auxiliary.kanban_decomposer.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Profile describer

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.profile_describer.provider` | Auto-generates a 1–2 sentence "what this profile is good at" blurb — `hermes profile describe <name> --auto` + dashboard button (`config.py:1354-1365`, `profile-commands.md`). Short, cheap call. | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ✅ Leave `auto` — it's a one-off, manual, tiny call; running it on `gpt-5.5` is negligible. |
| `auxiliary.profile_describer.model` | Describer model | model string | `""` | ✅ Empty. |
| `auxiliary.profile_describer.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.profile_describer.timeout` | Call timeout | seconds | `60` (`config.py:1363`) | ✅ 60s. |
| `auxiliary.profile_describer.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Monitor (urgency/importance classifier)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.monitor.provider` | Scores candidate items 0–10 against your criteria for the important-mail monitor automation (`cron/scripts/classify_items.py`) so only above-threshold items get delivered (`config.py:1379-1392`, consumer `cron/suggestion_catalog.py:64`). High-volume per-item scoring; docs explicitly say a small model is fine. | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ If you enable the important-mail monitor cron, route this to a cheap model — `openrouter` + `google/gemini-3-flash-preview` (proxied) — because per-item scoring is high-volume. If you never enable the monitor, leave `auto` (slot stays dormant). |
| `auxiliary.monitor.model` | Classifier model | model string | `""` | ❓ `google/gemini-3-flash-preview` if monitor enabled; else empty. |
| `auxiliary.monitor.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.monitor.timeout` | Per-item scoring timeout | seconds | `60` (`config.py:1390`) | ✅ 60s. |
| `auxiliary.monitor.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Skills hub, MCP dispatch, approval classifier

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.skills_hub.provider` | LLM for skill matching/search in the skills hub (`config.py:1288`, docs `configuration.md:991`). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ✅ Leave `auto` (= `gpt-5.5`). Skill matching benefits from a capable model and is low-volume. |
| `auxiliary.skills_hub.model` | Skills-hub model | model string | `""` | ✅ Empty. |
| `auxiliary.skills_hub.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.skills_hub.timeout` | Call timeout | seconds | `30` (`config.py:1293`) | ✅ 30s. |
| `auxiliary.skills_hub.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |
| `auxiliary.mcp.provider` | LLM for MCP tool-dispatch assistance (`config.py:1304`, docs `configuration.md:998`). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ✅ Leave `auto` (= `gpt-5.5`). Tool routing wants the capable model in the loop. |
| `auxiliary.mcp.model` | MCP dispatch model | model string | `""` | ✅ Empty. |
| `auxiliary.mcp.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.mcp.timeout` | Call timeout | seconds | `30` (`config.py:1309`) | ✅ 30s. |
| `auxiliary.mcp.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |
| `auxiliary.approval.provider` | Dangerous-command approval classifier for `smart` permission mode — auto-approves low-risk, auto-denies dangerous, escalates uncertain (`config.py:1296`, docs `configuration.md:970`, `security.md`). Docs recommend a fast/cheap model (gemini-flash, haiku). | `auto`/`main`/`custom`/`openrouter`/`nous`/`gemini` | `auto` | ❓ Security-sensitive but high-frequency. Recommended: leave `auto` (= `gpt-5.5`) — you want a capable model judging command risk in your Docker sandbox, and `http://ai` keeps the prompts (which may contain command text) off the proxy/cloud. Alternative: `openrouter` + a flash model if latency on every command bothers you, but that ships command text through the proxy to a cloud provider. |
| `auxiliary.approval.model` | Approval model (fast/cheap recommended by docs) | model string | `""` | ❓ Empty (main) unless you accept the cloud/cost tradeoff above. |
| `auxiliary.approval.base_url` / `.api_key` | Direct endpoint + key | URL / string | `""` / `""` | ✅ Empty. |
| `auxiliary.approval.timeout` | Classifier timeout | seconds | `30` (`config.py:1301`) | ✅ 30s. |
| `auxiliary.approval.extra_body` | Provider-specific fields | dict | `{}` | ✅ Empty. |

### Removed / non-slot notes

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `auxiliary.session_search.*` | **Removed.** Session search no longer uses an auxiliary LLM (PR #27590 — the single-shape tool returns DB content directly). Stale keys in config are harmless and ignored (`config.py:1284-1287`). | — | (none) | 🔒 Do not configure — there is no LLM slot here anymore. The prompt lists `session_search`, but it is no longer a model-routing slot; the search tool reads the DB directly. |
| `auxiliary.<task>.extra_body.provider` / `.plugins` | OpenRouter provider-routing prefs + Pareto Code coding-score floor, set *per aux task* — main-agent `provider_routing` / `openrouter.min_coding_score` do **not** propagate (`config.py:1240-1257`, docs `configuration.md:1027`). | dict | `{}` | ✅ Only relevant for any slot you route to OpenRouter; otherwise empty. If you move web_extract/title/triage/monitor to OpenRouter, optionally pin `extra_body.provider.sort: price`. |

**Net recommended overrides for the locked stack** (everything else stays `auto` = `gpt-5.5` over `http://ai`, off-proxy): route the high-volume, low-stakes text slots to a cheap proxied model — `web_extract`, `title_generation`, `triage_specifier`, and `monitor` (the last only if you enable the important-mail cron) → `openrouter` + `google/gemini-3-flash-preview` with `OPENROUTER_API_KEY` in agent-vault. Keep `vision`, `compression`, `curator`, `kanban_decomposer`, `skills_hub`, `mcp`, and `approval` on `auto`/main for quality and to keep sensitive prompts (command text, full page/conversation content) on `http://ai` and out of the proxy/cloud path. `tts_audio_tags` and `session_search` are inert for this stack.


---

I have everything needed. Writing the deliverable now.

## Dashboard, observability & security

Scope: the dashboard web UI + its auth providers, the two bundled observability plugins, network egress isolation, the secret/credential persistence model, log level + redaction, the SSL-CA guard, and **managed mode** (`HERMES_MANAGED` / `.managed`). Everything below is tailored to the locked stack: always-on single-user NixOS VM on Apple Silicon, dashboard reachable over Tailscale, secrets via agent-vault MITM proxy.

> **Architectural note on managed mode.** On NixOS the systemd unit sets `HERMES_MANAGED=true` (and/or the activation script drops a `~/.hermes/.managed` marker). `is_managed()` then returns `NixOS` (`/tmp/hermes-agent-ref/hermes_cli/config.py:315-337`). This makes every mutating CLI command **refuse and point you at `nixos-rebuild`** instead of silently editing `~/.hermes`. Concretely it blocks: `hermes update` (`hermes_cli/main.py:8296`), `hermes setup` wizard (`hermes_cli/setup.py:2912`), `hermes gateway setup` / `install` / `uninstall` service (`hermes_cli/gateway.py:5970,6490,6584`), and `config save` / `config set <key>` (`cli.py:5531,5797`). Consequence for this stack: you cannot use `hermes config set` or the dashboard's "Save config" button to persist settings — **all `config.yaml` and `.env` content must be declared in `services.hermes-agent.settings` (and the secret/env file) in your `configuration.nix`**, and upgrades happen via `nix flake update && nixos-rebuild switch`. Plan every recommendation below as a declarative Nix value, not an interactive command.

### Dashboard — launch, bind & exposure

The dashboard is **not** a config-file-enabled service; it is launched by the `hermes dashboard` CLI/process (or the s6 service in Docker). There is no `dashboard.enabled` key — these flags + the `dashboard:` config block tune it. Port default 9119, bind default loopback (`/tmp/hermes-agent-ref/hermes_cli/subcommands/dashboard.py:26,29`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `hermes dashboard --host` | Interface to bind the web UI to (`/tmp/hermes-agent-ref/hermes_cli/subcommands/dashboard.py:29`). Non-loopback host auto-engages the OAuth/auth gate (`should_require_auth`, `hermes_cli/web_server.py:291-304`). | any IP/hostname | `127.0.0.1` | ❓ Bind `127.0.0.1` and reach it via the Tailscale Aperture gateway / SSH-forward (no LAN exposure, no gate needed). Alternative: bind the VM's Tailscale IP directly — but RFC1918/CGNAT/Tailscale addrs count as **public**, forcing you to stand up an auth provider. Recommend loopback + Tailscale proxy. |
| `hermes dashboard --port` | Listen port (`:26`). | int, `0`=OS-assign | `9119` | ✅ Keep `9119`. |
| `hermes dashboard --insecure` | Legacy escape hatch: bind non-loopback **without** the auth gate, exposing API keys on the network (`:37`, gate truth table `web_server.py:296`). | flag | off | 🔒 Never set. Loopback bind already needs no gate; `--insecure` only disarms protection on a public bind. |
| `hermes dashboard --no-open` | Don't auto-open a browser (`:32`). | flag | off | 🔒 Set it — headless VM has no browser to open. |
| `hermes dashboard --skip-build` | Serve prebuilt `web/dist` instead of running `npm run build` (`:40`). | flag | off | ❓ In a NixOS image the SPA is built at derivation time, so set this and ship the prebuilt dist. Alternative: leave off if npm is in the VM and you accept a build on launch. Recommend skip-build with a Nix-built `dist`. |
| `auth.json` write boundary (managed) | Dashboard "Save config" / key edits hit the managed-mode block. | — | blocked under NixOS | 🔒 Edit config via `configuration.nix` + `nixos-rebuild`; treat the dashboard as read-mostly. |

### Dashboard auth providers (the OAuth/login gate)

The gate engages only on a non-loopback bind. Providers auto-activate by config presence; env vars override `config.yaml` (env wins when non-empty, `nous/__init__.py:566-598`). Exactly one is needed if you ever expose the dashboard beyond loopback. The auth middleware lets `/login`, `/auth/*`, `/api/auth/providers`, and static assets through unauthenticated and 401/redirects everything else (`hermes_cli/dashboard_auth/middleware.py:38-71`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `dashboard.basic_auth.username` / `…password` / `…password_hash` (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` / `_PASSWORD_HASH`) | Activates the **basic** provider: username + password, stateless HMAC sessions, stdlib scrypt hashing (`plugins/dashboard_auth/basic/plugin.yaml:3`, `basic/__init__.py:408-461`). `password_hash` preferred; plaintext env overrides config hash. | strings | unset (provider no-ops) | ❓ If you ever bind to Tailscale, this is the simplest gate — set `username` + `password_hash`. Realistic alt: skip entirely and stay loopback+Tailscale (recommended), so no provider is configured at all. |
| `dashboard.basic_auth.secret` (`HERMES_DASHBOARD_BASIC_AUTH_SECRET`) | HMAC signing key so sessions survive restart / multi-worker (`basic/__init__.py:372`). | string | ephemeral random | ❓ Set (via agent-vault/Nix secret) **only if** you use basic_auth; otherwise every restart logs you out. Else N/A. |
| `dashboard.basic_auth.session_ttl_seconds` (`HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS`) | Access-token lifetime (`basic/__init__.py:417,471`). | int seconds | `43200` (12h) [^ttl] | ✅ Leave default if using basic_auth. |
| `dashboard.oauth.self_hosted.issuer` / `…client_id` / `…scopes` (`HERMES_DASHBOARD_OIDC_ISSUER` / `_CLIENT_ID` / `_OIDC_SCOPES`) | Activates the **self_hosted** generic OIDC provider (Authentik/Keycloak/Authelia/etc.) via discovery + PKCE (`self_hosted/plugin.yaml:3`, `self_hosted/__init__.py:49-57`). | issuer+client_id required; scopes optional | scopes `openid profile email` | ❓ The strongest option if you run an IDP. For a single-user home server it's overkill; recommend skipping in favor of loopback+Tailscale. Pick this only if you already host Authelia/Authentik. |
| `dashboard.oauth.client_id` / `dashboard.oauth.portal_url` (`HERMES_DASHBOARD_OAUTH_CLIENT_ID` / `HERMES_DASHBOARD_PORTAL_URL`) | Activates the **nous** Portal OAuth provider (`nous/plugin.yaml:3`, `nous/__init__.py:566-598`). Portal provisions `client_id` on Fly.io deploys; `register` via `hermes dashboard register`. | client_id string | portal_url → `https://portal.nousresearch.com` | 🔒 Not for this stack — it's the cloud/Fly Portal path. Leave unset. |
| `dashboard.public_url` (`HERMES_DASHBOARD_PUBLIC_URL`) | Forces the absolute base URL used to build OAuth callbacks behind reverse proxies that don't forward `X-Forwarded-*` (`cli-config.yaml.example:1224-1240`). | URL incl. optional path prefix | empty (reconstruct from proxy headers) | ✅ Leave empty unless you front the gated dashboard with a manual nginx that drops forwarded headers. Not needed for loopback+Tailscale. |

### Observability plugins (Langfuse, NeMo Relay)

Both are bundled, **opt-in**, and fail-open (no-op without SDK/creds). Enable via `hermes plugins enable observability/<name>` — but that command persists enabled-state into `HERMES_HOME`, which is blocked/awkward under managed mode, so on NixOS declare them in the `plugins.enabled` list in `config.yaml` instead (the NeMo README shows this list form, `nemo_relay/README.md:212-214`). They hook the read-only observer contract (`docs/observability/README.md`); payloads are sanitized + secret-redacted before export.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `plugins.enabled: [observability/langfuse]` | Loads the Langfuse tracer (turns, LLM calls, tools) (`langfuse/plugin.yaml:3`). | list entry | not enabled | ❓ Off by default. For a privacy-focused local server, enable **only** if you point it at a self-hosted Langfuse on the LAN — never `cloud.langfuse.com`. Recommend leaving disabled unless you want trace UI. |
| `HERMES_LANGFUSE_PUBLIC_KEY` / `HERMES_LANGFUSE_SECRET_KEY` | Langfuse credentials; required for the plugin to do anything (`langfuse/plugin.yaml:6-7`, README:23-26). | `pk-lf-…` / `sk-lf-…` | unset → silent no-op | ❓ If enabling, inject via agent-vault. Else N/A. |
| `HERMES_LANGFUSE_BASE_URL` | Langfuse endpoint (`langfuse/README.md:26`). | URL | `https://cloud.langfuse.com` | 🔒 If used, **must** point at a self-hosted/LAN instance (privacy lock). Add it to `NO_PROXY` if internal. |
| `HERMES_LANGFUSE_ENV` / `_RELEASE` / `_SAMPLE_RATE` / `_MAX_CHARS` / `_DEBUG` | Trace tags, sampling (0–1), per-field char cap, verbose logging (`langfuse/README.md:42-46`). | tags / float / int / bool | sample `1.0`, max_chars `12000`, debug off [^lf] | ✅ Leave defaults if enabled. |
| `plugins.enabled: [observability/nemo_relay]` | Loads the NeMo Relay exporter (ATOF/ATIF JSONL trajectories) (`nemo_relay/plugin.yaml:3`, README:36-45). Env vars only configure an **already-enabled** plugin. | list entry | not enabled | ✅ Leave disabled. This is for trajectory eval/replay harnesses, not a home server; needs `nemo-relay` PyPI extra anyway. |
| `HERMES_NEMO_RELAY_ATOF_ENABLED` / `_ATIF_ENABLED` + `_OUTPUT_DIRECTORY` / `_FILENAME` / `_MODE` / `_PLUGINS_TOML` … | Local export of agent trajectories to disk (or via a `plugins.toml`) (`nemo_relay/README.md:108-170`). | bools / paths / `append`\|`overwrite` | export off | ✅ N/A unless you enable the plugin. |

### Network egress isolation

The locked stack already supplies egress control at the **host** layer via the agent-vault MITM proxy (`HTTPS_PROXY` with `NO_PROXY` excluding `http://ai`), which both injects secrets and constrains where traffic can go. The Docker-layer guide below is the in-container equivalent — relevant only because `terminal.backend=docker` runs in the VM.

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `HTTPS_PROXY` / `HTTP_PROXY` (process env) | Routes all hermes egress through the agent-vault MITM proxy for credential injection + allowlisting (`docs/security/network-egress-isolation.md:119-122`). | proxy URL | unset | 🔒 Set to the agent-vault proxy (locked-stack decision). |
| `NO_PROXY` (process env) | Hosts that bypass the proxy (`:122`). | comma list | unset | 🔒 Must include `ai` / `http://ai` (Aperture gateway) per locked stack, plus `localhost`, `127.0.0.1`, and the STT host:8765. |
| Docker `internal` network / `network_mode` override | Two-network split: agent on no-internet `internal`, only egress-needing services dual-homed (`network-egress-isolation.md:76-96`). | compose override | `network_mode: host` (full egress) | ❓ The Docker-egress guide assumes the *whole stack* runs in Compose; here only the in-VM terminal sandbox is Docker. Recommend instead relying on the VM-level proxy + NixOS firewall for egress control, and segmenting the sandbox network if you later run untrusted code. |
| `security.allow_private_urls` | Lets web/browser/vision tools reach RFC1918/loopback/CGNAT/metadata destinations (`docs/user-guide/security.md:530-537`). | bool | `false` | ❓ Default `false` blocks the agent from hitting LAN services — but you *want* it to reach the Tailscale gateway (`http://ai`), the STT host, and any LAN. The host-substring guard stays on regardless. Recommend `true` (deliberate home-network trust boundary), accepting prompt-injection-to-LAN risk; mitigated by the docker sandbox + proxy allowlist. |
| `security.website_blocklist.enabled` / `.domains` / `.shared_files` | Deny specific domains across all URL tools (`security.md:497-509`). | bool / list / paths | disabled | ✅ Leave off for a personal server; add domains only if you want guardrails. |

### Secrets, credential sources & persistence

Resolution model: API keys live in the agent-vault secret manager and are pulled at startup; the bootstrap token lives in `~/.hermes/.env` (`docs/user-guide/secrets/index.md`). OAuth/device-code tokens Hermes *owns* persist to `~/.hermes/auth.json`; the **credential pool** strips raw borrowed/reference secrets before any disk write so external-provider creds fail closed at the boundary (`agent/credential_persistence.py:1-26`). `.env` does not override an already-set process env var (agent-vault-injected env wins).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| Secret source = agent-vault (bootstrap token in `.env`) | External secret manager pulled at startup; per-provider keys rotate centrally (`secrets/index.md`). | bws/Vault/1Password/custom module | none (keys in `.env`) | 🔒 agent-vault via MITM proxy (locked). Bootstrap token in the Nix-managed env file; everything else (OPENAI_API_KEY, Exa, Honcho, Langfuse if used) injected. |
| `~/.hermes/.env` | Last-resort key store + non-secret env. Under NixOS it's owned by the unit's env/secret file; not edited interactively. | key=value | — | 🔒 Hold only the agent-vault bootstrap token + non-secret env (proxy vars). Declare via NixOS secret file (e.g. agenix/sops), never plaintext in the store. |
| `~/.hermes/auth.json` (credential pool) | Hermes-owned OAuth/device tokens persisted across restart; raw values for borrowed sources are stripped (`credential_persistence.py:17-26`). Persistable sources: anthropic/minimax/nous/openai-codex/xai (`:20-26`). | managed file | auto | ✅ No config; ensure it's on the VM's persistent volume so model OAuth survives reboot. `chmod 600`. |
| `terminal.docker_forward_env` / `terminal.env_passthrough` / `terminal.credential_files` | Explicit allowlists for which secrets/files cross into the docker sandbox (`security.md:344-447`). | lists | empty (nothing forwarded) | 🔒 Keep empty — secrets must NOT enter the sandbox; the MITM proxy is how the agent's code reaches credentialed APIs. Add only task-scoped tokens (e.g. `GITHUB_TOKEN`) deliberately. |

### Logging level & secret redaction

Logs live under `~/.hermes/logs/` (`agent.log`, `errors.log`, `gateway.log`, `gui.log`), all rotating with a `RedactingFormatter` so secrets never hit disk (`hermes_logging.py:7-22`). Session trajectories are always logged to `logs/session_*.json` and can't be disabled via config (`cli-config.yaml.example:894-906`).

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `logging.level` | Root log level read from config (`hermes_logging.py:251-253,516-536`). | `DEBUG`/`INFO`/`WARNING`/… | `INFO` | ✅ Keep `INFO`. Use `--verbose`/`-v` for ad-hoc DEBUG console (`:323`). |
| `logging.max_size_mb` / `logging.backup_count` | Rotating-file size + retained count (`:516-536`). | ints | code defaults (unconfirmed exact values) | ✅ Leave default; revisit only if the persistent volume fills. |
| `agent.verbose` | Verbose agent logging (`cli-config.yaml.example:625`). | bool | `false` | ✅ Leave `false`. |
| `security.redact_secrets` (`HERMES_REDACT_SECRETS`) | Master switch for the regex secret-redactor over logs + tool output; matches `sk-…`, `ghp_…`, Bearer tokens, DB URLs, query params, env assignments (`agent/redact.py:59-67,330`; wired in `cli.py:700-702`). | bool | `true` | 🔒 Keep `true` (never disable on a server). It's the only thing keeping agent-vault-injected keys out of `gui.log`/`agent.log`. |
| `privacy.redact_pii` | Strips phone numbers + hashes user/chat IDs in the LLM prompt (not names) (`cli-config.yaml.example:1134-1140`). | bool | `false` | ❓ Single-user → low value (it's your own data). Leave `false`; flip to `true` only if you forward third-party messages through BlueBubbles and want IDs hashed before they reach the model. |

### SSL / CA guard & misc security floor

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `HERMES_SKIP_SSL_GUARD` | The SSL guard validates `HERMES_CA_BUNDLE`/`SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`/`CURL_CA_BUNDLE` + certifi at startup, failing fast on a broken CA bundle (`agent/ssl_guard.py:18-84`). This var bypasses it. | `1`/`true`/`yes`/`on` | unset (guard on) | ❓ The agent-vault **MITM proxy presents its own CA**, so you must trust that CA. Recommend: install the proxy CA into the VM trust store and point `HERMES_CA_BUNDLE` at a bundle that includes it (guard stays on, validates it). Only set `HERMES_SKIP_SSL_GUARD=1` if the bundle path legitimately looks unusual but downstream clients work (managed-trust env). |
| `HERMES_CA_BUNDLE` | Custom CA bundle for all hermes HTTP clients (`ssl_guard.py:18-21`). | path to PEM | system/certifi | 🔒 Point at a PEM that includes the agent-vault MITM CA so HTTPS-intercepted egress validates. |
| `security.allow_lazy_installs` | Allows runtime venv-scoped `pip install` of optional deps from an in-tree allowlist (`security.md:644-677`). | bool | `true` | ❓ On NixOS the venv is immutable and network may be proxy-gated, so lazy installs will fail noisily. Recommend `false` and pre-declare every needed extra in the Nix derivation. |
| `security.tirith_enabled` / `_path` / `_timeout` / `_fail_open` | Content-level pre-exec command scanner (homograph URLs, pipe-to-shell) (`security.md:549-558`, `cli-config.yaml.example:323-327`). | bools/path/int | `tirith_enabled: true`, `tirith_timeout: 5`, `tirith_fail_open: true` | ✅ Keep enabled. Consider `tirith_fail_open: false` for a stricter posture — but only after confirming the tirith binary is in the Nix image (else every command blocks). |
| `security.acked_advisories` | Dismissed supply-chain advisory IDs, set via `hermes doctor --ack` (`security.md:634-640`). | list | empty | ✅ Default; managed via `hermes doctor` (read-only, not blocked). |

[^ttl]: `_DEFAULT_TTL_SECONDS = 12*60*60` (12h); refresh token `_REFRESH_TTL_SECONDS = 30d` (`plugins/dashboard_auth/basic/__init__.py:89-90`).
[^lf]: Langfuse defaults from `plugins/observability/langfuse/README.md:42-46`; sample rate and env/release tags are unset (full-sample) unless overridden.


---

Now I have everything confirmed:
- `skills.creation_nudge_interval` default is **10** in source (agent_init.py:1206), though the example file shows **15** as a suggested value. I'll note both.
- `HERMES_LANGUAGE`, `HERMES_BUNDLED_LOCALES` are real env vars (undocumented in env-vars.md — unique to this domain).
- `display.language` default `"en"`.

I have all the data I need. Let me write the deliverable markdown section.

## Skills, autonomy & environment variables

This domain covers skill loading/creation/curation, the autonomous-iteration and tool-loop circuit-breakers that govern unattended runs, locale/i18n, progressive subdirectory context discovery, first-run/onboarding controls, and a grouped catch-all reference of **every** environment variable in the Hermes env-var reference (with cross-domain ownership flagged).

### Skills — creation, curation & loading

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `skills.creation_nudge_interval` | Every N tool-calling iterations, nudge the model to consider saving a new skill after a complex task (`cli-config.yaml.example:578-582`; nudge wired in `agent/agent_init.py:1203-1206`). `0` disables. | int ≥ 0 | **10** (source default in `agent_init.py:1206`; the example file *suggests* `15`) | ❓ Keep at `10` for an always-on agent that should build procedural memory. Raise to `25-30` or set `0` if you find auto-skill churn noisy. |
| `skills.guard_agent_created` | Run the keyword/pattern security scanner on skills the agent writes via `skill_manage` (`hermes_cli/config.py:1834-1844`). Content-scanner, *not* an approval gate. | `true` / `false` | `false` (`config.py:1844`) | ✅ Leave `false` — single-user, the agent can already run the same code via `terminal` with no gate, so the scan only adds friction. |
| `skills.write_approval` | Approval gate: stage every `skill_manage` write (create/edit/patch/delete/write_file/remove_file) — foreground turns *and* the background self-improvement review — for `/skills approve` review under `~/.hermes/pending/skills/` (`config.py:1845-1856`; docs `features/skills.md:404-435`). | `true` / `false` | `false` (`config.py:1856`) | ❓ Recommend `false` (single-user, trusted, you want autonomous procedural memory). Flip `true` only if you want eyes on every self-improvement write. |
| `skills.external_dirs` | Extra read-only skill directories scanned alongside `~/.hermes/skills/`; each entry expands `~` and `${VAR}` (`config.py:1819`; `agent/skill_utils.py:381-461`; docs `features/skills.md:251-291`). Local skills win on name collision; skill *creation* always writes to `~/.hermes/skills/`. | list of paths | `[]` (`config.py:1819`) | ✅ Leave empty unless you keep a shared cross-agent skills repo on the VM; then point one entry at it. |
| `skills.template_vars` | Substitute `${HERMES_SKILL_DIR}` / `${HERMES_SESSION_ID}` in SKILL.md before the agent reads it (`config.py:1820-1824`; `agent/skill_preprocessing.py:124-139`). | `true` / `false` | `true` (`config.py:1824`) | ✅ Leave `true` — needed for bundled skills that reference their own scripts. |
| `skills.inline_shell` | Pre-execute `` !`cmd` `` snippets in SKILL.md bodies and inline their stdout before the agent reads them (`config.py:1825-1831`; `skill_preprocessing.py:102-121`). Runs author shell on the host with **no approval gate**. | `true` / `false` | `false` (`config.py:1831`) | ✅ Leave `false`. The locked stack runs skills' real work in the in-VM Docker sandbox; host-side inline shell is an unsandboxed footgun. Enable only for skills you author. |
| `skills.inline_shell_timeout` | Per-snippet timeout (seconds) when `inline_shell` is on (`config.py:1832`; `skill_preprocessing.py:138`). | int seconds | `10` (`config.py:1833`) | ✅ Moot while `inline_shell: false`. |
| `skills.disabled` | Global list of skill names hidden from index, `skills_list`, slash commands, and offer surfaces (`agent/skill_utils.py:318-353`). Not in the example; read dynamically. | list of skill names | `[]` (empty) | ❓ Optional. Add the noisy bundled skills you'll never use (e.g. China-platform or gaming skills) to trim the prompt index. |
| `skills.platform_disabled.<platform>` | Per-platform disabled-skill list, unioned with the global `disabled` (`skill_utils.py:346-353`). Resolves platform from `HERMES_PLATFORM` / `HERMES_SESSION_PLATFORM`. | map `platform → [names]` | `{}` | ✅ Leave unset — only CLI + BlueBubbles are active; use the global `disabled` instead. |
| `skills.config.<key>` | Storage namespace for skill-declared config vars (paths/prefs a SKILL.md requests via `metadata.hermes.config`) (`skill_utils.py:498-641`, prefix `skills.config`). Populated by `hermes config migrate`. | per-skill keys | unset | ✅ Set on demand when a skill prompts for it (e.g. `wiki.path`); not a global decision. |
| Blank-slate / opt-out marker (`.no-bundled-skills`) | Stop bundled-skill seeding on install/update; `hermes skills opt-out [--remove]` / `opt-in --sync`, or install `--no-skills` / `profile create --no-skills` (docs `features/skills.md:20-48`). | marker present / absent | seeded (marker absent) | ❓ Keep bundled skills seeded for a capable home agent. Run `opt-out` only if you want a deliberately minimal, hand-curated skill set. |
| Skill bundles (`~/.hermes/skill-bundles/<slug>.yaml`) | YAML alias loading N skills under one `/<bundle>` slash command; `name`/`description`/`skills`/`instruction` (`agent/skill_bundles.py:1-41,116-165`; docs `features/skills.md:293-376`). Bundle wins over a same-named skill. Override dir via `HERMES_BUNDLES_DIR`. | YAML files | none installed | ❓ Optional convenience. Define a bundle (`hermes bundles create`) for any recurring multi-skill task; skip if you invoke skills singly. |
| Skills Hub sources / taps (`~/.hermes/.hub/taps.json`) | Browse/search/install skills from `official`, `skills-sh`, `well-known`, `github`, `clawhub`, `lobehub`, `browse-sh`, direct URL (docs `features/skills.md:441-797`). All non-builtin installs run the security scanner; `--force` overrides non-dangerous blocks only. | source ids / tap repos | default taps only (openai/anthropics/huggingface/NVIDIA/gstack) | ✅ Leave default taps. Add custom taps only if you maintain a private skills repo. Set `GITHUB_TOKEN` (see env table) to lift the 60 req/hr unauth rate limit. |

### Autonomous skill curation (Curator)

| Setting (config key) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `curator.enabled` | Background maintenance of **agent-created** skills: marks stale, archives (never deletes) obsolete ones, forks an aux-model agent to consolidate overlaps. Inactivity-triggered from session start — no cron daemon (`config.py:1859-1899`; docs `features/curator.md`). | `true` / `false` | `true` (`config.py:1870`) | ✅ Leave `true` — exactly what an always-on agent wants to keep its procedural memory tidy. |
| `curator.interval_hours` | Minimum hours between curator runs. | int hours | `168` (7 days) (`config.py:1872`) | ✅ Default is fine for a personal server. |
| `curator.min_idle_hours` | Only run after the agent has been idle this long. | int hours | `2` (`config.py:1874`) | ✅ Leave default. |
| `curator.stale_after_days` | Days unused before a skill is marked stale. | int days | `30` (`config.py:1876`) | ✅ Leave default. |
| `curator.archive_after_days` | Days unused before a skill is archived to `skills/.archive/` (recoverable; no auto-delete). | int days | `90` (`config.py:1879`) | ✅ Leave default. |
| `curator.prune_builtins` | Also archive long-unused *bundled* built-ins (hub installs never pruned). | `true` / `false` | `true` (`config.py:1890`) | ❓ Keep `true` to let the prompt index shrink to skills you actually use. Set `false` if you want every bundled skill permanently available. |
| `curator.backup.enabled` | Snapshot `~/.hermes/skills/` to `.curator_backups/` before each real pass (`hermes curator rollback`). | `true` / `false` | `true` (`config.py:1896`) | ✅ Leave `true` — cheap safety net. |
| `curator.backup.keep` | Retain last N curator snapshots. | int | `5` (`config.py:1897`) | ✅ Leave default. |

### Autonomy & iteration (loop budgets and circuit-breakers not in core model config)

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `agent.max_turns` / `HERMES_MAX_ITERATIONS` | Max tool-calling iterations per conversation (`cli-config.yaml.example:597-600`; env in env-vars `:592`; `run_agent.py:354`). Env overrides config. | int | example shows `60`; runtime/env default **90** (env-vars `:592`, `run_agent.py:354`) | ❓ Recommend `90` (default) for an autonomous home agent doing open-ended tasks. Drop to `30-50` only to cap cost on a runaway loop. |
| `tool_loop_guardrails.warnings_enabled` | Append guidance to repeated failed/non-progressing tool results (tool still runs) (`cli-config.yaml.example:344-345`). | `true` / `false` | `true` (`:345`) | ✅ Leave on. |
| `tool_loop_guardrails.hard_stop_enabled` | Opt-in circuit breaker that *stops* a loop instead of burning the whole iteration budget — meant for autonomous/cron runs (`cli-config.yaml.example:342-346`). | `true` / `false` | `false` (`:346`) | ❓ Recommend `true` for an always-on/unattended agent — a stuck loop on a home server otherwise spends the full 90-iteration budget. Keep `false` if you babysit sessions interactively. |
| `tool_loop_guardrails.warn_after.{exact_failure,same_tool_failure,idempotent_no_progress}` | Thresholds before a soft warning fires (`cli-config.yaml.example:347-350`). | ints | `2 / 3 / 2` | ✅ Leave defaults. |
| `tool_loop_guardrails.hard_stop_after.{...}` | Thresholds before a hard stop fires (only if `hard_stop_enabled`) (`cli-config.yaml.example:351-354`). | ints | `5 / 8 / 5` | ✅ Leave defaults if you enable hard stops. |
| `delegation.max_iterations` | Max tool-calling turns per delegated child agent (`cli-config.yaml.example:923`). | int | `50` (`:923`) | ✅ Leave default. |
| `delegation.max_spawn_depth` | Delegation tree depth cap (1 = flat) (`cli-config.yaml.example:926`). | 1-3 | `1` | ❓ Keep `1`. Raise to `2` only if you want orchestrator subagents spawning their own workers. |
| `delegation.subagent_auto_approve` | When a subagent hits a dangerous-command prompt: auto-deny (`false`) or auto-approve-once (`true`) — never blocks on stdin (`cli-config.yaml.example:930-933`). | `true` / `false` | `false` (`:930`) | ✅ Leave `false` for interactive use. Flip `true` only for unattended cron/batch pipelines. |
| `HERMES_YOLO_MODE` / `--yolo` | Bypass dangerous-command approval prompts entirely (env-vars `:594`). | `1` / unset | unset | ❓ Recommend leaving **off** — the agent runs sandboxed in Docker, but YOLO removes the last gate on host-affecting tools. Enable per-session only for trusted batch work. |
| `HERMES_EXEC_ASK` | Enable execution-approval prompts in gateway mode (env-vars `:617`). | `true` / `false` | unset | ✅ Single-user trusted; leave default. |
| `HERMES_ACCEPT_HOOKS` / `hooks_auto_accept` | Auto-approve unseen shell hooks declared in `config.yaml` without a TTY prompt (env-vars `:595`). | flag | off | ✅ Leave off unless you run headless with vetted hooks. |

### Internationalization / locale

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `display.language` | Locale for Hermes' own static user-facing strings (approval prompts, some gateway replies). Agent output stays English (`agent/i18n.py:1-28,22-26`; `hermes_cli/config.py:1470`). | `en, zh, zh-hant, ja, de, es, fr, tr, uk, af, ko, it, ga, pt, ru, hu` (`i18n.py:43-46`) + aliases | `"en"` (`config.py:1470`, `i18n.py:47`) | ✅ Leave `en`. |
| `HERMES_LANGUAGE` | Process-level locale override (resolution order: `lang=` arg → this env → `display.language` → `en`) (`agent/i18n.py:22-28,243`). Not in the env-vars doc — unique to this domain. | one of the supported codes | unset → falls to `display.language` | ✅ Leave unset. |
| `HERMES_BUNDLED_LOCALES` | Override the `locales/` catalog directory (set by the Nix wrapper / packagers) (`agent/i18n.py:93-118`). Not in the env-vars doc — unique here. | dir path | unset (auto-discovered) | 🔒 Likely set automatically by your NixOS wrapper; do not set by hand. |
| `stt.local.language` | Forced language for local STT transcription (`cli-config.yaml.example:878`; `config.py:1682`). | `en`/`es`/… or empty=auto | `""` (auto) (`config.py:1682`) | 🔒 STT is Parakeet on the host via `stt.provider=openai` + base_url, so the *local* faster-whisper path is unused — this key is moot. |
| `HERMES_LOCAL_STT_LANGUAGE` | Default language for `HERMES_LOCAL_STT_COMMAND` / local whisper fallback (env-vars `:105`). | lang code | `en` | 🔒 Unused — STT routes to host Parakeet, not the local-command path. |

### Subdirectory hints & context-file injection

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| Progressive subdirectory discovery | At session start loads the CWD's project context file; as the agent navigates into subdirs (and walks up parents) it injects each subdir's `AGENTS.md`/`CLAUDE.md` once, on demand (docs `features/context-files.md:16,30-52`). Subdir files pass the same prompt-injection security scan. | always-on behavior | enabled (no toggle) | ✅ No config needed — drop per-directory `AGENTS.md` files where you want scoped guidance. |
| `HERMES_MD_NAMES` | Comma-separated rules-file names auto-injected as context (env-vars `:599`). | comma list | `AGENTS.md,CLAUDE.md,.cursorrules,SOUL.md` | ✅ Leave default unless you use non-standard rules filenames. |
| `HERMES_IGNORE_RULES` / `--ignore-rules` | Skip auto-injection of `AGENTS.md`/`SOUL.md`/`.cursorrules`/memory/preloaded skills (env-vars `:597`). | flag | off | ✅ Leave off — you want context injected. |
| Skill SKILL.md frontmatter: `platforms` / `metadata.hermes.environments` | Per-skill OS gate (`platforms:` — hard compat) and runtime-relevance gate (`environments: [kanban|docker|s6]`) that hides a skill from offer surfaces but still allows explicit load (`agent/skill_utils.py:128-269`). | lists | absent = all platforms/envs | 🔒 Authored per-skill, not a global setting. In the Linux VM, `linux`-tagged and `docker`-env skills surface; `macos`-only skills (iMessage, FindMy, etc.) auto-hide. |

### Onboarding / first-run & bundled-set overrides

| Setting (config key / env var) | What it does | Options / range | Default | Recommendation |
|---|---|---|---|---|
| `HERMES_BUNDLED_SKILLS` | Comma-separated override for the list of bundled skills loaded at startup (env-vars `:628`). | comma list | built-in bundled set | ✅ Leave unset — let the full bundled catalog seed; trim later via `skills.disabled` or the curator. |
| `HERMES_OPTIONAL_SKILLS` | Comma-separated optional-skill names to auto-install on first run (env-vars `:629`). | comma list | none | ❓ Optional. Pre-seed first-run installs here (e.g. a research or devops skill) if you want them present without a manual `hermes skills install`. |
| `HERMES_CORE_TOOLS` | Override the canonical core tool list (advanced; rarely needed) (env-vars `:627`). | comma list | built-in | ✅ Leave unset. |
| `HERMES_IGNORE_USER_CONFIG` / `--ignore-user-config` | Skip `~/.hermes/config.yaml`, use built-in defaults (`.env` still loads) (env-vars `:596`). | flag | off | ✅ Off — troubleshooting only. |
| `HERMES_SAFE_MODE` / `--safe-mode` | Disable ALL customizations: no plugin discovery, no MCP loading (also sets ignore-rules + ignore-user-config) (env-vars `:598`). | flag | off | ✅ Off — diagnostic escape hatch only. |
| `HERMES_AGENT_HELP_GUIDANCE` | Append extra guidance text to the system prompt for custom deployments (env-vars `:635`). | string | unset | ❓ Optional — use it to bake in always-on house rules for your agent (e.g. "prefer Exa for search; use the Docker sandbox"). |
| `HERMES_AGENT_LOGO` | Override the ASCII banner logo at CLI startup (env-vars `:636`). | string/path | built-in | ✅ Cosmetic; leave default. |

### Skill / sandbox runtime env vars (autoset — do not hand-set)

| Variable | What it does | Default | Recommendation |
|---|---|---|---|
| `HERMES_SKILL_DIR` | Absolute skill directory, substituted into SKILL.md `${HERMES_SKILL_DIR}` (`agent/skill_preprocessing.py:10-58`). | set per skill load | 🔒 Autoset by the loader — never set manually. |
| `HERMES_SESSION_ID` | Current session id, exported into every tool subprocess (terminal, execute_code, Docker backend, delegated subagents); substituted into SKILL.md `${HERMES_SESSION_ID}` (env-vars `:655`; `skill_preprocessing.py`). | set per session | 🔒 Autoset — never set manually. |
| `HERMES_BUNDLES_DIR` | Override the skill-bundles directory (test hook) (`agent/skill_bundles.py:66-75`). | `<HERMES_HOME>/skill-bundles` | ✅ Leave unset. |
| `HERMES_PLATFORM` / `HERMES_SESSION_PLATFORM` | Resolve the active platform for `skills.platform_disabled` filtering (`agent/skill_utils.py:340-345`). | set by gateway | 🔒 Autoset per session — don't set manually. |
| `HERMES_KANBAN_TASK` / `HERMES_KANBAN_BOARD` | Set by the kanban dispatcher; gate `environments: [kanban]` skills + kanban tools (`skill_utils.py:204`; env-vars `:607,110`). | unset (no kanban) | ✅ Unused unless you run the kanban orchestrator. |
| `TERMINAL_DOCKER_FORWARD_ENV` | Forward extra env vars into Docker terminal sessions. Skill-declared `required_environment_variables` forward automatically (env-vars `:199`; docs `features/skills.md:206-207`). | unset | 🔒 With `terminal.backend=docker`, skills' declared keys already pass through; set this only for non-skill vars you need in-sandbox. |

---

### Complete environment-variable reference (grouped)

Every variable in `/tmp/hermes-agent-ref/website/docs/reference/environment-variables.md`, grouped by the doc's own sections. The **Domain** column marks whether a var is **(here)** — owned by this Skills/autonomy/env domain — or **(other: …)** when another domain owns it. Defaults shown where the doc states one.

#### LLM Providers (env-vars `:11-114`) — Domain: other (model plane)
🔒 Decided by the locked stack: `model.provider=custom` → `OPENAI_BASE_URL=http://ai/v1` + `OPENAI_API_KEY` (via agent-vault), with `gemini-3.5` / `qwen-local` fallbacks configured in `config.yaml`. The long provider-key list below is otherwise unused.

| Variable | Default | Domain |
|---|---|---|
| `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`, `HERMES_OPENROUTER_CACHE`, `HERMES_OPENROUTER_CACHE_TTL` | — / — / off / — | other (model) |
| `NOUS_BASE_URL`, `NOUS_INFERENCE_BASE_URL` | — | other (model) |
| `OPENAI_API_KEY`, `OPENAI_BASE_URL` | — | 🔒 other (model) — **set by your custom endpoint + agent-vault** |
| `LM_API_KEY`, `LM_BASE_URL` | — / `http://localhost:1234/v1` | other (model) |
| `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, `HERMES_COPILOT_ACP_COMMAND`, `COPILOT_CLI_PATH`, `HERMES_COPILOT_ACP_ARGS`, `COPILOT_ACP_BASE_URL`, `COPILOT_API_BASE_URL` | — / — / — / `copilot` / — / `--acp --stdio` / — / — | other (model); **note `GITHUB_TOKEN` is dual-use → Skills Hub, see Tool APIs** |
| `GLM_API_KEY`/`ZAI_API_KEY`/`Z_AI_API_KEY`, `GLM_BASE_URL` | — / `https://api.z.ai/api/paas/v4` | other (model) |
| `KIMI_API_KEY`, `KIMI_CODING_API_KEY`, `KIMI_BASE_URL`, `KIMI_CN_API_KEY` | — / — / `https://api.moonshot.ai/v1` / — | other (model) |
| `ARCEEAI_API_KEY`, `ARCEE_BASE_URL` | — / `https://api.arcee.ai/api/v1` | other (model) |
| `GMI_API_KEY`, `GMI_BASE_URL` | — / `https://api.gmi-serving.com/v1` | other (model) |
| `MINIMAX_API_KEY`, `MINIMAX_BASE_URL`, `MINIMAX_CN_API_KEY`, `MINIMAX_CN_BASE_URL` | — / `…/anthropic` / — / `…/anthropic` | other (model) |
| `KILOCODE_API_KEY`, `KILOCODE_BASE_URL` | — / `https://api.kilo.ai/api/gateway` | other (model) |
| `XIAOMI_API_KEY`, `XIAOMI_BASE_URL` | — / `https://api.xiaomimimo.com/v1` | other (model) |
| `TOKENHUB_API_KEY`, `TOKENHUB_BASE_URL` | — / `https://tokenhub.tencentmaas.com/v1` | other (model) |
| `AZURE_FOUNDRY_API_KEY`, `AZURE_FOUNDRY_BASE_URL`, `AZURE_ANTHROPIC_KEY`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_CLIENT_CERTIFICATE_PATH`, `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_AUTHORITY_HOST`, `IDENTITY_ENDPOINT`/`MSI_ENDPOINT` | — | other (model/Azure) |
| `HF_TOKEN`, `HF_BASE_URL` | — / `https://router.huggingface.co/v1` | other (model) |
| `GOOGLE_API_KEY`/`GEMINI_API_KEY`, `GEMINI_BASE_URL`, `HERMES_GEMINI_CLIENT_ID`, `HERMES_GEMINI_CLIENT_SECRET`, `HERMES_GEMINI_PROJECT_ID` | — | other (model) — relevant to `gemini-3.5` fallback |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_TOKEN` | — | other (model) |
| `DASHSCOPE_API_KEY`, `DASHSCOPE_BASE_URL`, `ALIBABA_CODING_PLAN_API_KEY`, `ALIBABA_CODING_PLAN_BASE_URL` | — / `…dashscope-intl…/v1` / — / — | other (model) — relevant to `qwen-local` |
| `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, `NOVITA_API_KEY`, `NOVITA_BASE_URL`, `NVIDIA_API_KEY`, `NVIDIA_BASE_URL`, `STEPFUN_API_KEY`, `STEPFUN_BASE_URL`, `OLLAMA_API_KEY`, `OLLAMA_BASE_URL`, `XAI_API_KEY`, `XAI_BASE_URL`, `MISTRAL_API_KEY` | various | other (model) |
| `AWS_REGION`, `AWS_PROFILE`, `BEDROCK_BASE_URL`, `HERMES_QWEN_BASE_URL`, `OPENCODE_ZEN_API_KEY`, `OPENCODE_ZEN_BASE_URL`, `OPENCODE_GO_API_KEY`, `OPENCODE_GO_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, `HERMES_MODEL` | various | other (model); **`HERMES_MODEL`/`HERMES_INFERENCE_MODEL` = autonomy/model overrides (also in Agent Behavior)** |
| `VOICE_TOOLS_OPENAI_KEY`, `HERMES_LOCAL_STT_COMMAND`, `HERMES_LOCAL_STT_LANGUAGE` (`en`) | — / — / `en` | other (STT/TTS); `HERMES_LOCAL_STT_LANGUAGE` is i18n-adjacent but moot (host Parakeet) |
| `HERMES_HOME` | `~/.hermes` | other (core/profiles) — scopes config, gateway PID, skills/bundles dirs |
| `HERMES_GIT_BASH_PATH`, `HERMES_DISABLE_WINDOWS_UTF8` | — | other (Windows) — N/A on Linux VM |
| `HERMES_KANBAN_HOME`, `HERMES_KANBAN_BOARD` (`default`), `HERMES_KANBAN_DB`, `HERMES_KANBAN_WORKSPACES_ROOT`, `HERMES_KANBAN_DISPATCH_IN_GATEWAY` | — | other (kanban); **kanban also gates `environments:[kanban]` skills → (here)-adjacent** |

#### Provider Auth / OAuth (env-vars `:115-127`) — Domain: other (model + time)
| Variable | Default | Domain |
|---|---|---|
| `HERMES_PORTAL_BASE_URL`, `NOUS_INFERENCE_BASE_URL`, `HERMES_NOUS_MIN_KEY_TTL_SECONDS` (`1800`), `HERMES_NOUS_TIMEOUT_SECONDS` | — | other (model/Nous) |
| `HERMES_DUMP_REQUESTS`, `HERMES_PREFILL_MESSAGES_FILE` | — | (here) — debug/agent behavior (also listed under Agent Behavior) |
| `HERMES_TIMEZONE` | server-local | other (time) — IANA tz; also `timezone` in config (`config.py:1908`) |

#### Tool APIs (env-vars `:129-163`) — Domain: other (tools/web/memory), except GITHUB_TOKEN
🔒 Locked stack: web search/extract = **Exa** (`EXA_API_KEY` via agent-vault); memory = **Honcho hosted** (`HONCHO_API_KEY` via agent-vault); image gen = openai plugin (`OPENAI_API_KEY`). Other keys unused.

| Variable | Default | Domain |
|---|---|---|
| `PARALLEL_API_KEY`, `FIRECRAWL_API_KEY`, `FIRECRAWL_API_URL`, `TAVILY_API_KEY`, `SEARXNG_URL`, `TAVILY_BASE_URL`, `EXA_API_KEY` | — | other (web search) — 🔒 only `EXA_API_KEY` used |
| `BROWSERBASE_API_KEY`, `BROWSERBASE_PROJECT_ID`, `BROWSER_USE_API_KEY`, `FIRECRAWL_BROWSER_TTL` (`300`), `BROWSER_CDP_URL`, `CAMOFOX_URL` (`http://localhost:9377`), `CAMOFOX_USER_ID`, `CAMOFOX_SESSION_KEY`, `CAMOFOX_ADOPT_EXISTING_TAB`, `BROWSER_INACTIVITY_TIMEOUT`, `AGENT_BROWSER_ARGS` | — | other (browser) — 🔒 local in-VM Chromium, cloud browsers unused |
| `FAL_KEY` | — | other (image gen) |
| `GROQ_API_KEY`, `ELEVENLABS_API_KEY`, `STT_GROQ_MODEL` (`whisper-large-v3-turbo`), `GROQ_BASE_URL`, `STT_OPENAI_MODEL` (`whisper-1`), `STT_OPENAI_BASE_URL` | — | other (STT/TTS) — 🔒 `STT_OPENAI_BASE_URL` points at host Parakeet:8765 |
| `GITHUB_TOKEN` | — | **(here)** — Skills Hub API rate-limit lift + skill publish (docs `features/skills.md:682-684`) |
| `HONCHO_API_KEY`, `HONCHO_BASE_URL`, `HINDSIGHT_TIMEOUT` (`60`), `SUPERMEMORY_API_KEY` | — | other (memory) — 🔒 `HONCHO_API_KEY` (hosted) via agent-vault |
| `DAYTONA_API_KEY` | — | other (sandbox) — unused (Docker backend) |

#### Langfuse Observability (env-vars `:165-179`) — Domain: other (observability plugin)
`HERMES_LANGFUSE_PUBLIC_KEY`, `…_SECRET_KEY`, `…_BASE_URL` (`https://cloud.langfuse.com`), `…_ENV`, `…_RELEASE`, `…_SAMPLE_RATE` (`1.0`), `…_MAX_CHARS` (`12000`), `…_DEBUG`, plus SDK fallbacks `LANGFUSE_PUBLIC_KEY`/`SECRET_KEY`/`BASE_URL`. ✅ Off unless you enable the plugin.

#### Nous Tool Gateway (env-vars `:181-190`) — Domain: other (tool gateway)
`TOOL_GATEWAY_DOMAIN` (`nousresearch.com`), `TOOL_GATEWAY_SCHEME` (`https`), `TOOL_GATEWAY_USER_TOKEN` (auto from Nous auth), `FIRECRAWL_GATEWAY_URL`. ❓ Tied to the open "Nous Tool Gateway scope" decision — normally auto-configured via `hermes model`/`hermes tools`; leave manual overrides unset.

#### Terminal Backend (env-vars `:192-210`) — Domain: other (sandbox), one (here)
🔒 `TERMINAL_ENV=docker` (in-VM). | `TERMINAL_ENV` (`local`/`docker`/`ssh`/…), `HERMES_DOCKER_BINARY`, `TERMINAL_DOCKER_IMAGE` (`nikolaik/python-nodejs:python3.11-nodejs20`), **`TERMINAL_DOCKER_FORWARD_ENV` → (here)** (skill env passthrough), `TERMINAL_DOCKER_VOLUMES`, `TERMINAL_DOCKER_MOUNT_CWD_TO_WORKSPACE` (`false`), `TERMINAL_SINGULARITY_IMAGE`, `TERMINAL_MODAL_IMAGE`, `TERMINAL_DAYTONA_IMAGE`, `TERMINAL_TIMEOUT`, `TERMINAL_LIFETIME_SECONDS`, `TERMINAL_CWD` (deprecated), `SUDO_PASSWORD`.

#### SSH Backend (`:212-220`), Container Resources (`:222-230`), Persistent Shell (`:232-238`) — Domain: other (sandbox)
SSH: `TERMINAL_SSH_HOST/USER/PORT(22)/KEY/PERSISTENT`. Resources: `TERMINAL_CONTAINER_CPU(1)`, `_MEMORY(5120)`, `_DISK(51200)`, `_PERSISTENT(true)`, `TERMINAL_SANDBOX_DIR(~/.hermes/sandboxes/)`. Persistent shell: `TERMINAL_PERSISTENT_SHELL(true)`, `TERMINAL_LOCAL_PERSISTENT(false)`, `TERMINAL_SSH_PERSISTENT`. ✅ Tune CPU/mem/disk to the VM; rest default.

#### Messaging (env-vars `:240-457`) — Domain: other (messaging)
🔒 Locked stack: CLI + **BlueBubbles** only. Relevant: `BLUEBUBBLES_SERVER_URL`, `BLUEBUBBLES_PASSWORD`, `BLUEBUBBLES_WEBHOOK_HOST` (`127.0.0.1`), `BLUEBUBBLES_WEBHOOK_PORT` (`8645`), `BLUEBUBBLES_HOME_CHANNEL`, `BLUEBUBBLES_ALLOWED_USERS`, `BLUEBUBBLES_ALLOW_ALL_USERS`. **All other platforms off** — Telegram/Discord/Slack/Google Chat/WhatsApp(+Cloud)/Signal/Twilio-SMS/Email/DingTalk/Feishu/WeCom(+callback)/Weixin/QQ/Mattermost/Matrix/HomeAssistant/Webhook/`API_SERVER_*`/`GATEWAY_*`/`MESSAGING_CWD` vars are not set. (~200 vars; not enumerated individually — none in this domain.)

#### Web Dashboard & Hermes Desktop (`:459-477`), Microsoft Graph / Teams (`:479-514`), LINE (`:516-536`), ntfy (`:538-552`) — Domain: other (dashboard/messaging)
`HERMES_DASHBOARD_BASIC_AUTH_*`, `HERMES_DASHBOARD_OAUTH_CLIENT_ID`, `HERMES_DASHBOARD_PUBLIC_URL`, `HERMES_DASHBOARD_OIDC_*`, `HERMES_DESKTOP_REMOTE_URL`; `MSGRAPH_*`, `MSGRAPH_WEBHOOK_*`, `TEAMS_*`; `LINE_*`; `NTFY_*`. ✅ Single-user local-first; leave unset (dashboard auth only matters on a non-loopback bind).

#### Advanced Messaging Tuning (`:556-579`) — Domain: other (messaging)
`HERMES_TELEGRAM_*`, `HERMES_DISCORD_*`, `HERMES_MATRIX_*`, `HERMES_FEISHU_*`, `HERMES_WECOM_*` batch knobs; plus `HERMES_VISION_DOWNLOAD_TIMEOUT` (`30`), `HERMES_RESTART_DRAIN_TIMEOUT` (`900`), `HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT`, `HERMES_GATEWAY_BUSY_INPUT_MODE` (`queue`/`steer`/`interrupt`). ✅ Unused (BlueBubbles only).

#### Gateway / Cron / Display (`:580-586`) — Domain: mixed
`HERMES_GATEWAY_BUSY_ACK_ENABLED`(true), `HERMES_GATEWAY_NO_SUPERVISE`, `HERMES_GATEWAY_BOOTSTRAP_STATE`, `HERMES_FILE_MUTATION_VERIFIER`(true) → other (gateway/display); `HERMES_CRON_TIMEOUT`(600), `HERMES_CRON_SCRIPT_TIMEOUT`(120), `HERMES_CRON_MAX_PARALLEL`(4) → other (cron, autonomy-adjacent).

#### Agent Behavior (env-vars `:588-637`) — Domain: **(here)** (autonomy/agent), unless noted
| Variable | Default | Notes |
|---|---|---|
| `HERMES_MAX_ITERATIONS` | `90` | (here) — see autonomy table |
| `HERMES_INFERENCE_MODEL`, `HERMES_MODEL` | — | other (model) override |
| `HERMES_YOLO_MODE`, `HERMES_ACCEPT_HOOKS`, `HERMES_EXEC_ASK` | off | (here) — approval gates |
| `HERMES_IGNORE_USER_CONFIG`, `HERMES_IGNORE_RULES`, `HERMES_SAFE_MODE`, `HERMES_MD_NAMES` (`AGENTS.md,CLAUDE.md,.cursorrules,SOUL.md`) | — | (here) — onboarding/context |
| `HERMES_TOOL_PROGRESS`, `HERMES_TOOL_PROGRESS_MODE` | deprecated → `display.tool_progress` | other (display) |
| `HERMES_HUMAN_DELAY_MODE`/`_MIN_MS`/`_MAX_MS`, `HERMES_QUIET` | off | other (display/pacing) |
| `CODEX_HOME` (`~/.codex`) | — | other (codex runtime) |
| `HERMES_KANBAN_TASK` | — | other (kanban) — gates skill `environments:[kanban]` |
| `HERMES_API_TIMEOUT`(1800), `HERMES_API_CALL_STALE_TIMEOUT`(300), `HERMES_STREAM_READ_TIMEOUT`(120), `HERMES_STREAM_STALE_TIMEOUT`(180), `HERMES_STREAM_RETRIES`(3), `HERMES_AGENT_TIMEOUT`(900), `HERMES_AGENT_TIMEOUT_WARNING`, `HERMES_AGENT_NOTIFY_INTERVAL`, `HERMES_CHECKPOINT_TIMEOUT`(30) | — | other (timeouts; autonomy-adjacent for unattended runs) |
| `HERMES_ENABLE_PROJECT_PLUGINS`(off), `HERMES_PLUGINS_DEBUG` | off | other (plugins) |
| `HERMES_BACKGROUND_NOTIFICATIONS`(all), `HERMES_EPHEMERAL_SYSTEM_PROMPT`, `HERMES_PREFILL_MESSAGES_FILE` | — | mixed (agent behavior) |
| `HERMES_ALLOW_PRIVATE_URLS`(off in gateway), `HERMES_REDACT_SECRETS`(true), `HERMES_WRITE_SAFE_ROOT`, `HERMES_DISABLE_FILE_STATE_GUARD` | — | other (security) — 🔒 note `NO_PROXY` excludes `http://ai`; `HERMES_ALLOW_PRIVATE_URLS` may need `true` to reach in-VM/LAN services |
| `HERMES_CORE_TOOLS` | built-in | (here) — onboarding |
| **`HERMES_BUNDLED_SKILLS`** | bundled set | **(here)** — skills |
| **`HERMES_OPTIONAL_SKILLS`** | — | **(here)** — skills |
| `HERMES_DEBUG_INTERRUPT`, `HERMES_DUMP_REQUESTS`, `HERMES_DUMP_REQUEST_STDOUT`, `HERMES_OAUTH_TRACE`, `HERMES_OAUTH_FILE` (`~/.hermes/auth.json`) | — | other (debug/auth) |
| **`HERMES_AGENT_HELP_GUIDANCE`**, **`HERMES_AGENT_LOGO`** | — | **(here)** — onboarding/system-prompt |
| `DELEGATION_MAX_CONCURRENT_CHILDREN` (`3`) | — | (here)-adjacent (autonomy/delegation; config wins) |

#### Interface (env-vars `:639-647`) — Domain: other (TUI/CLI)
`HERMES_TUI`, `HERMES_TUI_DIR`, `HERMES_TUI_RESUME`, `HERMES_TUI_THEME`, `HERMES_INFERENCE_MODEL`. ✅ Local CLI; defaults fine.

#### Session Settings (env-vars `:649-655`) — Domain: other (sessions), one (here)
`SESSION_IDLE_MINUTES`(1440), `SESSION_RESET_HOUR`(4) → other (session reset); **`HERMES_SESSION_ID` → (here)** (autoset into every tool subprocess + SKILL.md template token — never set manually).

#### Config-only sections (env-vars `:657-717`) — Domain: other
Context Compression (`compression.*` / `auxiliary.compression.*`), Auxiliary Task Overrides (`AUXILIARY_VISION_*`, `AUXILIARY_WEB_EXTRACT_*`), Fallback Providers (`fallback_providers` — 🔒 holds `gemini-3.5`/`qwen-local` failover), Provider Routing (`provider_routing.sort|only|ignore|order|require_parameters|data_collection`). All belong to the model/context domains, not this one.

#### Undocumented-in-env-doc but in this domain (source-confirmed)
| Variable | What it does | Default | Domain |
|---|---|---|---|
| `HERMES_LANGUAGE` | i18n locale override (`agent/i18n.py:24,243`) | unset | **(here)** |
| `HERMES_BUNDLED_LOCALES` | Override `locales/` catalog dir (Nix wrapper) (`agent/i18n.py:93-118`) | auto-discovered | **(here)** — 🔒 set by NixOS packaging |
| `HERMES_BUNDLES_DIR` | Override skill-bundles dir (`agent/skill_bundles.py:72`) | `<HERMES_HOME>/skill-bundles` | **(here)** |
| `HERMES_SKILL_DIR` | Skill dir token in SKILL.md (`agent/skill_preprocessing.py:13`) | per-load | **(here)** — autoset |
| `HERMES_PLATFORM` / `HERMES_SESSION_PLATFORM` | Platform scope for `skills.platform_disabled` (`agent/skill_utils.py:340-345`) | per-session | **(here)** — autoset |

**Net for the locked stack:** in this domain only a handful of genuine choices (❓) remain — `tool_loop_guardrails.hard_stop_enabled` (recommend `true` for unattended runs), `skills.write_approval`/`creation_nudge_interval` (recommend defaults: free writes, nudge `10`), `agent.max_turns`/`HERMES_MAX_ITERATIONS` (recommend `90`), `curator.prune_builtins`, optional `skills.disabled` trimming, and onboarding pre-seeds (`HERMES_OPTIONAL_SKILLS`, `HERMES_AGENT_HELP_GUIDANCE`). Everything else is either 🔒 fixed by the architecture or ✅ safe at its default. Source: `/tmp/hermes-agent-ref/cli-config.yaml.example`, `/tmp/hermes-agent-ref/hermes_cli/config.py`, `/tmp/hermes-agent-ref/agent/{skill_utils,skill_bundles,skill_preprocessing,agent_init,i18n}.py`, `/tmp/hermes-agent-ref/website/docs/reference/environment-variables.md`, `/tmp/hermes-agent-ref/website/docs/user-guide/features/{skills,curator,context-files}.md`.


---

