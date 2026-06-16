# Deployment Handoff — bring the Hermes Home Server up end-to-end

> **You are the deploying agent.** The IaC is authored, committed, pushed, and Nix-verified
> (flake locks, all outputs evaluate, both Go services build). Your job: deploy it on the live host
> `yasyf-home` until [the smoke tests](#phase-8--smoke-tests-definition-of-done) pass.
>
> **Authority:** full autonomy. Run sudo, `darwin-rebuild switch`, create/destroy tart VMs, build
> images, provision. For the interactive sign-ins (browser OAuth, Apple-ID, Aperture dashboard),
> **drive them with `claude-in-chrome` / computer-use** rather than stopping — only fall back to a
> `HUMAN:` ask if automation genuinely can't proceed (e.g. a 2FA code only on the user's phone).

## 0. Mission & decisions (locked by the operator)

- **Scope:** full stack **including iMessage**. Done = the smoke tests pass (not the full
  destroy-and-rebuild — that's a later milestone).
- **Brownfield:** this machine already runs the prior `openclaw.md` experiment — an `openclaw` VM
  (old agent gateway) and a `bluebubbles` VM (iMessage, **already signed in** the old manual way).
  - **Decommission `openclaw`** (VM + `com.local.tart.openclaw` launchagent + `~/.openclaw`): the
    hermes+vault stack replaces it.
  - **Reuse the `bluebubbles` VM** — keep its Apple-ID/iMessage sign-in; repoint its BlueBubbles
    webhook from openclaw to hermes and (optionally) re-provision it the reproducible way later.
- **Credentials:** all available — ChatGPT/Codex subscription, personal Google (Gemini), OpenAI,
  Exa, Honcho, GitHub, a Google Cloud Workspace OAuth client, and the dedicated Apple ID.

## 1. Known environment (baked in — do NOT re-discover)

| Fact | Value |
|---|---|
| Host | `yasyf-home`, Apple Silicon, macOS 26.4.1 (Tahoe), **128 GB** RAM, user `yasyf` |
| Tailnet (`@@TAILNET_DOMAIN@@`) | `tail71af5d.ts.net` |
| **Bridged interface** | **`en12`** — the existing plists use it; **NOT `en0`** (the source default is wrong, see §2) |
| Aperture node `ai` | **up** at `100.90.33.88` (linux) — `http://ai/v1` is real; configured in the hosted dashboard |
| `bluebubbles` VM | exists at `100.120.65.20`; currently **suspended/offline** on the tailnet — wake it |
| `openclaw` VM | `100.71.147.16` — **decommission** |
| Nix | 2.34.7, flakes on. `nix.linux-builder` comes up only **after** `darwin-rebuild switch` |
| Repo | `github.com/yasyf/yclaw` `main` (pushed). Stays a template; deploy substitutes the working tree (uncommitted) + sops for secrets — do NOT commit substituted secrets |

### Placeholder resolution

Non-secret tokens (substitute into the working tree at deploy time, e.g. via `bootstrap.sh`):
`@@HOST_NAME@@`=`yasyf-home`, `@@HOST_USER@@`=`yasyf`, `@@HOST_RAM@@`=`128`,
`@@TAILNET_DOMAIN@@`=`tail71af5d.ts.net`, bridged iface=`en12`.

Secret tokens (prompted by `bootstrap.sh` → encrypted into `secrets/secrets.sops.yaml`, never
committed): `@@OPENAI_API_KEY@@`, `@@EXA_API_KEY@@`, `@@HONCHO_API_KEY@@`, `@@GITHUB_TOKEN@@`,
`@@BLUEBUBBLES_PASSWORD@@` (read it off the existing BB VM — don't reset it), `@@TS_AUTHKEY@@`
(mint a reusable/ephemeral key in the Tailscale admin console), `@@AGENT_VAULT_MASTER_PASSWORD@@`
(mint), `@@APERTURE_STATIC_KEY@@` (mint, `openssl rand -hex 32`), `@@GOOGLE_OAUTH_CLIENT_ID@@` /
`@@GOOGLE_OAUTH_CLIENT_SECRET@@`, `@@AUTHORIZED_HANDLES@@` (your iMessage handle(s)).

## 2. Source fixes to land FIRST (known-wrong defaults)

1. **`en0` → `en12`.** `darwin/host.nix` (the `tart-hermes`/`tart-vault` launchd agents) and the
   tart launch commands default to `--net-bridged=en0`. This host bridges on `en12`. Make it a
   `@@NET_BRIDGED_IFACE@@` placeholder (add to `secrets/PLACEHOLDERS.md`, resolve to `en12`) or set
   `en12` directly.
2. **agent-vault owner bootstrap** (`nixos/vault.nix` TODO): the provisioning oneshot needs an
   authenticated owner session, and the first registered user becomes owner with no documented
   non-interactive seed. Plan: let the server come up, then register the owner via the API/UI on
   `http://vault.<tailnet>:14321` (drive with `claude-in-chrome`), capture the session/token, and
   feed it to the `vault service set` / `credential set` calls. Update the oneshot accordingly.
3. **BB VM reuse, not rebuild.** The packer image + `bluebubbles-setup.sh` are for a from-scratch
   VM. For now, skip them — reuse the running VM and only repoint the webhook (§ Phase 6).

## 3. Phases (each gates on its verification before the next)

### Phase 1 — Host apply (nix-darwin)
- Substitute the non-secret placeholders + `en12` into the working tree.
- Install + apply nix-darwin: `nix run nix-darwin -- switch --flake .#host` (first time), thereafter
  `darwin-rebuild switch --flake .#host`. **Risk:** this is a daily-driver Mac — it takes over
  Homebrew + launchd; reconcile with the existing `com.local.tart.*` agents (they'll be replaced by
  the nix-darwin `org.nixos.tart-*` agents). Boot out the old agents first.
- **Verify:** `darwin-rebuild` succeeds; `nix.linux-builder` VM is up
  (`nix store ping --store ssh-ng://linux-builder` or check `launchctl`); MLX/Parakeet/CLIProxyAPI
  launchd agents loaded; `pfctl -s anchors` shows `vnc`.

### Phase 2 — Model plane
- MLX Qwen on `:8080` and Parakeet on `:8765` (launchd). CLIProxyAPI on `:8317`.
- **Interactive (automate via claude-in-chrome):** `cli-proxy-api --codex-login` (ChatGPT
  subscription) and `cli-proxy-api --login` (personal Google — NOTE: `--login`, not
  `--gemini-login`). One holder only; back up `~/.cli-proxy-api`.
- **Aperture (hosted dashboard, drive via claude-in-chrome):** build the providers config
  (`nix build .#packages.aarch64-darwin.aperture-config`), then paste it into the Aperture dashboard
  Settings (the config-API write verb is unverified — use the UI). Set the `@@APERTURE_STATIC_KEY@@`.
- **Verify:** `curl http://ai/v1/chat/completions -d '{"model":"gpt-5.5",...,"ping"}'` returns; then
  disable the gpt-5.5 upstream and confirm fallback `gemini-3.5` → `qwen-local`.

### Phase 3 — Credential plane (vault VM)
- Mint `@@TS_AUTHKEY@@`. Build the image (`nix build .#packages.aarch64-linux.vault-image`, needs
  the linux-builder) → `tart create --linux vault` → disk-replace → boot → it joins the tailnet.
- Owner bootstrap (§2.2, via UI), push `vault-services.yaml`, set the static creds from sops.
- **Google OAuth connect (drive via claude-in-chrome):** `POST /v1/credentials/oauth/connect` with
  the Workspace client id/secret → open the returned URL → consent. Register the exact redirect URI
  `http://vault.<tailnet>:14321/v1/oauth/callback` in the Google Cloud console first.
- Fetch the CA: `GET http://vault.<tailnet>:14321/v1/mitm/ca.pem` → `nixos/agent-vault-ca.pem`.
- **Verify:** a direct proxied `curl` through `http://vault.<tailnet>:14322` to `api.openai.com`
  gets the injected bearer; `GET /v1/mitm/ca.pem` returns the PEM.

### Phase 4 — hermes VM
- Rebuild the hermes image **with the real CA** committed to `nixos/agent-vault-ca.pem`. Build →
  `tart create --linux hermes` → disk-replace → boot → joins the tailnet.
- The systemd `ExecStartPre` blocks until BlueBubbles answers (Phase 5) — that's expected ordering.
- **Verify:** `tailscale ssh admin@hermes -- hermes doctor` is green; the gateway reaches
  `http://ai/v1` (direct) and the vault proxy; `gws` round-trips a dummy token (real Google token
  never in the hermes VM — apply `scripts/gws-bridge.patch` to the vendored skill).

### Phase 5 — BlueBubbles (reuse)
- Wake the `bluebubbles` VM; bring its in-VM `tailscaled` back up (it's offline). Confirm
  `tailscale serve --bg --https=443 1234` is still active and `https://bluebubbles.<tailnet>/api/v1/server/info`
  answers (needs the `?password=` or `guid`).
- Repoint the BlueBubbles webhook to `https://hermes.<tailnet>` (it currently points at openclaw).
- Set the hermes env: `BLUEBUBBLES_SERVER_URL`, `BLUEBUBBLES_PASSWORD` (read from the BB VM),
  `BLUEBUBBLES_ALLOWED_USERS=@@AUTHORIZED_HANDLES@@`, `BLUEBUBBLES_ALLOW_ALL_USERS=false`.
- **Verify:** send/receive a DM and a group message from an authorized handle.

### Phase 6 — Decommission openclaw
- `launchctl bootout gui/$(id -u)/com.local.tart.openclaw`; `tart stop openclaw && tart delete openclaw`;
  remove `~/Library/LaunchAgents/com.local.tart.openclaw.plist` and `~/.openclaw`.
- Do this **after** hermes is confirmed healthy, so there's no agent gap.

### Phase 7 — Smoke tests (definition of done)
```bash
nix flake check                                                              # config integrity (needs linux-builder)
curl http://ai/v1/chat/completions -d '{"model":"gpt-5.5","messages":[{"role":"user","content":"ping"}]}'
# fallback: disable gpt-5.5 upstream → confirm gemini-3.5 → qwen-local
# vault: a tool call needing Exa/OpenAI succeeds (bearer injected); fails cleanly if vault is down
# gmail: `gws` with the dummy token round-trips through the vault proxy
# bluebubbles: send/receive in a DM AND a group from an authorized handle
tailscale ssh admin@hermes -- hermes doctor
```

## 4. Pitfalls (the sharp edges, front-loaded)

- **`en12`, not `en0`** — every VM `--net-bridged` must be `en12` on this host.
- **linux-builder ordering** — `nix build .#…-image` (aarch64-linux) fails until `darwin-rebuild
  switch` has brought `nix.linux-builder` up. Phase 1 must precede the image builds.
- **CLIProxyAPI single-holder rule** — the Codex/Gemini refresh tokens are single-use/rotating; only
  CLIProxyAPI may hold them. Don't log the same accounts in elsewhere. Back up `~/.cli-proxy-api`;
  alert on `invalid_grant`.
- **rustls ignores `SSL_CERT_FILE`** — the agent-vault CA must be in the hermes VM's OS trust store
  (`security.pki.certificateFiles`, already wired). Fetch the REAL CA before building the hermes
  image; the committed `nixos/agent-vault-ca.pem` is a placeholder.
- **CA fetch ordering** — vault must be up to serve `/v1/mitm/ca.pem`, and hermes needs that CA at
  image-build time. So: vault first → fetch CA → (re)build hermes image.
- **BB VM is suspended** — `tart` shows it "running" but the tailnet shows it offline; its in-VM
  tailscale needs waking. Don't assume it's reachable.
- **Don't reset the BB password** — read the existing one off the VM; resetting breaks the running
  iMessage bridge.
- **agent-vault owner bootstrap** — non-interactive owner seeding is undocumented; register via the
  UI (claude-in-chrome) and capture the session.
- **Aperture config API** — the write verb/path is unverified; use the dashboard UI, do not script a
  `PUT /api/config`.
- **Secrets never committed** — substitute into the working tree for deploy; commit nothing with a
  real secret. `bootstrap.sh`'s residue guard (`grep -rl '@@'`) gates the apply.

## 5. Workflow plan

The deploying agent (you) tracks state, runs the host/VM commands, and drives browser automation; it
fans work out only where parallel and independent.

| Phase | Shape | Agents | Verification |
|---|---|---|---|
| Source fixes (§2) | main-agent | edits in place | `nix eval` of host + VMs still clean |
| Host apply | main-agent | `darwin-rebuild switch` | linux-builder up; launchd agents loaded; pf anchor present |
| Model plane | main-agent + claude-in-chrome | logins + Aperture UI | `curl http://ai/v1` ping; fallback hops |
| Image builds | parallel | `nix build` hermes-image + vault-image (linux-builder) | images build; `tart` boots them |
| Vault provision | main-agent + claude-in-chrome | owner + rules + OAuth connect | proxied curl gets injected bearer |
| hermes bring-up | main-agent | build → tart → boot | `hermes doctor` green |
| BlueBubbles | main-agent + claude-in-chrome | wake VM + repoint webhook | DM + group send/receive |
| Decommission | main-agent | bootout + delete openclaw | openclaw gone; hermes still healthy |

## 6. Verification (proving "done")

Run the [Phase 7 smoke tests](#phase-7--smoke-tests-definition-of-done). All must pass:
the model ping routes through Aperture, the fallback chain hops on a killed upstream, a
vault-injected tool call succeeds, `gws` round-trips a dummy Google token, BlueBubbles sends and
receives in a DM and a group from an authorized handle, and `hermes doctor` is green on each VM.
