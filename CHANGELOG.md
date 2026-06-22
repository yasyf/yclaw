# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` — the project is now MIT-licensed.
- A pre-commit secret guard (`.pre-commit-config.yaml`): a self-contained `pygrep`
  hook that blocks staged secret-shaped strings (Tailscale keys, OpenAI/GitHub
  tokens, AWS access keys, age and PEM private keys), matching the patterns the CI
  genericity guard already enforces. Install with `brew install pre-commit && pre-commit install`.
- Hermes agent state is externalized to the host. `honcho` memory, sessions, and
  the rest of `/var/lib/hermes` live in `~/.yclaw/state/hermes` over virtiofs, so
  conversation history survives a VM rebuild and is captured by backups.
- `just backup` — a `restic` backup of `~/.yclaw/state` that excludes the
  regenerable caches (`omlx/`, `mlx-audio/`). The model cache now lives in the host's
  regular `~/.cache/huggingface` (outside `~/.yclaw/state`), so it is regenerable and
  out of the backup scope entirely. Point it at a repo with `YCLAW_RESTIC_REPO` and
  `RESTIC_PASSWORD`; restore with `restic restore latest --target ~/.yclaw/state`
  followed by `just setup`.
- `just validate` (`scripts/validate-hardening.sh`) — a post-`bootstrap` probe, run on
  the host with the VMs up, that exercises the per-VM isolation + audit controls (pf
  gate, docker socket proxy, tailnet binds, crypto isolation, share boundary,
  credential plane, tailnet tags) over `tailscale ssh` and reports PASS/FAIL. The two
  checks needing a third tailnet node or a cross-VM decrypt are flagged as manual steps.
- A dedicated `yclaw` keychain (`~/Library/Keychains/yclaw.keychain-db`) holding
  every generated password (agent-vault master, per-VM admin, BlueBubbles server),
  siloed from your login keychain and auto-unlocked via one
  `yclaw-keychain-password` entry.
- End-of-bootstrap onboarding. Once `hermes` is reachable, `just bootstrap`
  auto-launches an interactive `hermes-onboard` over `tailscale ssh` that seeds the
  user-specific context the declarative build can't supply: your profile (`USER.md`),
  the agent persona (`SOUL.md`), and the Honcho peer identity. It runs as the `hermes`
  user, only writes files that are absent (so the agent's own later edits are never
  overwritten), and is re-runnable: `tailscale ssh -t admin@hermes -- sudo -u hermes -H
  hermes-onboard`.
- The `just bootstrap` recipe. The documented entrypoint (`scripts/bootstrap.sh`) had
  no matching recipe, so `just bootstrap` failed with "unknown recipe"; it now runs the
  wizard.
- `just nuke` and `just nuke-tailnet` — a true clean-slate teardown. `nuke` extends
  `destroy` by wiping host secret/agent state (`~/.yclaw/state`, the `hermes` node-config
  share) and the generated keychain passwords, while PRESERVING the operator-supplied
  Tailscale OAuth client and the large, content-addressed model caches (drop those too
  with `WIPE_MODELS=1`). `nuke-tailnet` deletes the VMs' lingering device registrations
  from the tailnet over the Tailscale API. The next `just bootstrap` regenerates the rest.

### Changed
- Lower iMessage reply latency. hermes now calls metal's model upstreams directly
  (cliproxy `:8317`, omlx `:8000`) instead of routing through the hosted Aperture
  node, removing a ~0.5 s WAN round-trip per call; cliproxy's `:8317` is `pf`-gated to
  hermes + the host, so hermes reaches it with no bearer of its own.
  Reasoning effort drops from `medium` to `low` (replies are sent only after the full
  completion, so reasoning time dominates perceived latency). The hermes-agent
  systemd unit gains `TimeoutStopSec=210s` so a graceful drain is not SIGKILLed
  mid-flight.
- Deploy is now a single wizard. `just bootstrap` runs end to end: preflight
  tooling, prompt for the non-secret values (tailnet, GitHub owner, IPSW URL, host
  RAM, authorized handles), mint the age key and generate per-VM passwords, encrypt
  state with sops, then build and boot all images. The agent-vault CA fetch from
  `metal` is automated; the remaining human gates (Apple-ID iMessage sign-in,
  `cliproxy` OAuth logins, agent-vault Google OAuth) are printed at the end.
- Honcho memory loads and targets the remote cloud. The `honcho` extra (`honcho-ai`)
  is baked into the hermes image — upstream dropped it from the eager-install set, so
  it would otherwise fail to lazy-install in the network-less Nix Python. The provider
  is declared (`memory.provider = "honcho"`, `environment = "production"`, no
  `base_url` so it targets the cloud, real key injected by agent-vault on `api.honcho.dev`), and
  `~/.honcho/config.json` is seeded as a writable copy rather than a read-only symlink,
  so the agent's own memory writes survive a rebuild.
- VM images are generic and reusable across tailnets. Nodes are addressed by bare
  Tailscale MagicDNS names (`metal`, `bluebubbles`, `hermes`, `ai`) and configured
  on first boot from an injected `node.env`, so a published image carries no
  site-specific identifiers. The `hermes` image's canonical source is CI; the wizard
  builds it locally as a fallback.
- Model ids have one source of truth, `nixos/models.nix`, consumed by
  `nixos/hermes.nix`, `nixos/ai.nix`, and `darwin/metal.nix`.
- Models are served from a SHARED Hugging Face cache. `metal` mounts the host's
  regular `~/.cache/huggingface/hub` as a read-write `hfhub` virtiofs share — only the
  `hub/` subdir, so the host's HF token never enters the VM — instead of a separate
  copy under `~/.yclaw/state/hf`; omlx and STT read it via `HF_HUB_CACHE`. `just
  bootstrap` auto-downloads the Qwen model into that cache, retiring the manual
  model-placement gate.
- Speech-to-text now lazy-loads and idle-unloads. `mlx-audio` STT on `metal` loads
  `granite-speech` on first use and unloads after an idle period, matching the omlx
  per-model idle TTL (1800s).
- Tailscale on the NixOS nodes is bumped to current (overlaid from
  `nixpkgs-unstable`).
- `just destroy` now tears down every yclaw VM, not just `metal` + `hermes`. It also
  stops and deletes the `bluebubbles` guest and the retired `vault` VM, boots out all
  three `com.yclaw.tart-*` launchd agents, and removes their runner plists.
- The end-of-bootstrap gate instructions pass `--no-browser` to the `cli-proxy-api`
  Codex/Gemini logins, so the OAuth consent can be approved in any browser and the code
  pasted back — no SSH tunnel to `metal` required.

### Removed
- The `tailscale-acl.yml` GitOps workflow. It force-replaced the whole tailnet ACL
  with `tailnet/policy.hujson` on push — destructive on a shared tailnet (it would
  deauthorize non-yclaw nodes). The yclaw tags are added to the ACL additively
  instead.
- The `vault` VM. `agent-vault` (the credential broker and MITM forward proxy) now
  runs on `metal`, the sole credential custodian, so there is no separate vault node.
- Host Nix. The macOS host no longer runs nix-darwin; `darwin/host.nix` and the host
  flake output are gone, and the host is provisioned by `scripts/setup.sh` (Homebrew
  `tart`, Tailscale, `gum`, `packer`, `restic`) alone. In-guest `metal` is still
  configured by nix-darwin (`darwinConfigurations.metal`).

### Security
- `metal` is hardened to SIP-on and tailnet-only. It is the sole credential
  custodian (omlx, `granite-speech` STT, CLIProxyAPI, and agent-vault all run
  inside it), locked down with a `pf` anchor plus the application firewall, with
  Remote Login off (reachable only via Tailscale SSH). Real secrets never enter
  `hermes`; agent-vault injects static keys and OAuth bearers on the wire, and
  `cliproxy` holds the Codex/Gemini subscription OAuth.
- BlueBubbles runs in its own SIP-off `bluebubbles` guest — a separate tailnet node
  that holds no credentials beyond the BlueBubbles server password it needs locally.
- **bluebubbles bring-up hardens itself.** `scripts/bluebubbles-setup.sh` best-effort
  auto-grants BlueBubbles the Full Disk Access + Accessibility TCC permissions (the
  guest is SIP-off, so the system/user TCC databases can be written and `tccd`
  reloaded), health-checks the server, and AUTO-DISABLES Screen Sharing once the
  Private-API helper has injected — falling back to the human GUI grant + `just
  bb-harden` only when the auto-grant does not take. Screen Sharing no longer stays
  enabled by default after bring-up. Apple-ID 2FA stays the one irreducibly-human step.
- Generated passwords are random and reused on re-run, never hardcoded, placeholder,
  or prompted. Packer reads each guest's admin password from the `yclaw` keychain via
  `PKR_VAR_vm_admin_pass`; the BlueBubbles password flows through sops.
- **Per-VM secret isolation.** Each host now has its own age keypair and its own
  sops bundle, encrypted only to that host's recipient and holding only the secrets
  it owns (`nixos/secrets-manifest.json` is the single source of truth for both the
  encryption scope and the `sops.secrets` read-selectors). A host can decrypt only
  its own secrets — the old single global key that decrypted every host's bundle on
  every VM is gone, and the vestigial host-side age key is no longer installed.
- **Narrow virtiofs shares.** `metal` no longer mounts the whole `~/.yclaw/state`
  tree; it gets read-only/scoped shares for only its own key, bundle, and runtime
  dirs, so it can no longer read `hermes`'s private agent state (memory, sessions,
  the BlueBubbles password in `.env`) or any other host's key.
- **Tailnet tags + per-node keys.** `tailnet/policy.hujson` is the reference for the
  `tag:hermes`/`tag:metal`/`tag:bluebubbles` `tagOwners` + admin-SSH rule and the
  intended default-deny `hermes → metal` grants. On a shared tailnet (the real
  deployment) those tags are added **additively** to the existing ACL — the full
  default-deny lockdown only applies on a tailnet dedicated to yclaw. Each node joins
  with its own ephemeral, single-use, tagged auth key minted from a Tailscale OAuth
  client — replacing the one reusable fleet-wide auth key.
- **Functional credential-injection plane.** `hermes` now presents a per-host
  agent-vault proxy token (minted from `metal` at bootstrap) so brokered upstream
  calls are actually injected instead of returning 407; the token only authorizes
  injection and cannot read raw keys. Instance-wide agent-vault proxy
  rate/concurrency limits are set and locked. The model plane carries no per-caller
  bearer at all: `metal`'s cliproxy `:8317` is reachable only by `hermes` + the host
  (the `pf` gate below), so "the tailnet is the auth" and `HERMES_CLIPROXY_KEY` is gone.
- **Defense-in-depth hardening.** `metal`'s boot-time `pf` gate fails loud (and
  non-zero) instead of silently leaving the credential services exposed if `pf` can't
  enable; the `hermes` code-exec containers run under the gVisor (`runsc`) runtime;
  the dedicated `yclaw` keychain auto-locks (300 s) and is re-locked after use;
  BlueBubbles' REST `:1234` is firewalled to the tailnet and its `config.json` is
  `0600`; and the builder + BlueBubbles base images are pinned by digest.
- **Docker socket no longer root-equivalent to the agent (H6).** gVisor sandboxes
  syscalls but not bind mounts, so a docker-group agent could still `docker run -v
  /:/host`. A new `hermes-docker-proxy` (default-deny, screens every container-create
  body) now fronts the socket; `hermes` is dropped from the docker group and reaches
  the filtered socket via `DOCKER_HOST`.
- **metal model services bound tailnet-only (M2).** omlx (`:8000`) and STT (`:8765`)
  bind the resolved tailnet IP instead of `0.0.0.0`, so they never listen on the vmnet
  LAN even if `pf` is down. STT needs no app bearer — the tailnet ACL + `pf` are the
  authentication for an internal service.
- **metal restricted to hermes + host, east-west (H3/H4 via `pf`).** The deployment tailnet is
  shared and its ACL is allow-all, so the ACL cannot scope metal to `tag:hermes`; a `pf` anchor
  does it instead. metal admits ONLY its two legitimate consumers to the five service ports —
  hermes (the runtime client, resolved by hostname at RUNTIME via `tailscale ip -4 hermes`) and the
  host admin machine (its tailnet IP, which `bootstrap.sh` injects over the SSH path; the host hits
  `metal:14321` for the bootstrap CA fetch and Google-OAuth admin, and its Mac is an existing tailnet
  member metal cannot name-resolve) — and drops every OTHER tailnet node (sprite/gcp/zo/modal) and
  the sibling vmnet-LAN guests. The scope is resolved at activation, at every boot, and on a 5-minute
  refresh, never baked into the build: if hermes is rebuilt and its IP changes, the next refresh
  re-scopes with no `darwin-rebuild`. It never fails open — a transient hermes unresolve reuses the
  sticky last-known IP, the anchor is written atomically and only persisted after the kernel accepts
  it, and with no resolvable source the anchor is fully CLOSED (loopback only), never the whole tailnet.

[Unreleased]: ../../commits/main
