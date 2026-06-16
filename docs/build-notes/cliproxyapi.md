# CLIProxyAPI — Build Notes (authoritative extraction)

> Source of truth for the host-side **OAuth → static-key** proxy that re-exposes Codex
> (gpt-5.5) and Gemini-personal (gemini-3.5) OpenAI-compatibly behind Aperture.
> All facts extracted from a depth-1 clone of
> <https://github.com/router-for-me/CLIProxyAPI>.

## Pin

- **Repo:** `https://github.com/router-for-me/CLIProxyAPI`
- **HEAD commit (pin this):** `bbef8da454c88ad09d6e589f7ddce5ed2eeddb51`
  (2026-06-15, `feat(videos): add video authentication binding and update handler behavior`)
- **Go module path:** `github.com/router-for-me/CLIProxyAPI/v7` (note the `/v7`), `go 1.26.0`
  (`go.mod:1,3`).
- **License:** MIT.
- **Binary name:** `cli-proxy-api` (built via `go build -o cli-proxy-api ./cmd/server`,
  `AGENTS.md:11`). The Docker image instead names it `CLIProxyAPI` (`Dockerfile`).
  The Hermes architecture doc calls it `cli-proxy-api` in its CLI examples — that is the
  correct OSS-build name.

---

## 1. Config file: format, location, schema

### Location / discovery (`cmd/server/main.go:461-472`, `AGENTS.md:20`)

- Default config file is **`config.yaml`** resolved against the **current working
  directory** (`filepath.Join(wd, "config.yaml")`, `main.go:470`). There is **no**
  `~/.config` lookup for the config file itself.
- Override with **`--config <path>`** (alias `-config`; also `-config=<path>`).
- Template shipped in-repo: **`config.example.yaml`** (22 KB, fully commented).
- `.env` is auto-loaded from the working directory (`main.go:185`,
  `godotenv.Load(filepath.Join(wd, ".env"))`) — but env vars are only needed for the
  optional Postgres/git/object remote token stores. **For our local file-backed setup,
  no env vars are required.**

### Top-level schema (real keys, from `config.example.yaml`)

```yaml
# Bind interface. "" = all interfaces (IPv4+IPv6). "127.0.0.1"/"localhost" = local only.
host: ""
# Listen port — THE port Aperture targets.
port: 8317

tls:
  enable: false
  cert: ""
  key: ""

# Authentication directory (supports ~). THIS is where OAuth tokens are persisted.
auth-dir: "~/.cli-proxy-api"

# Static client keys (our @@APERTURE_STATIC_KEY@@). Plaintext list.
api-keys:
  - "your-api-key-1"
  - "your-api-key-2"

debug: false

# Management API (separate from the proxy API; key-gated). Leave empty to disable entirely.
remote-management:
  allow-remote: false
  secret-key: ""            # hashed on startup; required for ALL /v0/management routes even from localhost
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

request-retry: 3            # retries on upstream 403/408/500/502/503/504
proxy-url: ""               # optional outbound socks5/http/https proxy for upstream calls

routing:
  strategy: "round-robin"   # round-robin (default) | fill-first
  session-affinity: false
  session-affinity-ttl: "1h"
```

### `api-keys` — the static keys clients present (our `@@APERTURE_STATIC_KEY@@`)

- Field is the top-level YAML list **`api-keys`** (`config.example.yaml:39-42`;
  SDK struct tag `yaml:"api-keys,omitempty"` at `sdk/access/types.go:21`).
- These are **arbitrary plaintext strings** (no `sk-` prefix required) compared by exact
  match. Whitespace is trimmed and duplicates de-duped on load
  (`internal/access/config_access/provider.go:120-141`).
- **If `api-keys` is empty/absent, the config-API-key access provider is unregistered**
  (`provider.go:19-23`) — i.e. inbound requests are NOT key-gated by this provider. For
  our deployment we MUST set at least one key so Aperture's injected key is required.
- **SAFETY GUARD:** if any key still equals an example value (`your-api-key-1` etc.), the
  server refuses to start the proxy and instead launches a *warning-only* server
  (`main.go:536-541`, `safemode.HasExampleAPIKeys`). So the placeholder
  `@@APERTURE_STATIC_KEY@@` must be substituted with a real value before launch.

### How a client presents the static key (`provider.go:55-104`)

The proxy accepts the key in **any** of these locations (first match wins):
1. `Authorization: Bearer <key>` (the `bearer` prefix is stripped case-insensitively; a
   bare value with no `bearer ` prefix is also accepted as the whole key —
   `extractBearerToken`, `provider.go:106-118`).
2. `X-Goog-Api-Key: <key>` (Gemini-style).
3. `X-Api-Key: <key>` (Anthropic-style).
4. `?key=<key>` query param.
5. `?auth_token=<key>` query param.

→ **Aperture should inject `Authorization: Bearer @@APERTURE_STATIC_KEY@@`** on requests it
forwards to `http://<host>:8317`. That is the standard OpenAI-wire shape and matches
candidate #1.

---

## 2. `--codex-login` and `--gemini-login` OAuth flows + token storage

> NOTE: the flag for Gemini/Google is **`--login`**, *not* `--gemini-login`. The Hermes
> architecture doc (`hermes-home-server.md:182`) writes `cli-proxy-api --gemini-login`,
> which is **wrong** — there is no such flag. Use **`cli-proxy-api --login`** for Gemini.
> BLOCKER(doc): correct `--gemini-login` → `--login` in `hermes-home-server.md` before
> scripting the one-time logins.

CLI flags (`cmd/server/main.go:94-112`):

| Flag | Effect |
|---|---|
| `--login` | Google/Gemini OAuth (interactive). `cmd.DoLogin` (`main.go:571-573`). |
| `--codex-login` | Codex (ChatGPT) OAuth via local-callback browser flow. `cmd.DoCodexLogin` (`main.go:577-579`). |
| `--codex-device-login` | Codex device-code flow (no local callback; for headless). `main.go:580-582`. |
| `--claude-login` | Claude OAuth (not used by us). |
| `--no-browser` | Don't auto-open the browser (prints URL instead). |
| `--oauth-callback-port <port>` | Override the local callback port (else provider default). |
| `--project_id <id>` | Gemini only; preselect a GCP project (else interactive picker). |

### Codex (`--codex-login`) — `internal/auth/codex/`

- OAuth2 **auth-code + PKCE** against OpenAI:
  - `AuthURL = "https://auth.openai.com/oauth/authorize"` (`openai_auth.go:25`)
  - `TokenURL = "https://auth.openai.com/oauth/token"` (`openai_auth.go:26`)
  - `ClientID = "app_EMoamEEZ73f0CkXaXp7hrann"` (`openai_auth.go:27`)
  - `scope = "openid email profile offline_access"` (`openai_auth.go:75`)
- Local callback server: **`RedirectURI = "http://localhost:1455/auth/callback"`**
  (`openai_auth.go:28`; handler `mux.HandleFunc("/auth/callback", ...)` at
  `oauth_server.go:83`). → **Callback port `1455`** unless `--oauth-callback-port` overrides.
- Stored token JSON (`internal/auth/codex/token.go:18-38`, struct `CodexTokenStorage`):
  `id_token` (JWT), `access_token`, `refresh_token`, `account_id`, `last_refresh`,
  `email`, `type`, `expired`. The `account_id` here is the JWT-derived
  `ChatGPT-Account-Id` the architecture doc references.
- Token filename (`internal/auth/codex/filename.go`):
  `codex-<email>.json`, or `codex-<email>-<plan>.json` when a plan type is present
  (e.g. `codex-you@example.com-plus.json`), or `codex-<hashAccountID>-<email>-team.json`
  for team plans.

### Gemini (`--login`) — `internal/auth/gemini/` + `internal/cmd/login.go`

- OAuth2 against Google; local callback:
  **`callbackURL = "http://localhost:%d/oauth2callback"` with `DefaultCallbackPort = 8085`**
  (`gemini_auth.go:33,79,211`). → **Callback port `8085`** unless overridden.
- After OAuth, performs the **Code Assist handshake** (`loadCodeAssist` then
  `onboardUser` against `https://cloudcode-pa.googleapis.com/v1internal`,
  `login.go:31-32,209-356`) and resolves/activates a GCP project. Interactive menu offers:
  **(1) Code Assist** (GCP project, manual selection) or
  **(2) Google One** (personal account, auto-discover project) — `login.go:105-112`.
  For **personal Gmail (free Code Assist)** pick the Google One / auto-discover path or
  let `onboardUser` auto-provision a project.
- Stored token JSON includes `project_id`, `email`, etc.
  (`gemini_token.go:24-28`, `GeminiTokenStorage`).
- Token filename (`gemini_token.go:89-104`): `gemini-<email>-<project>.json`, or
  `gemini-<email>-all.json` when multiple/ALL projects selected.

### Where tokens are stored + how they're re-exposed

- All OAuth credential JSON files land under **`auth-dir`** (default `~/.cli-proxy-api`,
  resolved via `util.ResolveAuthDir`, `main.go:519-524`). The in-repo `auths/` dir
  (with `.gitkeep`) is the Docker-mount default (`docker-compose.yml` maps
  `./auths:/root/.cli-proxy-api`).
- The running server **auto-refreshes** these OAuth tokens (refresh-token rotation
  handled internally; worker pool default 16, `config.example.yaml:136-138`) and serves
  the upstream models OpenAI-compatibly on `:8317`. There is a config hot-reload watcher
  (`internal/watcher/`) so adding/removing auth files does not require a restart.
- **BACK UP `auth-dir`** and alert on `invalid_grant` (architecture doc §11) — these refresh
  tokens are single-use/rotating and CLIProxyAPI must be the *only* holder.

---

## 3. OpenAI-compatible endpoints + model→account mapping

### Endpoints served (Gin routes, `internal/api/server.go:429-486`)

OpenAI-compatible group `/v1`:

| Method | Path | Handler |
|---|---|---|
| GET  | `/v1/models` | unified models list (OpenAI + Claude shapes) |
| POST | `/v1/chat/completions` | **primary OpenAI chat endpoint** |
| POST | `/v1/completions` | legacy completions |
| POST | `/v1/images/generations` | image gen |
| POST | `/v1/images/edits` | image edits |
| POST | `/v1/responses` | OpenAI Responses API (Codex native wire) |
| GET  | `/v1/responses` | Responses websocket |
| POST | `/v1/messages` | Anthropic-style messages |
| POST | `/v1/videos`, `/v1/videos/generations`, … | xAI video |

Also: `/openai/v1/...` (videos), `/backend-api/codex/responses` (Codex-direct),
`/v1beta/models/...` (Gemini-native wire), `/v1internal:method` (Gemini CLI; gated by
`enable-gemini-cli-endpoint`, default false), and `/v0/management/...` (management API,
key-gated).

→ **For Aperture we point both `gpt-5.5` and `gemini-3.5` upstreams at
`http://<host>:8317/v1/chat/completions`** (OpenAI chat wire). Both Codex and Gemini OAuth
accounts are reachable through the unified `/v1/chat/completions` endpoint.

### Model → Codex-vs-Gemini routing — NO manual mapping needed

- The proxy maintains a **global model registry** (`internal/registry/`,
  `sdk/cliproxy/model_registry.go`). Each logged-in OAuth account contributes the models
  it owns; Codex contributes the `gpt-*` family and Gemini-CLI contributes the `gemini-*`
  family (see `internal/registry/models/models.json`, which lists e.g. `gemini-2.5-pro`,
  `gemini-3-pro-preview`, `gemini-3.5-flash`, etc.).
- A client request's **`model` field selects the owning provider automatically**; among
  multiple credentials owning the same model, an auth scheduler picks one
  (`routing.strategy: round-robin` default, `sdk/cliproxy/auth/scheduler.go`). **We do not
  configure a model→account table** — we simply request `gpt-5.5` (→ Codex auth) or
  `gemini-3.5` (→ Gemini auth) and the proxy routes by registry ownership.
- TODO(human): confirm the exact upstream model ids the *current* Codex/Gemini accounts
  expose once logged in — `models.json` in this pin lists `gemini-3.5-flash` and `gpt-5*`
  families but the literal ids `gpt-5.5` / `gemini-3.5` are architecture-doc placeholders;
  hit `GET http://<host>:8317/v1/models` after login to read the real ids, then either use
  those ids directly in Aperture or define `oauth-model-alias` (below) to rename them.
- **Optional renaming** if the upstream id differs from `gpt-5.5`/`gemini-3.5`: the
  `oauth-model-alias` block (`config.example.yaml:334-371`) maps per-channel
  (`codex:`, `gemini-cli:`, …) `name → alias`. Example:
  ```yaml
  oauth-model-alias:
    codex:
      - name: "gpt-5"          # real upstream id from /v1/models
        alias: "gpt-5.5"       # the id Aperture/hermes requests
    gemini-cli:
      - name: "gemini-3.5-flash"
        alias: "gemini-3.5"
  ```
  Aliases affect both `/v1/models` listing and request routing.

---

## 4. Running as a long-lived macOS service + packaging

### Invocation

- Server (default, no flag) just runs the proxy:
  `cli-proxy-api --config /path/to/config.yaml` (with cwd containing the config, or pass
  `--config`). It blocks in the foreground serving on `host:port`.
- Logins are **separate one-shot invocations** that exit after saving the token:
  ```bash
  cli-proxy-api --config <cfg> --codex-login    # ChatGPT subscription account, callback :1455
  cli-proxy-api --config <cfg> --login          # personal Gmail (free Code Assist), callback :8085
  ```
  These open a browser (suppress with `--no-browser`). Run them **on the host** during
  bootstrap (architecture doc §9: "one-time interactive sign-ins").

### launchd / nix-darwin service shape (facts to encode)

- One foreground process, restart-always. Set `KeepAlive=true`, `RunAtLoad=true`.
- The process needs a **working directory** that contains `config.yaml` **or** an absolute
  `--config`; prefer the latter for launchd (no `~`, full paths — matches the repo's
  `openclaw.md` prior art). Set `WorkingDirectory` so relative `auth-dir`/`logs` resolve
  predictably, or set absolute `auth-dir` in config.
- Bind: set `host: ""` (all interfaces) so the VM-side Aperture node can reach it over the
  LAN/tailnet, **or** bind a specific interface and rely on Tailscale ACLs. `port: 8317`.
- `auth-dir`: use an absolute path under the service user's home, e.g.
  `auth-dir: "/Users/<user>/.cli-proxy-api"`, and back it up.

### Nix packaging

- **No Nix packaging exists in the repo** (no `flake.nix`, no nixpkgs reference). Two options:
  1. **`buildGoModule`** from the pinned commit. `go 1.26.0`, module
     `github.com/router-for-me/CLIProxyAPI/v7`, build target `./cmd/server`,
     output binary `cli-proxy-api`. **`CGO_ENABLED=1` is required** (Dockerfile and the
     release workflow both build with `CGO_ENABLED=1` — pure-Go SQLite / cgo deps), so the
     `buildGoModule` derivation must enable cgo (`CGO_ENABLED = "1"`, ensure a C compiler
     in `nativeBuildInputs`). Inject version via
     `-ldflags "-X main.Version=… -X main.Commit=… -X main.BuildDate=…"`.
     TODO(human): supply `vendorHash` for the pinned commit (run
     `nix build` once and copy the reported hash, or `nix-prefetch`).
  2. **Fetch the release binary.** Release assets are named
     **`CLIProxyAPI_<version>_darwin_aarch64.tar.gz`** for Apple Silicon
     (release workflow matrix `darwin-arm64 → asset_arch: aarch64`, archive `tar.gz`,
     binary inside named `cli-proxy-api`). Wrap in `pkgs.fetchurl` +
     `installPhase` that drops `cli-proxy-api` into `$out/bin`.
  - **Recommendation:** `buildGoModule` for determinism (the locked Nix posture), falling
    back to the prebuilt `darwin_aarch64` tarball if cgo packaging is fiddly.

---

## 5. Aperture → CLIProxyAPI wiring (the static-key boundary)

- Aperture's upstreams `gpt-5.5` and `gemini-3.5` both point at
  **`http://<host>:8317/v1`** (OpenAI-compatible base URL; `/v1/chat/completions` is the
  chat route).
- Aperture must **inject the static key** on each forwarded request:
  `Authorization: Bearer @@APERTURE_STATIC_KEY@@`, where `@@APERTURE_STATIC_KEY@@` is one
  of the strings in CLIProxyAPI's `api-keys` list. (Any of the 5 credential locations in
  §1 works; Bearer is the natural one.)
- `host` reachability: set CLIProxyAPI `host: ""` to bind all interfaces so the separate
  `ai` tailnet node can reach the host's `:8317`. Per the architecture doc, `http://ai`
  stays in hermes's `NO_PROXY` (direct, not via the vault MITM proxy), and Tailscale ACLs
  gate access.
- This is consistent with the architecture's **OAuth-in / static-key-out** boundary:
  refresh tokens live only in CLIProxyAPI's `auth-dir`; downstream sees only the static key.

---

## Quick reference (load-bearing constants)

| Fact | Value |
|---|---|
| Listen port | `8317` (config key `port`) |
| Static-key field | `api-keys:` (top-level YAML list) |
| Auth/token dir | `auth-dir`, default `~/.cli-proxy-api` |
| Config file | `config.yaml` (cwd) or `--config <path>`; template `config.example.yaml` |
| Codex login flag | `--codex-login` (callback `http://localhost:1455/auth/callback`) |
| Gemini login flag | `--login` (NOT `--gemini-login`; callback `http://localhost:8085/oauth2callback`) |
| Primary endpoint | `POST /v1/chat/completions` |
| Models endpoint | `GET /v1/models` (read real upstream ids here) |
| Model→account routing | automatic by registry ownership; optional `oauth-model-alias` rename |
| Binary name | `cli-proxy-api` (OSS build); `CGO_ENABLED=1` required |
| HEAD pin | `bbef8da454c88ad09d6e589f7ddce5ed2eeddb51` |
| darwin/arm64 release asset | `CLIProxyAPI_<version>_darwin_aarch64.tar.gz` |
