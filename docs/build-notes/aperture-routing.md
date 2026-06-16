# Build Note — Aperture Routing (the `ai` node / `http://ai/v1`)

> **Scope:** authoritative extraction of Tailscale Aperture's configuration model, so a later
> agent can author `nixos/ai.nix` (or decide it should not be a NixOS host at all) and the model-plane
> wiring WITHOUT re-reading the source. Architecture is **locked** — see
> [`hermes-home-server.md`](../hermes-home-server.md) §2, §4, §10. This note does not re-litigate.
>
> **Sources** (Tailscale Aperture docs, fetched 2026-06-15):
> [configuration](https://tailscale.com/docs/aperture/configuration),
> [self-hosted how-to](https://tailscale.com/docs/aperture/how-to/use-self-hosted),
> [provider-compatibility](https://tailscale.com/docs/aperture/provider-compatibility),
> [how-aperture-works](https://tailscale.com/docs/aperture/how-aperture-works),
> [get-started](https://tailscale.com/docs/aperture/get-started),
> [troubleshooting](https://tailscale.com/docs/aperture/troubleshooting),
> [use-openai-compatible-tools](https://tailscale.com/docs/aperture/how-to/use-openai-compatible-tools),
> [blog: aperture-private-alpha](https://tailscale.com/blog/aperture-private-alpha). Prior-art client
> config: [`openclaw.md`](../../../Documents/Blog/drafts/openclaw.md) lines 285–326.

---

## TL;DR — the load-bearing facts

1. **Aperture is a HOSTED Tailscale service, not a binary we run.** You sign up at
   `aperture.tailscale.com`; Tailscale provisions a gateway node on your tailnet (default MagicDNS
   hostname **`ai`**) and a dashboard at `http://<hostname>/ui`. There is no Aperture
   install/run command, no container we operate, no on-disk config file we manage.
2. **Config is JSON/HuJSON edited in the hosted dashboard Settings page** (Visual editor default,
   or JSON editor), applied via the dashboard / config API — **not** a file on a node we control,
   **not** a Tailscale ACL, **not** a CLI on our machines.
3. **Routing is by the `models` array on each provider entry.** Aperture extracts `model` from the
   request body, finds the provider whose `models` list contains it, and forwards there — injecting
   that provider's `apikey` as the configured `authorization` header.
4. **Per-upstream static key** = the provider's `apikey` field + `authorization` (`bearer` default).
5. **`/v1` path-doubling is the #1 pitfall**: clients send `POST /v1/chat/completions`; Aperture
   appends the full incoming path to `baseurl`. So for a self-hosted upstream, set `baseurl` to
   **host:port only** (no `/v1`).
6. **Client contract is confirmed:** OpenAI-wire base URL `http://ai/v1`, model ids
   `gpt-5.5` / `gemini-3.5` / `qwen-local`, api-key value `-` (any non-empty string; Aperture
   ignores client keys). hermes reaches it DIRECT via `NO_PROXY=ai`.
7. **Consequence for IaC:** because the gateway and its config are Tailscale-hosted, `nixos/ai.nix`
   as a *full NixOS host* has nothing to provision. The deliverable is a **rendered config artifact
   + a documented apply step**, not a NixOS machine. See [§5](#5-what-nixosainix-should-actually-contain).

---

## 1. Deployment model — where Aperture lives

**Hosted, not self-hosted.** Verbatim from [get-started]:

> "Visit `aperture.tailscale.com` and complete the sign-up form." … "Open the Aperture dashboard at
> `http://<aperture-hostname>/ui`."

From [troubleshooting]:

> "Replace `<hostname>` with your Aperture hostname (`ai` is the default, but it might be a custom
> name)." … "Aperture relies on MagicDNS to resolve its hostname. When MagicDNS is off, the hostname
> does not resolve, and connection attempts fail." … references "the Aperture device's IP address on
> the **Machines** of the admin console."

So the picture is:

- Sign-up at `aperture.tailscale.com` provisions a **gateway node on your tailnet**. Its default
  MagicDNS name is **`ai`** → `http://ai` resolves for every tailnet device with MagicDNS on.
- It shows up under **Machines** in the Tailscale admin console as a normal device (we don't build
  or boot it; Tailscale runs it).
- Config + usage dashboard live at `http://<hostname>/ui` (i.e. `http://ai/ui`).
- **No install/run commands exist in the docs** — Aperture is "managed entirely through the web
  interface, consistent with a hosted service model." The `aperture-private-alpha` blog confirms the
  credential "stays inside the gateway" (Tailscale-side), which is why no key lands on our boxes.

This is consistent with the locked decision §10 **"`ai`-node placement → Aperture stays on the
existing `ai` tailnet node"**: that node is the Tailscale-provisioned Aperture gateway, already on the
tailnet. We do **not** stand up our own `ai` VM.

> BLOCKER: the docs do **not** state whether the alpha lets you *rename* the gateway hostname to `ai`
> if it isn't already, nor whether multiple tailnets get the node automatically. The architecture
> assumes the hostname is `ai`. TODO(human): confirm in the live Aperture dashboard that the gateway's
> MagicDNS hostname is exactly `ai` (or set it), and that MagicDNS is enabled for the tailnet.

---

## 2. Config format, location, and how to apply it

**Format:** JSON / HuJSON (comments allowed). From [configuration]:

> "Admins can edit the configuration from the **Settings** page of the Aperture dashboard using the
> **Visual editor** (default) or the **JSON editor**."

**Location/apply:** the hosted dashboard Settings page (`http://ai/ui` → Settings → JSON editor). The
config fetch summarized an API shape `PUT http://<aperture-hostname>/api/config` for programmatic
apply.

> TODO(human): the exact config-API verb/path (`PUT /api/config`) was summarized by the fetch tool,
> not seen verbatim in the doc body. Before scripting an apply step, confirm the real endpoint (and
> auth) from `http://ai/ui` network calls or the dashboard's "JSON editor" export/import. Do NOT bake
> `PUT /api/config` into a script as fact until verified.

**Top-level config schema** (verbatim field set, from [configuration]):

```jsonc
{
  "providers": { /* map: provider-key -> provider object */ },
  "grants":   [ ... ],   // identity/ACL-style access grants (who can call what)
  "quotas":   { ... },   // spend/usage caps
  "hooks":    { ... },
  "exporters":{ ... },
  "database": { ... },
  "chat_models": [ ... ],
  "mcp":      { ... }
}
```

For Hermes only the `providers` map matters; `grants`/`quotas` are Tailscale-identity governance we
can leave at defaults (the tailnet ACLs already gate who reaches `ai`, per §7 "Dashboard" in the
architecture).

---

## 3. The provider object — fields that drive routing + key injection

Verbatim field set for each entry under `"providers"` (from [configuration]):

| Field | Required | Meaning |
|---|---|---|
| `baseurl` | **yes** | Upstream API root. Aperture **appends the full incoming request path** to this. |
| `models` | **yes** | Array of model-id strings. **This is the routing table** — a request's `model` is matched here. |
| `apikey` | no | Static key injected toward the upstream. Omit if the upstream needs no auth. |
| `authorization` | no | Header style for `apikey`: `"bearer"` (default), `"x-api-key"`, `"x-goog-api-key"`. |
| `compatibility` | no | Object of boolean wire-format flags (see [§4](#4-compatibility-flags-which-wire-formats-a-provider-exposes)). |
| `name` | no | Display name in dashboard. |
| `description` | no | Display string. |
| `preference` | no | Integer ordering hint. |
| `disabled` | no | Boolean kill-switch. |
| `add_headers` | no | Extra static headers to inject. |
| `cost_basis` / `model_cost_map` | no | Spend-ledger metadata. |

**Routing semantics** (verbatim, [how-aperture-works]):

> "When a request arrives, Aperture extracts the model name from the request body (for example,
> `claude-sonnet-4-6` or `gpt-5.5`). The proxy looks up which provider serves that model and forwards
> the request to that provider's API endpoint, injecting the correct authentication headers."

And ([configuration]):

> "Aperture does not verify model names in the provider configuration. Aperture sends names directly
> to the upstream provider as-is." (Wildcards like `"claude-opus*"` are allowed when the upstream
> supports them.)

So routing = **string membership of the request `model` in some provider's `models` array**, then the
incoming path is appended to that provider's `baseurl` and `apikey` is injected as `authorization`.

**The `/v1` path-doubling pitfall** (verbatim, [configuration]):

> "If `baseurl` includes `/v1`, the upstream URL contains `/v1/v1/...`, which causes HTTP 405 errors
> from the upstream provider. This is the most common provider setup mistake."

Therefore: clients send `POST /v1/chat/completions` → for any OpenAI-wire upstream, `baseurl` must be
**`http://host:port`** (no trailing `/v1`).

> Caveat: the self-hosted how-to's *example* showed `"baseurl": "http://100.64.0.1:8080/v1"` AND a
> note that "If your clients use the standard `/v1` base URL, set the self-hosted `baseurl` to just
> the host and port." These conflict on the surface. The reconciling rule: the trailing-`/v1` example
> is only correct for clients that send a *bare* path (no `/v1`). **Hermes sends `http://ai/v1/...`,
> so we MUST use host:port only.** TODO(human): verify against the real upstreams once reachable —
> first request to each upstream should hit `…:8317/v1/chat/completions`, not `…/v1/v1/...`.

---

## 4. Compatibility flags (which wire formats a provider exposes)

Full boolean set with defaults (verbatim, [provider-compatibility]):

| Flag | Default |
|---|---|
| `openai_chat` | `true` |
| `openai_responses` | `false` |
| `anthropic_messages` | `false` |
| `gemini_generate_content` | `false` |
| `google_generate_content` | `false` |
| `google_raw_predict` | `false` |
| `bedrock_model_invoke` | `false` |
| `bedrock_converse` | `false` |
| `experimental_gemini_cli_vertex_compat` | `false` |

Authorization values: `"bearer"` (default for self-hosted), `"x-api-key"`, `"x-goog-api-key"`.

**For Hermes, every upstream is consumed over the OpenAI `/v1/chat/completions` wire** (hermes talks
OpenAI-wire to `http://ai/v1`, and CLIProxyAPI re-exposes Codex/Gemini OpenAI-compatibly per §4 of the
architecture). So **`openai_chat: true`** (the default) is the only flag needed on all three. We do
NOT need `gemini_generate_content` / `anthropic_messages` here, because hermes is not speaking the
Gemini/Anthropic native wire to Aperture — it speaks OpenAI-wire and lets CLIProxyAPI front Gemini.

---

## 5. The concrete `providers` config Hermes needs

Mapping the locked §4 table (`gpt-5.5`→CLIProxyAPI :8317, `gemini-3.5`→CLIProxyAPI :8317,
`qwen-local`→host `mlx_lm.server` :8080) onto the verified schema:

```jsonc
{
  "providers": {
    "cliproxy": {
      "name": "CLIProxyAPI (Codex + Gemini OAuth → static key)",
      "baseurl": "http://<HOST_TAILNET_IP_OR_NAME>:8317",   // NO /v1 — clients send /v1/...
      "models": ["gpt-5.5", "gemini-3.5"],
      "apikey": "<CLIPROXY_STATIC_KEY>",                     // the static key CLIProxyAPI is configured to accept
      "authorization": "bearer",
      "compatibility": { "openai_chat": true }
    },
    "qwen-mlx": {
      "name": "Local Qwen (mlx_lm.server)",
      "baseurl": "http://<HOST_TAILNET_IP_OR_NAME>:8080",   // NO /v1
      "models": ["qwen-local"],
      // no apikey — mlx_lm.server needs none (self-hosted, §4)
      "compatibility": { "openai_chat": true }
    }
  }
}
```

Notes that pin this down:

- **`gpt-5.5` and `gemini-3.5` share one provider entry** (`cliproxy`) — they both route to
  CLIProxyAPI :8317; two ids in one `models` array. CLIProxyAPI internally maps the model id to the
  right OAuth account (Codex vs Gemini), so Aperture just forwards `model` as-is.
- **`<HOST_TAILNET_IP_OR_NAME>`**: the Aperture gateway is a Tailscale node and CLIProxyAPI/MLX run on
  the **host** Mac, also on the tailnet. From the gateway, the host is reachable by its MagicDNS name
  or its `100.64.0.0/10` tailnet IP. TODO(human): fill in the host's MagicDNS name (e.g.
  `host.<tailnet>.ts.net`) or tailnet IP. The self-hosted doc example used a `100.64.x.x` CGNAT IP.
- **`<CLIPROXY_STATIC_KEY>`**: the static bearer CLIProxyAPI accepts on its OpenAI-compatible
  endpoint. This is the only secret in this config. It must NOT be committed (Nix store is
  world-readable — §9 of the architecture). It is entered in the hosted Aperture dashboard, or
  injected at apply time. TODO(human): generate/record the CLIProxyAPI static key and set it in the
  Aperture dashboard (or via the verified config API). Do not place it in the flake.

> The provider *keys* (`"cliproxy"`, `"qwen-mlx"`) are arbitrary labels — routing is by `models`, not
> by key name. Chosen for clarity only.

---

## 6. What `nixos/ai.nix` should actually CONTAIN

**The `ai` node is NOT a NixOS host we build.** It is a Tailscale-managed Aperture gateway. A full
`nixos/ai.nix` machine definition would have nothing to install (no Aperture package exists publicly;
no service to run). Forcing it into the flake as a host is dead weight.

Recommended shape (a *rendered config artifact + documented apply step*, NOT a NixOS machine):

1. **`nixos/ai.nix` becomes a thin Nix module that renders the Aperture `providers` JSON**, not a
   `nixosSystem`. It exposes a derivation/file output (e.g. `aperture-providers.json`) built from Nix
   values (host name, ports, model ids) so the §4 catalog stays declarative — but with the secret
   `apikey` left as a placeholder (e.g. `"@CLIPROXY_STATIC_KEY@"`), substituted at apply time, never
   in the store.
   - Reuse the repo's existing PLACEHOLDER + sops pattern (§9): render with placeholders, fill from
     `sops-nix`/`agenix` or the `bootstrap` runtime prompt.
2. **A `just` recipe `apply-aperture`** that: (a) takes the rendered JSON, (b) substitutes the static
   key from the credential plane, (c) applies it to the dashboard. Until the config-API endpoint is
   verified (§2 TODO), the apply step is **manual/documented**: "paste the rendered JSON into the
   Aperture dashboard JSON editor at `http://ai/ui` → Settings."
3. **A documented one-time step** in the bootstrap docs: sign up at `aperture.tailscale.com`, confirm
   the gateway hostname is `ai`, enable MagicDNS.

Why a rendered-artifact-plus-apply-step (not a host): Aperture is proprietary alpha, hosted by
Tailscale, with no public binary, image, or NixOS module. The only thing we own is the *provider
configuration content*; everything else is Tailscale's. Generating that content from the flake keeps
it reproducible (`destroy-and-rebuild` re-renders identical JSON) while honoring that the gateway
itself is not ours to provision.

> TODO(human): pick the apply mechanism once §2's config API is verified — programmatic
> (`PUT`/import) vs documented manual paste. Until then, ship the rendered artifact + manual step.
> Do NOT invent an Aperture CLI or a `services.aperture` NixOS option — neither exists in the sources.

> DO-NOT-INVENT: every Aperture field name, value, and the routing semantics above are quoted from the
> live docs. Anything beyond them (the config-API verb, the exact host MagicDNS name, the rename-to-`ai`
> step) is marked TODO(human)/BLOCKER and must be verified, not guessed.

---

## 7. Client-side contract Hermes relies on (confirmed)

What the hermes VM and the architecture (§4) assume, cross-checked against the docs and prior art:

- **Base URL:** `http://ai/v1` for the OpenAI wire. Verbatim from [use-openai-compatible-tools]:
  `http://<aperture-hostname>/v1`, with a curl example posting `{"model":"gpt-5.5", ...}` to
  `http://<aperture-hostname>/v1/chat/completions`. The docs explicitly say **use `http://` (not
  `https://`)** — WireGuard already encrypts. ✓ Matches `base_url: http://ai/v1` in hermes
  `config.yaml` (architecture §4).
- **Model ids:** `gpt-5.5`, `gemini-3.5`, `qwen-local` — the strings hermes sends as `model`; they
  must appear in the providers' `models` arrays (§5). ✓
- **API key value:** any non-empty string; Aperture ignores client-provided keys
  ([use-openai-compatible-tools]: "Leave empty or set to any value (Aperture ignores client-provided
  keys and injects credentials automatically)"). The prior-art `openclaw.md` uses **`"apiKey": "-"`**
  with the note "the API key field just has to be non-empty for the client library to not complain"
  ([`openclaw.md`](../../../Documents/Blog/drafts/openclaw.md) line 326). ✓ Use `-`.
- **DIRECT, not proxied:** hermes sets `NO_PROXY=ai,.ts.net,localhost,127.0.0.1` so `http://ai` skips
  the `vault` MITM proxy (architecture §5, line 227). The Aperture gateway holds the static keys
  Tailscale-side; nothing else should intercept that hop. ✓
- **Failover is hermes's job, not Aperture's.** Aperture only routes by id; hermes's
  `fallback_providers` chain (`gpt-5.5` → `gemini-3.5` → `qwen-local`) does the hopping, each entry
  pointing at the same `base_url: http://ai/v1` (architecture §4, lines 161–171). ✓ Aperture's
  `preference` field is NOT used for failover.

**Prior-art divergence to note (do not carry over):** `openclaw.md` registered Aperture as *three*
client-side providers split by wire format (`anthropic-messages` → `http://ai`, `openai-completions`
→ `http://ai/v1`, `google-generative-ai` → `http://ai/v1beta`) because that experiment used
Anthropic/OpenAI/Google native models. **Hermes does NOT do this** — it speaks one wire (OpenAI) to
one base URL (`http://ai/v1`) for all three ids, and CLIProxyAPI fronts the Gemini OAuth. The
multi-wire split is prior-experiment context, not the Hermes contract.

---

## 8. Smoke test (gates the model plane)

From architecture §13, now grounded in the verified wire:

```bash
# model plane + Aperture routing (run from the hermes VM or any tailnet node)
curl http://ai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer -" \
  -d '{"model":"gpt-5.5","messages":[{"role":"user","content":"ping"}]}'

# repeat with "gemini-3.5" (→ same CLIProxyAPI provider) and "qwen-local" (→ MLX) to prove routing.
# Expect a normal OpenAI chat-completion JSON; an HTTP 405 means /v1 path-doubling (fix baseurl).
```

`hermes` then exercises failover by killing the `gpt-5.5` upstream and confirming it hops to
`gemini-3.5` then `qwen-local` (hermes-side, not Aperture).
