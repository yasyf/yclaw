# Placeholder Manifest

Every human-only input in this repo is emitted as the literal token `@@NAME@@` in configs and
scripts, and listed here. **Never invent a real value.** `scripts/bootstrap.sh` prompts for each at
run time (or reads it from sops/agenix if pre-seeded), and code fails loud if a placeholder is still
unresolved at apply time — it never silently defaults.

Real secrets never land in the Nix store, the hermes VM filesystem, or a commit. They flow through
the credential planes (agent-vault on the `vault` VM, CLIProxyAPI on the host) or the `bootstrap`
prompt at run time. See [`hermes-home-server.md` §5](../docs/hermes-home-server.md#5-credential-planes-custody-not-containment).

## Tokens

| Token | What | Consumed by | How the human supplies it |
|---|---|---|---|
| `@@TAILNET_DOMAIN@@` | MagicDNS suffix, e.g. `tailXXXX.ts.net` | every `*.<tailnet>.ts.net` name | auto-detect via `tailscale status --json` if the host is on the tailnet; else prompt |
| `@@TS_AUTHKEY@@` | Tailscale auth key (reusable/ephemeral) for VM join | each VM's `tailscaled` (cloud-init / nixos) | bootstrap prompt → sops |
| `@@HOST_NAME@@` | Which Mac (hostname) the host config targets | `darwin/host.nix`, packer | prompt |
| `@@HOST_USER@@` | macOS login user on the host (home dir, launchd log paths, CLIProxyAPI `auth-dir`) | `darwin/host.nix`, `darwin/cliproxyapi-config.yaml` | prompt |
| `@@HOST_RAM@@` | Host RAM tier (GB) for VM sizing | `darwin/host.nix` | prompt |
| `@@IPSW_URL@@` | Pinned Sequoia IPSW URL for the macOS BB VM | `packer/bluebubbles.pkr.hcl` | prompt |
| `@@APPLE_ID@@` | Dedicated Apple ID for iMessage | bluebubbles VM sign-in | **interactive (human gate)** |
| `@@APPLE_ID_PW@@` | Password for the dedicated Apple ID | bluebubbles VM sign-in | **interactive (human gate)** |
| `@@VM_ADMIN_USER@@` | Local admin user baked into the bluebubbles macOS image | `packer/bluebubbles.pkr.hcl` | packer var (prompt) |
| `@@VM_ADMIN_PASS@@` | Password for `@@VM_ADMIN_USER@@` (sensitive) | `packer/bluebubbles.pkr.hcl` | packer var (prompt) |
| `@@BLUEBUBBLES_PASSWORD@@` | BlueBubbles server password | vault static cred → hermes env | bootstrap prompt → vault |
| `@@AUTHORIZED_HANDLES@@` | iMessage allowlist (your + approved handles/groups) | bluebubbles `allow_from` / `*_ALLOWED_*` | prompt (list) |
| `@@OPENAI_API_KEY@@` | image-gen (gpt-image-2) + vision/web_extract aux | vault static → injected on `api.openai.com` | prompt → vault |
| `@@EXA_API_KEY@@` | web search | vault static → `api.exa.ai` | prompt → vault |
| `@@HONCHO_API_KEY@@` | memory (hosted Honcho) | vault static → `api.honcho.dev` | prompt → vault |
| `@@GITHUB_TOKEN@@` | GitHub PAT (or move to OAuth) | vault static → `api.github.com` | prompt → vault |
| `@@GOOGLE_OAUTH_CLIENT_ID@@` | Google Cloud **Web** OAuth client id (Gmail/Cal restricted scopes) | agent-vault `oauth/connect` | human creates in GCP console → prompt |
| `@@GOOGLE_OAUTH_CLIENT_SECRET@@` | Google Cloud **Web** OAuth client secret | agent-vault `oauth/connect` | human creates in GCP console → prompt |
| `@@AGENT_VAULT_MASTER_PASSWORD@@` | agent-vault vault encryption | vault server | bootstrap prompt → sops |
| `@@APERTURE_STATIC_KEY@@` | static key Aperture presents to CLIProxyAPI | `ai.nix` ↔ CLIProxyAPI | generate (bootstrap may mint a random one) → sops |

## Interactive one-time sign-ins (cannot be scripted)

These leave a `HUMAN:` note in the relevant script and the run continues elsewhere:

- `cli-proxy-api --codex-login` — ChatGPT **subscription** account (host, one-time browser flow).
- `cli-proxy-api --gemini-login` — **personal** Google (free Code Assist) (host, one-time browser flow).
- agent-vault **Google OAuth consent** — `POST /v1/credentials/oauth/connect` → browser, callback to
  `https://vault.<tailnet>.ts.net/v1/oauth/callback` from any tailnet device.
- **Apple-ID iMessage sign-in** (2FA) on the bluebubbles VM.
- **SIP disable** on the bluebubbles VM (recovery mode) — see [`../scripts/sip-disable.md`](../scripts/sip-disable.md).

## Encrypted material

`secrets/*.age` / `secrets/*.sops.yaml` hold sops-nix/agenix-encrypted values for unattended
rebuilds (the Tailscale auth key, agent-vault master password, the static API keys). Until the human
supplies real values, these carry placeholder keys. `bootstrap.sh` is the single writer of runtime
secret material; nothing here is committed in plaintext.

## Generated artifacts (not human inputs)

These are produced during bootstrap, not prompted for — listed so the `@@…@@` markers in them aren't
mistaken for missing inputs:

- `@@AGE_PUBLIC_KEY@@` (in `.sops.yaml`) — bootstrap writes the public half of the age key it
  generates; the private key lands at `/var/lib/sops-nix/key.txt` on each VM (never committed).
- `@@AGENT_VAULT_CA_PEM@@` (in `nixos/agent-vault-ca.pem`) — a placeholder line; bootstrap fetches the
  real public CA via `GET http://vault.<tailnet>:14321/v1/mitm/ca.pem` and overwrites the file. The CA
  cert is public (only its key is secret), so the fetched PEM is safe to commit.
