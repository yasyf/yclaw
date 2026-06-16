# Build Notes: Agent Vault (Infisical credential proxy)

Authoritative extraction from the upstream source so Nix/scripts can be authored
without re-reading it. All facts below are quoted/derived from the pinned commit.

**Source pin (research preview):** `github.com/Infisical/agent-vault` @
`30ff25ce8f3c8cfd855e4e2d3e7713bb0b007eed` (branch `main`, HEAD message
`fix(broker): resolve dynamic secrets through the MITM proxy (#269)`).
The README footer states: *"Preview. Agent Vault is in active development and the
API is subject to change."* PIN THIS COMMIT — do not float `latest`.

---

## 1. Binary, invocation, configuration, and NixOS build

### Language / module
- **Go**, `module github.com/Infisical/agent-vault`, `go 1.25.0` (go.mod:1-3).
  Docker builder uses `golang:1.26.4-alpine` (Dockerfile:11). Build is
  `CGO_ENABLED=0 go build` (Dockerfile:22) — pure-Go (SQLite is `modernc.org/sqlite`,
  go.mod:17, a cgo-free SQLite, so `CGO_ENABLED=0` works).
- **Binary name:** `agent-vault` (`.goreleaser.yml` line 10: `binary: agent-vault`;
  Dockerfile:26 `-o /agent-vault`; installed to `/usr/local/bin/agent-vault`).
- Frontend (web/, Vite/React) is built first and **embedded** into the Go binary at
  `internal/server/webdist` (Dockerfile:21). For a headless server you still need the
  embedded webdist to exist at build time, OR the Go embed will fail. See PITFALL below.

### NixOS build approach
- **`buildGoModule`** is the right fitter: pure Go, standard `go.mod`/`go.sum`.
  - `src` = this repo at the pinned commit.
  - `vendorHash` = TODO(human): compute via `nix build` once and paste the
    `got: sha256-…` (go.sum is committed so the module graph is fixed).
  - Build needs the embedded frontend dir present. The Go embed directive lives under
    `internal/server`. TODO(human): VERIFY whether `internal/server/webdist` is checked
    in or `//go:embed` will fail without an `npm run build` preStep. If it fails, add a
    `preBuild` that creates `internal/server/webdist` (a stub `index.html` is enough for
    a headless API+proxy deployment) OR run the Vite build (`web/`, needs node) and copy
    it in — mirror Dockerfile stages 1 + line 21.
  - ldflags injected for version stamping (optional): `-X .../cmd.version`,
    `-X .../cmd.commit`, `-X .../cmd.date` (Dockerfile:23-25). Not required to run.

### Invocation (cobra CLI; one binary = server + client)
- **Server:** `agent-vault server` (cmd/server.go:74). Key flags (cmd/server.go:665-673):
  - `-p, --port` int — default `14321` (also honors `PORT` env). (`DefaultPort = 14321`, defaults.go:9)
  - `--host` string — default `127.0.0.1` (`DefaultHost`, defaults.go:10). **Use `0.0.0.0` to bind for the VM.** (Docker CMD does exactly this: `server --host 0.0.0.0 --port 14321`, Dockerfile:48.)
  - `--mitm-port` int — default `14322` (`DefaultMITMPort = 14322`, defaults.go:12). `0` disables the proxy.
  - `-d, --detach` — fork to background (writes `~/.agent-vault/server.log`, server.go:626-632). **For a systemd unit run FOREGROUND (omit `-d`)** and let systemd supervise.
  - `--password-stdin` — read master password from stdin (single attempt, no retry).
  - `--log-level` info|debug (debug = one line per proxied request, no secret values).
  - `--max-response-bytes` (default 0 = unlimited), `--max-request-bytes` (default 1 GiB).
- `agent-vault server stop` (cmd/server.go:636) — stops via pidfile.
- **CA fetch (client):** `agent-vault ca fetch` (cmd/ca.go:54) — GETs `/v1/mitm/ca.pem` from the server; `-o <file>` writes PEM. No auth required.
- **Service rules (admin/client):** `agent-vault vault service ...` (cmd/service.go) — see §2.
- **Credentials:** `agent-vault credential set KEY=VALUE ...` (cmd/credential.go) — see §5.
- **Agent-side wrapper:** `agent-vault run -- <cmd>` (cmd/run.go) bootstraps `HTTPS_PROXY`/CA env for a child process. We likely will NOT use this on the Hermes VM (we set env ourselves), but it documents the exact env contract — see §4.

### There is NO single config file
Agent Vault is **state-in-SQLite**, not a config file. There is **no YAML/TOML/JSON
config file the server reads at boot.** Configuration is:
- **env vars** (process-level: ports, master password, network policy, SMTP, Infisical store, rate limits) — full catalog in `.env.example` (reproduced in §5).
- **runtime state** stored encrypted in SQLite at the default DB path (under `~/.agent-vault/`, resolved by `store.DefaultDBPath()`; `HOME=/data` in Docker → `/data/.agent-vault`). Vaults, credentials, service rules, OAuth configs, agents/tokens all live here.
- **Service rules CAN be expressed as YAML** and pushed via the CLI/API (`agent-vault vault service set -f services.yaml`), but the server stores them as JSON in SQLite; the YAML is a client-side convenience (cmd/service.go:363-385). The YAML schema is the `broker.Config` struct — see §2.

> Operational implication for Nix: the unit just needs the binary + env +
> a writable `$HOME/.agent-vault` (or `--mitm-port`/`--port` flags). Seeding
> vaults/credentials/services/OAuth is a **post-start provisioning step** done
> via the CLI or HTTP API against `http://127.0.0.1:14321`, NOT a declarative file.

---

## 2. Service-rules schema (static-key injection + substitution)

The canonical type is `broker.Service` (internal/broker/broker.go:30-38). YAML uses the
**split** form (`host` + `path` + `port`); JSON/API uses an **inline** form where `host`
carries `host[:port]/path` joined (MarshalJSON, broker.go:53-60). The CLI's
`-f services.yaml` reads the YAML/split form.

### YAML shape (what we author and push)
```yaml
vault: hermes               # broker.Config.Vault (yaml:"vault")
services:
  - name: openai            # slug: 3-64 lowercase [a-z0-9-], no leading/trailing/double hyphen
    host: api.openai.com    # bare host, *.one-level-wildcard, or inline host:port/path
    path: ""                # optional glob; "" = catch-all. '*' greedy across '/'. no '**'
    # port: 443             # optional *int; nil matches any port
    # enabled: true         # optional *bool; nil = enabled (legacy-safe)
    auth:
      type: bearer          # bearer | basic | api-key | custom | passthrough
      token: OPENAI_API_KEY # credential KEY (UPPER_SNAKE_CASE), NOT the secret value
    substitutions: []       # optional; see below
```

### Auth block (internal/broker/broker.go:85-102) — exact field names per type
- `type: bearer` → field **`token`** = credential key. Injects header **`Authorization: Bearer <value>`** (broker.go:297-302). Set, not Add, so it wins over client-supplied dupes.
- `type: api-key` → field **`key`** = credential key; optional **`header`** (default `"Authorization"`), optional **`prefix`**. Injects `<header>: <prefix><value>` (broker.go:319-328).
- `type: basic` → **`username`** (required), **`password`** (optional) = credential keys. Injects `Authorization: Basic base64(user:pass)` (broker.go:304-317).
- `type: custom` → **`headers`** map: header-name → template string with `{{ CREDENTIAL_KEY }}` placeholders (regex `\{\{\s*(\w+)\s*\}\}`, broker.go:507). Each `{{ KEY }}` is resolved to the decrypted credential. Header names limited to `[a-zA-Z0-9-]+`.
- `type: passthrough` → no credential lookup, no injection; host is allowlisted and client headers flow through (minus broker headers + hop-by-hop). Used WITH `substitutions` (the tutorial's recommended GitHub pattern).

> Credential KEY names must match `^[A-Z][A-Z0-9_]*$` (UPPER_SNAKE_CASE),
> `broker.CredentialKeyPattern` (broker.go:108). The key is a *reference*; the
> real secret is stored separately (§5) and decrypted at request time.

### Substitutions (placeholder rewrite) — `broker.Substitution` (broker.go:65-69)
```yaml
    substitutions:
      - key: GITHUB_TOKEN          # credential key (UPPER_SNAKE_CASE)
        placeholder: __github_token__   # the literal string the agent sends as a dummy
        in: [header]               # surfaces to scan; SECURITY BOUNDARY
```
- Surfaces (`SubstitutionSurfaces`, broker.go:112): `path`, `query`, `header`, `body`, `websocket`.
- **Default when `in` omitted** (`DefaultSubstitutionSurfaces`, broker.go:117): `[path, query]`. **`header` is a deliberate opt-in** (CRLF guard) — you MUST list `header` explicitly to rewrite headers (broker.go:114-117). Body sub is content-type-aware (json-escape / form-urlencode / raw; multipart skipped — substitution.go:140-149).
- Placeholder validator (broker.go:420-450): ≥4 chars, only RFC-3986 unreserved `[A-Za-z0-9_-.~]`, ≥1 alphanumeric, and a delimiter (either `__` or a non-word char) so bare words can't match. The `__name__` convention satisfies all of these.

### Matching precedence (broker.MatchService, broker.go:547-583)
1. exact host beats `*.x.y` wildcard (even if wildcard has longer path);
2. port-specific beats port-nil within a host tier;
3. longest literal path prefix wins;
4. earlier declaration order breaks ties.
Wildcard `*.` matches **exactly one** subdomain level (`*.googleapis.com` matches
`api.googleapis.com` and `storage.googleapis.com` but NOT `a.b.googleapis.com` nor bare
`googleapis.com`) — broker.go:586-605. Host validation REJECTS IPs and `*.com`-style
single-level wildcards (broker.go:866-916).

### Unmatched-host policy (brokercore/credential.go:24-31)
Vault-level setting `unmatched_host_policy`: `passthrough` (system default — forward as
plain proxy) or `deny` (403). README:39 confirms `unmatched_host_policy=deny` is the
opt-in strict mode. **For Hermes we want `deny`** (only declared hosts get out).

### CLI to push rules (cmd/service.go)
- `agent-vault vault service set -f services.yaml` → **replace-all** (PUT `/v1/vaults/{vault}/services`).
- `agent-vault vault service add -f services.yaml` → **upsert by name** (POST). Also flag-driven: `--name --host --auth-type bearer --token-key OPENAI_API_KEY`.
- `agent-vault vault service add --name openai --host api.openai.com --auth-type bearer --token-key OPENAI_API_KEY` (flag form, service.go:158).
- `--vault` selects the vault (helper `resolveVault`).

### Mapping our required hosts
The built-in catalog (internal/catalog/catalog.go) HAS `openai`(api.openai.com, bearer,
`OPENAI_API_KEY`) and `github`(api.github.com, bearer, `GITHUB_TOKEN`). It does **NOT**
contain `api.exa.ai`, `api.honcho.dev`, or `*.googleapis.com` — those are custom rules
we author. Concrete `services.yaml` for our needs:

```yaml
vault: hermes
services:
  - name: openai
    host: api.openai.com
    auth: { type: bearer, token: OPENAI_API_KEY }
  - name: exa
    host: api.exa.ai
    auth: { type: bearer, token: EXA_API_KEY }       # TODO(human): VERIFY Exa uses Bearer (some Exa APIs use x-api-key header). If x-api-key: use type: api-key, key: EXA_API_KEY, header: x-api-key.
  - name: honcho
    host: api.honcho.dev
    auth: { type: bearer, token: HONCHO_API_KEY }    # TODO(human): VERIFY Honcho auth header shape.
  - name: github
    host: api.github.com
    auth: { type: bearer, token: GITHUB_TOKEN }
  - name: googleapis
    host: "*.googleapis.com"
    auth: { type: bearer, token: GOOGLE_OAUTH_TOKEN }  # oauth-type credential, auto-refreshed (see §3)
```

> The "overwrites a dummy bearer" behavior: injected auth headers use **Set** (not Add),
> so even if the Hermes client sends `Authorization: Bearer dummy`, the broker replaces it
> with the real/refreshed token (brokercore InjectResult.Headers comment, credential.go:38-39).

---

## 3. OAuth module — Google provider, connect/callback, auto-refresh binding

There is **no static OAuth "provider catalog"** in the source. OAuth is configured
**per-credential** (per `vault` + `key`) via an HTTP connect flow; you supply the
provider's URLs/client-id/secret/scopes in the request body. The refreshed access token
is then bound to a service rule by **using the same credential key as a `bearer` token**.

### Connect endpoint
`POST /v1/credentials/oauth/connect` (server.go:780 → handleOAuthConnect, handle_oauth.go:39).
Auth: requires an authenticated owner/member session. Request body
(`oauthConnectRequest`, handle_oauth.go:26-37):
```json
{
  "vault": "hermes",
  "key": "GOOGLE_OAUTH_TOKEN",
  "authorization_url": "https://accounts.google.com/o/oauth2/v2/auth",
  "token_url": "https://oauth2.googleapis.com/token",
  "client_id": "<google-client-id>",
  "client_secret": "<google-client-secret>",
  "scopes": "https://www.googleapis.com/auth/cloud-platform ...",
  "scope_separator": " ",
  "disable_pkce": false,
  "token_auth_method": "client_secret_post"
}
```
- Required: `key`, `authorization_url`, `token_url`, `client_id` (handle_oauth.go:48-75).
- `key` must be SCREAMING_SNAKE_CASE (handle_oauth.go:52-55).
- `scope_separator` defaults to `" "` (space); `token_auth_method` defaults to
  `client_secret_post` (alt: `client_secret_basic`) (handle_oauth.go:111-118).
- PKCE S256 is on by default; `disable_pkce` opts out (handle_oauth.go:137-143).
- Server stores the config in SQLite (`SetCredentialOAuth`) and returns
  `{"authorization_url": "<built-auth-url-with-redirect+state+challenge>"}`. The operator
  opens that URL in a browser to consent.
- **Redirect URI is fixed**: `s.baseURL + "/v1/oauth/callback"` (handle_oauth.go:163).
  `baseURL` = `AGENT_VAULT_ADDR` env, else `http://{host}:{port}` (cmd/server.go:56-66).
  TODO(human): the Google client's **Authorized redirect URI** must EXACTLY equal
  `<AGENT_VAULT_ADDR>/v1/oauth/callback`. Set `AGENT_VAULT_ADDR` to the vault VM's
  reachable URL and register that exact callback in the Google Cloud console.

### Callback endpoint
`GET /v1/oauth/callback` (server.go:781 → handleOAuthCallback, handle_oauth.go:172).
Validates `state` (sha256-hashed, 10-min TTL — `oauthStateTTL`), exchanges `code` for
tokens (`oauth.Exchange`, RFC 6749 §4.1.3), encrypts access+refresh tokens with the master
DEK, stores `token_expires_at`, then redirects the browser to `/oauth/complete`.

### Manual token upload (no browser flow)
`POST /v1/credentials/oauth/tokens` (server.go:783 → handleOAuthTokenUpload,
handle_oauth.go:331). Accepts `{vault, key, access_token, refresh_token, token_url,
client_id, client_secret, token_auth_method}`. A new refresh_token is **validated by
refreshing immediately** (handle_oauth.go:402-413). This is the headless path if browser
consent is awkward on the VM — TODO(human): decide browser-consent vs. token-upload for
the Google credential.

### How the refreshed token binds to `*.googleapis.com` injection
- OAuth stores a credential row with **`type='oauth'`** under the same `key`
  (store.go:42; sqlite.go:782-787). The access token is the credential's ciphertext;
  refresh token / client-secret / token_url / scopes live in a sibling `credential_oauth` row.
- A service rule with `auth: {type: bearer, token: GOOGLE_OAUTH_TOKEN}` resolves that key.
  At request time `StoreCredentialProvider.Inject` decrypts it; because `cred.Type ==
  "oauth"` and a `Refresher` is attached, it calls `maybeRefreshOAuth`
  (brokercore/credential.go:195-204, 257-336).
- **Auto-refresh trigger:** if `token_expires_at` is within **5 minutes** (`oauthRefreshBuffer
  = 5 * time.Minute`, credential.go:255) and a refresh token exists, it performs an
  RFC-6749 §6 `refresh_token` grant (`oauth.Refresh`), re-encrypts and persists the new
  tokens, and injects the fresh `Authorization: Bearer <access>` — overwriting any dummy
  the client sent. Refreshes are deduped via singleflight keyed `vaultID|key`
  (credential.go:274-275).
- If the oauth credential has never been connected (empty value), Inject returns
  `ErrOAuthNotConnected` (credential.go:195-197) → the request fails closed.

> Net: declare the Google credential as an OAuth credential under key
> `GOOGLE_OAUTH_TOKEN`, connect it once (browser or token-upload), then point the
> `*.googleapis.com` bearer rule's `token` at the SAME key. Refresh is automatic.

---

## 4. Listening ports + CA generation/exposure

### Ports (VERIFIED against source)
- **API / management UI / HTTP API: `14321`** (`DefaultPort = 14321`, defaults.go:9; README ASCII diagram lines 72-73; Docker `EXPOSE 14321`).
- **MITM transparent proxy: `14322`** (`DefaultMITMPort = 14322`, defaults.go:12; README:107 "HTTP API on port 14321 and a transparent HTTP/HTTPS proxy on port 14322"). The SAME proxy listener handles `CONNECT` for `https://` upstreams AND absolute-form forward-proxy for `http://` (README:107, run.go:534-536).
- Architecture doc's "14322 proxy / 14321 management" is **CORRECT.**
- Health check: `GET /health` on 14321 (used by detach-poll, server.go:600; Docker HEALTHCHECK).

### CA generation (internal/ca/soft.go — `SoftCA`)
- On server start with MITM enabled, `ca.New(masterKey, …)` loads-or-generates the root CA
  (cmd/server.go:177-191). Directory: **`~/.agent-vault/ca/`** (`defaultDirName = "ca"`,
  soft.go:29,90; under `$HOME` → in Docker `/data/.agent-vault/ca/`).
- Files written (soft.go:27-28):
  - **`ca.crt.pem`** — root cert, PEM, mode `0644` (soft.go:226).
  - **`ca.key.enc`** — root EC private key, **AES-256-GCM encrypted with the master DEK**, JSON `{nonce, ciphertext}` (base64), mode `0600` (soft.go:71-74, 234-247).
- Root: ECDSA **P-256**, CN `"Agent Vault Root CA"`, 10-year validity (soft.go:32-34, 198-216).
- Leaves: per-SNI ECDSA P-256, **24h TTL**, minted on demand and LRU-cached (soft.go:30,269-335). `ExtraSANs` adds the server's own hostname (from `AGENT_VAULT_ADDR`) to every leaf so clients verifying the proxy hostname succeed (cmd/server.go:181-186; soft.go:40-52).
- CA dir is created `0700` (soft.go:92). CA init failure is **non-fatal** — the HTTP API still starts; the proxy is just disabled with a stderr warning (cmd/server.go:188-190).

### How to get the CA PEM into the Hermes VM OS trust store
- **HTTP endpoint (preferred, no auth):** `GET http://<vault-host>:14321/v1/mitm/ca.pem`
  (server.go:860 → handleMITMCA, handle_mitm.go:21). Returns
  `Content-Type: application/x-pem-file`, filename `agent-vault-ca.pem`, and an
  `X-MITM-Port` response header advertising the live proxy port (handle_mitm.go:28-33).
  Returns **404** if the proxy isn't actually listening (handle_mitm.go:22-27).
- **CLI:** `agent-vault ca fetch -o /etc/ssl/certs/agent-vault-ca.pem` (cmd/ca.go:54-93)
  — same endpoint, writes the file (mode `0600`).
- **NixOS install:** put the fetched PEM into `security.pki.certificateFiles = [ ./agent-vault-ca.pem ];` (system trust store / update-ca-certificates). The PEM is stable across restarts once `ca.crt.pem` exists, so we can fetch it once at provisioning and commit/sops it, OR fetch at bootstrap. TODO(human): decide fetch-at-bootstrap vs. commit-the-PEM. The CA is regenerated only if `~/.agent-vault/ca/` is wiped.
- The CA cert is public/world-readable by design (only the *key* is secret) — safe to commit the `.pem` if convenient.

### Agent-side env contract (if we use `agent-vault run`, run.go:537-580)
Sets on the child: `HTTPS_PROXY` + `HTTP_PROXY` → `http://<vault-host>:14322` (with token+vault
in proxy auth), `NO_PROXY`, and CA trust vars `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, `DENO_CERT` all pointing at the
written PEM (`~/.agent-vault/mitm-ca.pem`, run.go:556). The SDK's `buildProxyEnv` exposes the
same set (README:206-208). We can set these ourselves in the Hermes systemd unit instead of
wrapping with `agent-vault run`.

---

## 5. How secrets / master password are supplied at runtime

### Master password (`@@AGENT_VAULT_MASTER_PASSWORD@@`)
- Env var **`AGENT_VAULT_MASTER_PASSWORD`** (highest priority), else `--password-stdin`,
  else interactive prompt (cmd/server.go:316-330). It **derives a KEK that wraps the DEK**
  (data encryption key); `.env.example:10-12`. "the password is used as part of its data
  encryption mechanism and is **unset from the process after the initial read**"
  (README:92; the code does `os.Unsetenv("AGENT_VAULT_MASTER_PASSWORD")` at
  server.go:319 before deriving).
- If omitted/empty → **passwordless mode**: the DEK is stored unwrapped on disk
  (`.env.example:11`, server.go:340-349, master_password.go). Security then depends on FS perms.
- Sub-commands to manage it offline (server must be stopped): `agent-vault master-password
  set|change|remove` (cmd/master_password.go).
- **Nix/systemd plan:** supply `AGENT_VAULT_MASTER_PASSWORD` via an `EnvironmentFile=` whose
  contents come from sops-nix (the `@@AGENT_VAULT_MASTER_PASSWORD@@` placeholder maps to a
  sops secret). Because the process unsets it after read, a one-shot env is fine. The
  detach path passes the derived 32-byte key to the child over a pipe, never re-reading the
  env (server.go:499-505, 579-594) — but we run foreground under systemd, so just the env file.

### Static API keys (OPENAI/EXA/HONCHO/GITHUB)
- Stored as **credentials inside a vault**, encrypted with the DEK in SQLite. NOT env vars
  consumed by the proxy at request time. Supplied via:
  - CLI: `agent-vault credential set OPENAI_API_KEY=sk-... EXA_API_KEY=... --vault hermes`
    (cmd/credential.go:148+; POST `/v1/credentials`).
  - or HTTP API `POST /v1/credentials` with `{vault, credentials:{KEY:VALUE,…}}`.
- This is a **post-start provisioning step** (server must be up + an admin/owner session). Plan:
  a oneshot provisioning unit/script that reads the keys from sops and runs `agent-vault
  credential set`, ordered `After=` the server unit. TODO(human): the provisioning script
  needs an authenticated session/token — owner is created on first run (interactively or via
  UI). Decide how to bootstrap the owner non-interactively (the first registered user becomes
  owner; there is no documented `--owner-email/--owner-password` server flag — VERIFY whether
  `agent-vault register`/owner_vault.go offers a non-interactive path).
- Google: NOT `credential set` (it's an OAuth credential) — use the §3 connect/upload flow.

### Other relevant env (from `.env.example`, process-level)
- `AGENT_VAULT_ADDR` — external base URL; its hostname is added as a leaf-cert SAN AND used as the OAuth redirect base. Set to the vault VM's reachable URL.
- `AGENT_VAULT_ALLOW_PRIVATE_RANGES` (default false → blocks RFC-1918/loopback/link-local; IMDS always blocked) and `AGENT_VAULT_NETWORK_ALLOWLIST` (comma CIDRs). **TODO(human): if upstreams or the agent network are private, set the allowlist; default-deny will block private targets.**
- `AGENT_VAULT_LOG_LEVEL` info|debug. `AGENT_VAULT_RATELIMIT_PROFILE` default|strict|loose|off.
- Infisical external store (optional, `INFISICAL_URL` + an auth method) — only if backing the vault with a remote Infisical store; not needed for the local encrypted store.

---

## 6. Commit pin (restate)
- Repo: `https://github.com/Infisical/agent-vault.git`
- **HEAD commit: `30ff25ce8f3c8cfd855e4e2d3e7713bb0b007eed`** (branch `main`).
- Research preview — API may change; pin this exact SHA in the flake input.

---

## Open items (TODO/BLOCKER)
- TODO(human): `buildGoModule` `vendorHash` — compute and paste.
- TODO(human): VERIFY `internal/server/webdist` embed — does it build headless without `npm run build`? If not, add a preBuild stub or run Vite.
- TODO(human): VERIFY Exa (`api.exa.ai`) and Honcho (`api.honcho.dev`) auth header shape (Bearer vs `x-api-key`) before finalizing the bearer rules.
- TODO(human): register `<AGENT_VAULT_ADDR>/v1/oauth/callback` as the Google client's authorized redirect URI; set `AGENT_VAULT_ADDR` to the vault VM's reachable URL.
- TODO(human): decide Google OAuth path — browser connect vs. headless token-upload (`POST /v1/credentials/oauth/tokens`).
- TODO(human): decide CA delivery — fetch `/v1/mitm/ca.pem` at bootstrap vs. commit the PEM into `security.pki.certificateFiles`.
- TODO(human): non-interactive owner bootstrap — the first registered user becomes owner; there is no documented server flag to seed owner email/password. Determine how the provisioning script authenticates to push credentials/services (verify `cmd/register.go` / `cmd/owner_vault.go`).
- TODO(human): if any upstream/agent traffic is on private IP ranges, set `AGENT_VAULT_NETWORK_ALLOWLIST` / `AGENT_VAULT_ALLOW_PRIVATE_RANGES` (default blocks them).
