# Placeholder manifest

Human-only inputs that resolve into a config or script are emitted as the literal token `@@NAME@@`
and listed here. **Never invent a real value.** `scripts/bootstrap.sh` prompts for each at run time
(or reads it from sops if pre-seeded), and code fails loud if a placeholder is still unresolved at
apply time — it never silently defaults.

Real secrets never land in the hermes VM filesystem or a commit. They flow through the credential
custodian (agent-vault and CLIProxyAPI on `metal`) or the `bootstrap` prompt at run time. See
[Architecture § Credential custody](../docs/ARCHITECTURE.md#credential-custody).

Three classes of value live here, in three tables below: `@@…@@` tokens substituted into in-tree
configs, secret values rendered into the sops blob, and non-token bootstrap inputs that flow as
packer vars or the runtime `node.env` share.

## In-tree `@@…@@` tokens

These literal tokens appear in committed configs and scripts and must be resolved before apply.

| Token | What | Where it lives | How the human supplies it |
|---|---|---|---|
| `@@TS_AUTHKEY@@` | Tailscale auth key (reusable/ephemeral) for VM join | `nixos/common.nix` | bootstrap prompt, into sops `tailscale/authkey` |
| `@@VM_ADMIN_PASS@@` | Password for the baked-in `admin` user (per-VM) | `darwin/metal.nix`, packer var default | generated per-VM into the yclaw keychain; packer reads it as `PKR_VAR_vm_admin_pass` (see below) |
| `@@APPLE_ID@@` | Dedicated Apple ID for iMessage (on the bluebubbles VM) | `scripts/bluebubbles-setup.sh` | **interactive (human gate)** |
| `@@APPLE_ID_PW@@` | Password for the dedicated Apple ID | `scripts/bluebubbles-setup.sh` | **interactive (human gate)** |
| `@@BLUEBUBBLES_PASSWORD@@` | BlueBubbles server password | `nixos/hermes.nix`, `scripts/bluebubbles-setup.sh` | generated into the yclaw keychain, rendered into sops `hermes/env` (see below) |
| `@@APERTURE_STATIC_KEY@@` | Static bearer CLIProxyAPI requires on metal:8317 (Aperture used to inject it; hermes now presents it directly) | `darwin/metal-cliproxyapi-config.yaml`, `darwin/metal.nix`, `nixos/ai.nix`, `nixos/hermes.nix` | `secrets.sh` mints `openssl rand -hex 32` if unset, into sops `aperture/static-key` **and** `hermes/env` |
| `@@AGE_PUBLIC_KEY@@` | Public half of the sops age key | `.sops.yaml` (template only) | `secrets.sh` mints the age key, renders the public half into `~/.yclaw/state/sops.yaml`; the committed `.sops.yaml` keeps the placeholder |
| `@@AGENT_VAULT_CA_PEM@@` | agent-vault MITM CA the hermes VM trusts | `nixos/agent-vault-ca.pem`, `nixos/hermes.nix` | bootstrap fetches the real public CA from metal and overwrites the file (CA is public; safe to commit) |

## sops-encrypted secret values

`scripts/lib/secrets.sh` is the single writer of the per-host bundles under
`~/.yclaw/state/hosts/<host>/secrets.sops.yaml`. It prompts for the external API keys, mints or
reuses the keychain passwords, and renders each host's slice into its own age-encrypted bundle —
encrypted only to that host's recipient. `nixos/secrets-manifest.json` is the source of truth for
which host owns which secret. Nothing here is committed in plaintext.

| Value | What | sops path | How the human supplies it |
|---|---|---|---|
| `OPENAI_API_KEY` | image-gen (`gpt-image-2`) + vision/web-extract aux | `vault/static-keys` | bootstrap prompt, into agent-vault static |
| `EXA_API_KEY` | web search | `vault/static-keys` | bootstrap prompt, into agent-vault static |
| `HONCHO_API_KEY` | memory (hosted Honcho) | `vault/static-keys` | bootstrap prompt, into agent-vault static |
| `GITHUB_TOKEN` | GitHub PAT | `vault/static-keys` | sourced from the local `gh` CLI token, else prompt, into agent-vault static |
| `AGENT_VAULT_MASTER_PASSWORD` | agent-vault encryption | `vault/master-password` | generated into the yclaw keychain, rendered into sops |
| `TS_AUTHKEY` | resolves `@@TS_AUTHKEY@@` (above) | `tailscale/authkey` | bootstrap prompt |
| `BLUEBUBBLES_PASSWORD` | resolves `@@BLUEBUBBLES_PASSWORD@@` (above) | `hermes/env` | generated into the yclaw keychain |
| `APERTURE_STATIC_KEY` | resolves `@@APERTURE_STATIC_KEY@@` (above) | `aperture/static-key`, `hermes/env` | minted by `secrets.sh` if unset |

## Bootstrap inputs without an in-tree token

These are collected by `scripts/bootstrap.sh` but never substituted as a `@@…@@` token. They reach
the guests as packer vars at build time or the runtime `node.env` share on first boot.

| Input | What | Consumed by | How the human supplies it |
|---|---|---|---|
| `IPSW_URL` | Pinned macOS Tahoe IPSW URL (or local path) for the metal guest | `packer/metal.pkr.hcl` as `PKR_VAR_ipsw_url` (fail-loud `@@UNSET_IPSW_URL@@` default if unset) | prompt (with reachability check) |
| `GITHUB_OWNER` | GitHub owner whose `yclaw` fork the guests clone at build | `packer/metal.pkr.hcl` as `PKR_VAR_github_owner` (fail-loud `@@UNSET_GITHUB_OWNER@@` default if unset) | derived from `remote.origin.url`, else prompt |
| `vm_admin_pass` | Per-VM admin password (resolves `@@VM_ADMIN_PASS@@`) | `packer/metal.pkr.hcl`, `packer/bluebubbles.pkr.hcl` as `PKR_VAR_vm_admin_pass` | generated per-VM into the yclaw keychain (`yclaw.keychain-db`, services `yclaw-metal-admin-pass` / `yclaw-bluebubbles-admin-pass`), unlocked via `yclaw-keychain-password` in the login keychain, reused on re-run |
| `AUTHORIZED_HANDLES` | iMessage allowlist (comma-separated; first handle is the home channel) | hermes VM via the runtime `node.env` share (`BLUEBUBBLES_ALLOWED_USERS` / `BLUEBUBBLES_HOME_CHANNEL`) | prompt (list) |
| `HOST_RAM` | Host RAM tier (GB) for VM sizing | recorded in `~/.yclaw/state` for `just deploy` re-runs | prompt |
| `TAILNET_DOMAIN` | MagicDNS suffix, e.g. `tailXXXX.ts.net` | rendered into `node.env` as the two BlueBubbles FQDN endpoints (`BLUEBUBBLES_SERVER_URL`/`BLUEBUBBLES_WEBHOOK_HOST` — tailscale-serve's TLS cert is FQDN-only and the webhook can't bind to bare `hermes`→127.0.0.2); every other guest endpoint stays a bare MagicDNS name; also prints the human-facing gate URLs at the end of bootstrap | auto-detect via `tailscale status --json`, else prompt |

The admin **username** is no longer a token: `packer/metal.pkr.hcl` and `packer/bluebubbles.pkr.hcl`
default `vm_admin_user` to `admin` (matching `darwin/metal.nix` `adminUser`), overridable via
`PKR_VAR_vm_admin_user`.

## Interactive one-time sign-ins (cannot be scripted)

These are pure human gates — no token, no prompt. `scripts/bootstrap.sh` prints them at the end and
stops; the operator completes each:

- `cli-proxy-api --codex-login` — ChatGPT **subscription** account (metal, one-time browser flow).
- `cli-proxy-api --login` — **personal** Google (free Code Assist) (metal, one-time browser flow).
- agent-vault **Google OAuth consent** — run `./scripts/connect-google-oauth.py` on the host; open
  the printed consent URL, approve, and it finishes against the desktop client's `localhost`
  redirect.
- **Apple-ID iMessage sign-in** (2FA) on the bluebubbles VM, then `scripts/bluebubbles-setup.sh`.

## Encrypted material

`secrets/*.sops.yaml` would hold sops-encrypted values for unattended rebuilds, but the canonical
encrypted bundles live one per host at `~/.yclaw/state/hosts/<host>/secrets.sops.yaml`, never in
the repo, each encrypted only to that host's recipient and carrying only that host's secrets per
`nixos/secrets-manifest.json` (`hermes` and `metal` get bundles; `bluebubbles` owns none).
`bootstrap.sh` (via `scripts/lib/secrets.sh`) is the single writer of runtime secret material;
nothing here is committed in plaintext. Each host's private age key lands at
`~/.yclaw/state/hosts/<host>/key.txt` and is never committed.
