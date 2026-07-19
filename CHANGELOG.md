# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- The hermes container supervisor and its egress firewall. `apple/container` has no
  boot-autostart or restart verb, so a resident `com.yclaw.container-hermes` LaunchAgent
  ticks `/usr/local/lib/yclaw/container-hermes.sh` every 60 s under `KeepAlive`,
  re-execing and recreating the `hermes` container whenever it is absent — the lifecycle
  fix that keeps the agent always-on. The `com.yclaw.container-pf-refresh` LaunchDaemon
  holds the container's egress `pf` rules, and the container entrypoint (`setpriv`-drops
  root to uid 1000 + supplementary group 0, then renders `config.yaml` and the environment
  from the baked `services.hermes-agent.settings`) replaces the old `hermes-agent.service`
  systemd unit. From-scratch bring-up is a gated manual step — build and load the
  `hermes-agent:latest` image, run `./scripts/setup.sh host-container`, then load the
  supervisor — not part of the unattended `just bootstrap`.
- `com.yclaw.metal-nightly-bounce` — a host LaunchAgent (`scripts/setup.sh`, listed in
  `machines.json`, torn down by `scripts/destroy.sh`) that stops the metal VM at 05:00
  daily. macOS guests have no memory balloon, so the VM service's host RSS ratchets to
  the guest's high-water mark until a restart; KeepAlive on `com.yclaw.tart-metal`
  relaunches the VM immediately, dropping the footprint back to the fresh-boot ~9 GB.
- `machines.json` — the canonical fleet manifest at the repo root: machines, services,
  launchd labels, ports, health endpoints, log paths, virtiofs shares, keychain service
  names, host state paths, and the per-node debloat lists. Three readers consume it so a
  fleet fact is stated once: bash (`scripts/lib/manifest.sh`, jq with a fail-loud
  missing-key error), Nix (`darwin/metal.nix` via `builtins.fromJSON` — the pf anchor's
  port set and the debloat disable loops derive from it), and the `yclaw` Python CLI
  (`yclaw/manifest.py`). The ports mirror `tailnet/policy.hujson` by hand.
- `scripts/lib/` — the shared bash library (bash 3.2, functions-only):
  `common.sh` (logging, `need` preflight, build-mirror rsync), `manifest.sh`,
  `wait.sh` (the ONE blessed bounded-wait helper set — self-contained by design, so it is
  sourced on the host, embedded verbatim into the nix launchd wrappers, shipped into the
  metal image at `/usr/local/lib/yclaw/wait.sh`, and piped into guests), `launchd.sh`
  (`bootout_drain`), `pf.sh` (`install_pf_anchor`, targeted `pfctl -a <name> -f` loads
  only), `ssh.sh` (`ts_run` — exactly one command string per `tailscale ssh` — and
  `guest_pipe`, which ships wait.sh + pf.sh + a manifest prelude + secret env to a guest
  over stdin so secrets never hit argv), and `secrets.sh`. Every consumer script is
  refactored onto it.
- The `yclaw` debug CLI — a Python package (uv, click, anyio; flat at the repo root;
  139 tests) run as `uv run yclaw ...`: `ssh`, `wait` (http/port/service/share/ssh),
  `logs`, `status`, `doctor` (`--live` adds the credential-plane checks), `restart`,
  `bounce`, `vm` (list/ip/ssh/console), and `secret` (list/read/sops), all driven by
  `machines.json`. `yclaw/remote.py` is the sole tailscale-ssh chokepoint: one command
  string per call, Tailscale check-wall detection (exit 4 with the approval URL),
  anyio-bounded timeouts, and a per-host ssh concurrency limit. Exit codes: 0 clean,
  1 FAIL, 2 usage, 4 check-wall, 5 timeout.
- Packer first-boot hardening: `com.yclaw.metal-activate` self-retries until success
  (`KeepAlive.SuccessfulExit = false`), and the activator sources the shared wait lib
  instead of hand-rolled loops.
- Guest macOS slimming, encoded in provisioning so it survives image rebuilds. `metal`
  (aggressive) disables ~55 non-essential launchd jobs in its `postActivation` — the Spotlight
  `mds` daemon, Time Machine, photo/media analysis, Apple Intelligence, iCloud, Continuity,
  Find My, Siri, Game Center, Screen Time, location, and the analytics / telemetry / experiment /
  differential-privacy stack — across both the `system/` and the auto-login `gui/<uid>` launchd
  domains, and pins `pmset` to never sleep. Domains were read off the host's own macOS 26
  `/System/Library/Launch{Daemons,Agents}` (the guests share that base), not guessed; every call
  is `|| true`. `bluebubbles` gets a deliberately narrow safe subset (`bluebubbles-setup.sh
  debloat`, also run by `setup` / `reconfigure`) that never touches the Apple-ID / push /
  iMessage / iCloud / Private-API stack. Local crash diagnostics (`ReportCrash`, `spindump`) and
  automatic security updates stay on; only Apple's telemetry upload (`SubmitDiagInfo`) is cut.
  `just validate` §8 asserts the overrides landed, omlx still serves, and crash logging is preserved.
- `just onboard` (`scripts/onboard.sh`) — a guided TUI for the post-`bootstrap` human
  gates, run in a zellij session (tmux fallback). It surfaces the Tailscale SSH
  `action: check` re-auth URL the bootstrap probes used to swallow (a silent hang),
  seeds the hermes identity, runs the Codex + Gemini cli-proxy logins as subprocesses in
  their own panes (Gemini's `localhost:8085` callback forwarded over `ssh -L` since it
  has no paste fallback), connects agent-vault Google OAuth, and walks the Apple-ID /
  BlueBubbles bring-up over VNC — then runs `just validate` + `just smoke`. Every gate
  is idempotent (already-done gates are skipped) and no secret is minted. Force an inline
  run with `YCLAW_ONBOARD_NO_ZELLIJ=1`.
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
- End-of-bootstrap agent onboarding seeds the user-specific context the declarative
  build can't supply — your profile (`USER.md`) and the agent persona (`SOUL.md`). With
  hermes now a container, this is a gated manual step, not an auto-launched
  `hermes-onboard` over `tailscale ssh`: write the files into the bind-mounted state dir
  (`~/.yclaw/state/hermes/.hermes/`, which the container reads at `/var/lib/hermes/.hermes/`)
  and confirm with `uv run yclaw onboard --gate hermes-identity`. Only absent files are
  written, so the agent's own later edits are never overwritten.
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
- hermes moved from a `tart` NixOS VM (Virtualization.framework, 4 vCPU / 4 GiB) to an
  Apple `container` OCI container named `hermes` on the macOS host. The agent runs
  **unprivileged**: uid 1000 with supplementary group 0, which the entrypoint reaches by
  `setpriv`-dropping from root. Group 0 is load-bearing — the virtiofs idmap maps the
  host-gid-1000 proxy socket to guest gid 0, so carrying group 0 through the drop is what
  keeps that socket reachable. Agent state is **bind-mounted**, not virtiofs:
  `~/.yclaw/state/hermes` → `/var/lib/hermes` (honcho memory, sessions) and
  `~/.yclaw/state/hermes-ts-state` → `/var/lib/tailscale` (tailnet identity), with the
  restic file-level backup unchanged. The config source is unchanged in spirit —
  `nixos/hermes.nix`'s `services.hermes-agent.settings` still feeds the image (the
  `hermes-container-image` flake output imports `nixosConfigurations.hermes`) and the
  entrypoint renders `config.yaml` plus the environment from it; hermes.nix drops only its
  tart-only wiring (the `hermes-agent.service` systemd unit and the `/var/lib/hermes` +
  `/var/lib/yclaw-repo` virtiofs `fileSystems`), guest-eval-verified for zero settings
  drift. The model plane is unchanged: the container still calls `metal:8000` (rapid-mlx),
  `metal:8317` (cliproxy), and `metal:8765` (STT), egresses external traffic through
  `HTTPS_PROXY=…@metal:14322`, and the code-exec sandbox chain (`hermes-docker-proxy` →
  socktainer → nested Apple containers, with the agent mounting only the proxy socket) is
  untouched.
- The hermes deploy surface is repointed off `tart`/`nixos-rebuild` onto the container.
  `redeploy.sh hermes` is now a container reload (`container rm -f` plus a supervisor
  recreate), not an in-guest `nixos-rebuild switch`; `remint-hermes-authkey.sh` re-encrypts
  the per-host sops bundle, wipes `hermes-ts-state`, and restarts the container instead of
  disk-replacing a VM; and the `yclaw` CLI (`status`/`doctor`/`logs`/`ssh`/`restart`/`wait`/
  `onboard`) drives hermes through `container exec` and host-side checks (the last-ok marker,
  `container logs`) rather than `tailscale ssh` + systemd + `sudo`.
- The model plane moved from the metal guest to the host. `yasyf-home` now serves
  rapid-mlx behind an **idle-unload activator** (`athome serve activator`,
  tailnet-IP `:8000` — health and `/v1/models` answer locally without waking the
  model; the ~20 GB child is reaped after 30 idle minutes) and the granite-speech
  STT on `:8765` (~86 tok/s on-host vs 17.9 in-guest). metal's `rapid-mlx` and
  `mlx-audio` daemons became thin **socat relays** binding metal's tailnet IP and
  forwarding to the host, so hermes keeps calling `metal:8000`/`metal:8765`
  unchanged — hermes gets no tailnet grant to the host. `setup.sh host-serving`
  (re)installs the host stack; `just resize-metal` shrinks the live guest
  48 → 8 GB / 10 → 2 vCPU with an 800x600 display (`packer/metal.pkr.hcl` carries
  the new literals for fresh builds), and metal's display now sleeps after one
  idle minute — an awake framebuffer costs the host ~20% of a core in
  `ParavirtualizedGraphicsGPUTask` frame encodes, a sleeping one 0% (the
  resolution shrink alone measured no reduction).
- `scripts/build-hermes-image.sh`: builder-VM disk default 80 → 140 GB. A day of image
  builds fills 80 GB even after an in-guest store GC (hit twice on 2026-07-13); `tart set`
  only grows, so existing builders pick the new size up on the next run.
- The hermes disk image is built with **systemd-repart** instead of nixos-generators'
  `raw-efi` format. `raw-efi` runs nixpkgs' `make-disk-image` inside a KVM VM
  (`requiredSystemFeatures = ["kvm"]`), and GitHub's `ubuntu-24.04-arm` runners have no
  `/dev/kvm`, so the `build-images` workflow had never passed; repart runs `unshare` +
  `fakeroot` in the plain Nix sandbox with no KVM and no VM, so CI builds the image now.
  The bootloader moves GRUB → **systemd-boot** — its config is declaratively seedable,
  where GRUB's was generated inside the make-disk-image VM — and `nixos/image.nix`
  hand-seeds the ESP (the loader binary at both the EFI removable and systemd paths, a
  generation-1 loader entry, and `/nix-path-registration` for first-boot store-DB
  registration). The `nixos-generators` flake input is dropped, and the local
  `scripts/build-hermes-image.sh` fallback drops its `--nested` KVM path. The published
  `hermes-<ver>.img.zst` asset keeps its name and zstd format. The workflow's genericity
  guard is retuned for the real closure so its first CI run passes: the image-byte scan now
  requires the full 58-char `AGE-SECRET-KEY-1` body, drops the `AKIA…` and `BEGIN … PRIVATE
  KEY` shapes (a binary-coincidence and a dependency-test-vector false-positive magnet that a
  line-oriented grep can't tell from a real leak), and allowlists the two all-`x` doc
  placeholders via `.github/genericity-allowlist.txt`; the store-path-name scan and the
  `GENERICITY_BLOCKLIST` extension point are unchanged.
- metal's LLM daemon swapped from omlx to rapid-mlx 0.10.9: 25.9 tok/s decode vs omlx's 8.6
  on the same weights and VM. The KV cache is pinned to int8 over rapid-mlx's int4 default
  (tool-call fidelity on the agent lane), and pflash is off — it lossily compresses prompts
  (measured 2994 → 2304 tokens), unacceptable for tool calling. Prefix caching is a no-op on
  the hybrid GatedDeltaNet model in both engines' disk caches, so omlx's ~4 s warm-context
  reuse is traded for the ~3× decode. `nixos/models.nix` now carries the real slashed HF id
  (`unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit`) instead of omlx's `--`-mangled form; the model
  loads at startup (~101 s) and stays resident — no idle-TTL unload.
- The metal VM is sized at 48 GB RAM (`packer/metal.pkr.hcl`). An interim shrink to 32 GB
  (~26 GB GPU wired cap) measured out untenable in the 2026-07 qmlx/Rapid-MLX evaluation —
  a resident 20 GB model thrashes the cap (0.025 tok/s, a macOS kernel-panic warning) and
  omlx only fit by idle-unloading — so 48 GB (~42 GB cap) is restored, with headroom for
  the model, KV cache, and the co-resident STT model. The live VM was resized in place
  (`tart set metal --memory 49152`); the wired cap derives from guest RAM automatically.
- Renamed the cliproxy inbound-bearer secret from `aperture/static-key` /
  `APERTURE_STATIC_KEY` to `cliproxy/api-key` / `CLIPROXY_API_KEY` across the manifest,
  metal.nix + its cliproxy config template placeholder, hermes' `key_env`, `secrets.sh`,
  `smoke.sh`, and the docs — the "aperture" name was a leftover from the retired hosted
  router. The key value is unchanged (no client re-auth). `secrets.sh` fails loud if the
  old override name is set in `.env`.
- metal's per-user-agent debloat now uses the session-independent `user/<uid>` launchctl
  domain instead of `gui/<uid>`: metal is headless (no Aqua session), so every `gui/`
  operation failed `125: Domain does not support specified action` and the agents were
  never disabled. `validate-hardening` §8 reads the same domain.
- metal's launchd daemons are converted to `/bin/wait4path` + the shared wait lib.
  wait4path (the primitive nix-darwin's own `nix-daemon` plist uses) guards the late
  `/nix` APFS mount so no daemon fast-fails into launchd's penalty box at cold boot; the
  hand-rolled waitNix trampoline is deleted after three clean cold-boot gates (~25 s from
  power-on to the node answering on the tailnet). virtiofs sub-paths, secrets, and sockets
  keep the bounded `wait.sh` waits (wait4path wakes only on mount events). The provision and
  boot-setup oneshots use `KeepAlive.SuccessfulExit = false` so they relaunch until they exit 0;
  `ThrottleInterval` stays at the 10 s default.
- The `metal-pf-refresh` and `bb-pf-refresh` pf-anchor daemons are resident `KeepAlive = true`
  loops that self-pace with `sleep 300`, not `StartInterval = 300` oneshots: on macOS Tahoe the
  StartInterval timer silently stopped firing (the job still exits 0 when kickstarted — only the
  timer died), while launchd's process-liveness KeepAlive stays reliable. The per-tick anchor body
  is unchanged and runs as a child under `|| true` so its exit never kills the loop. Both are now
  `RunAtLoad = true`: on bluebubbles (no separate boot-setup daemon) the first iteration owns boot
  pf bring-up; on metal `metal-boot-setup` still owns boot bring-up and the loop's first pass is a
  redundant-but-idempotent re-scope. `machines.json` marks both `oneshot: false` so `yclaw status`
  renders them healthy via `state == "running"`.
- `HOME` is always the real user home; no daemon overrides it to a share anymore.
  agent-vault takes its state root from `AGENT_VAULT_HOME` (a state-dir override added by
  `pkgs/agent-vault-state-dir.patch` — same on-disk layout, zero data migration), so the
  `agentvault` virtiofs share is a state directory, not an identity.
- `tailnet/policy.hujson`'s SSH rule is `action: accept` (applied live): check-mode
  (`action: check`) walls silently hang every scripted `tailscale ssh`, which is the
  fleet's only management path.
- The justfile is thinned to orchestration entrypoints: `destroy`, `nuke`, and `smoke`
  moved to `scripts/{destroy,nuke,smoke}.sh` on the shared lib.
- `bluebubbles-setup.sh` loads its pf anchors through the shared `install_pf_anchor` —
  targeted `pfctl -a <name> -f` only, never a full `/etc/pf.conf` reload (which flushes
  the vmnet NAT anchors the VMs need).
- Guest auto-login is per-node in the packer builds (`VM_AUTOLOGIN`, required): `metal`
  drops the kcpassword blob and the auto-login key entirely (headless — every service is
  a system daemon), while `bluebubbles` re-establishes auto-login fresh via `sysadminctl`
  (BlueBubbles.app and Messages.app need a logged-in GUI session). The base image's stale
  kcpassword encoded the pre-rotation password, so every boot fired a failed auto-login
  that accrued account lockouts.
- Tailnet nodes are now **persistent** (non-ephemeral), so the always-on stack survives a
  host sleep, reboot, or network blip instead of being stranded off the tailnet. Previously
  `_ts_mint_key` (`scripts/lib/secrets.sh`) minted `ephemeral` auth keys; Tailscale reaps an
  ephemeral node ~30–60 min after it disconnects, and the single-use key is already spent, so a
  reaped `metal`/`hermes` could not rejoin without a human re-mint — and every management path is
  `tailscale ssh`, so the whole stack went dark. The nodes are tagged (`tag:<host>`), and tagged
  devices have key-expiry disabled by default, so they reconnect from on-disk `tailscaled` state
  with no re-auth. The key's redemption window rose from 2 h to 24 h (`expirySeconds`) so a cold
  `just bootstrap` whose packer/hermes/model builds run for hours can't expire it before first
  boot. Because a persistent node no longer self-reaps, teardown and disk-replace now delete the
  old device explicitly: `nuke-tailnet` moved to `scripts/nuke-tailnet.sh` (accepts a node filter),
  `just destroy` deletes the VMs' tailnet registrations, and `scripts/deploy-vm.sh` deletes the old
  `hermes` device before the fresh image joins so MagicDNS keeps the `hermes` name.
- Lower iMessage reply latency. hermes now calls metal's model upstreams directly
  (cliproxy `:8317`, omlx `:8000`) instead of routing through the hosted Aperture
  node, removing a ~0.5 s WAN round-trip per call; cliproxy's `:8317` is `pf`-gated to
  hermes + the host, and hermes presents cliproxy's own static bearer (see Fixed).
  Reasoning effort drops from `medium` to `low` (replies are sent only after the full
  completion, so reasoning time dominates perceived latency). The hermes-agent
  systemd unit gains `TimeoutStopSec=210s` so a graceful drain is not SIGKILLed
  mid-flight.
- Deploy is now a single wizard. `just bootstrap` runs end to end: preflight
  tooling, prompt for the non-secret values (tailnet, GitHub owner, host RAM,
  authorized handles), mint the age key and generate per-VM passwords, encrypt
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

### Fixed
- Host↔fleet Tailscale never landed the sub-ms vmnet-direct path, hairpinning every packet
  (model plane included) through the LAN router's NAT at ~7 ms instead. Root cause
  (packet-proven, source-confirmed at v1.98.5): Darwin `tailscaled` binds its magicsock UDP
  socket to the default interface with `IP_BOUND_IF`, so guest disco arriving on the vmnet
  bridge never reached the socket — the host-pf `:41641` carve-out admitted packets the daemon
  could not hear (upstream analogues: tailscale/tailscale#4270, #10318). `tailnet/policy.hujson`
  now grants the host node `https://tailscale.com/cap/debug-disable-bind-conn-to-interface` via
  `nodeAttrs` (applied live 2026-07-14; one `tailscale debug rebind` on the host activates it),
  and the host-pf comments no longer claim the carve-out alone forces the direct path. Verified:
  all host↔guest legs direct over `192.168.64.x` at 1 ms.
- First-boot swap race on the minimized repart image: `boot.growPartition` is a stage-2 unit
  at the 25.05 pin (`growpart.service` → `systemd-growfs-root.service`), so the 8 GiB
  `mkswap-var-swapfile` dd ran unordered against disk growth and hit ENOSPC on the ~2 GiB-free
  first boot — self-healing on the next reboot, but the first boot came up degraded. hermes.nix
  now orders swapfile creation after `systemd-growfs-root.service`; scratch-VM validated (the
  journal shows mkswap strictly after growfs, and the 8 GiB dd completes on first boot).
- `scripts/remint-hermes-authkey.sh` crashed with `KeyError: 'CLIPROXY_API_KEY'` on every
  disk-replace (`deploy-vm.sh hermes`): hermes's `hermes/env` block gained `CLIPROXY_API_KEY`
  after the script was written, but the key's only home is metal's sops bundle — not the
  keychain the script read. A shared `cliproxy_key_from_metal_bundle` helper
  (`scripts/lib/secrets.sh`) now decrypts it from metal's bundle with the state-store age key
  (never minting fresh, which would desync metal's inbound bearer); `smoke.sh`'s inline copy
  of the same decrypt moved onto the helper.
- The bluebubbles pf host-allowlist (`/etc/pf.anchors/bluebubbles-allowed-hosts`) is now seeded.
  `bb-pf-refresh` scoped the REST ports (443 + 1234) to hermes plus the bare IPv4s in that file,
  but no script ever wrote it, so the operator host was silently dropped (only hermes was admitted).
  `onboard.sh` and `redeploy.sh` resolve this host's tailnet IP HOST-side (the guest's own
  `tailscale ip -4` is bluebubbles' address, not the operator's) and forward it as
  `BB_ALLOWED_HOST_IP` over the guest_pipe env; `bluebubbles-setup.sh` validates it as a bare IPv4
  and writes it under `umask 077`, mirroring bootstrap.sh's `metal-allowed-hosts` write.
- hermes model-plane 401s. cliproxy **enforces** its inbound API-key allowlist on `:8317`
  (verified: a bearerless call 401s even on metal's loopback), but hermes's model plane
  was configured with no bearer per "the tailnet is the auth". The gpt-5.5 primary and
  the gemini fallback now carry `key_env = "APERTURE_STATIC_KEY"` (the sops name is
  historical: it is cliproxy's own allowlist entry, not an Aperture credential), so
  hermes presents the bearer itself.
- `tailscaled install-system-daemon` now runs only on the FIRST install.
  `install-system-daemon` terminates a running tailscaled and its reload silently fails,
  so metal's boot-setup oneshot was cutting the node off the tailnet on every redeploy.
- agent-vault no longer crash-loops on a stale pidfile. The pidfile lives on the
  persistent `agentvault` share, so it survives reboots; a PID-reuse match made the
  broker refuse to start ("already running") forever. The wrapper clears it before exec —
  launchd is the single-instance supervisor.
- `metal-redeploy` is invoked by its absolute store path over `tailscale ssh` — root's
  remote login shell has no nix directories on `PATH`, so the bare name was "command not
  found".
- `deploy-vm.sh` drains the launchd bootout before re-bootstrapping the runner.
  `bootout` is async; bootstrapping the same label while it is still stopping races
  launchd into "5: Input/output error" (`bootout_drain` in `scripts/lib/launchd.sh`).
- `manifest.sh` fails loud with an explicit error when `jq` is missing or a queried key
  is absent, instead of emitting an empty string a consumer would happily interpolate.

### Removed
- The `tart`-hosted hermes VM and its deploy path. The `com.yclaw.tart-hermes` runner is
  gone from `setup.sh`, `destroy.sh`, and `bootstrap.sh`; the in-guest `nixos-rebuild`
  redeploy flow for hermes gives way to the container reload; and `deploy-vm.sh` — the
  hermes disk-replace builder — is retired to a stub, since hermes now ships as an OCI
  image rather than a VM disk.
- The in-guest model install on metal: the rapid-mlx and mlx-audio venvs (deleted
  at activation, the same idiom as the omlx retirement), the `python@3.14` brew,
  the python-framework application-firewall entries, and the `hfhub`/`mlxaudio`
  virtiofs shares — metal keeps only `metalsecrets`, `agentvault`, `cliproxy`, and
  `repo`.
- The Aperture/`ai` model-routing deploy path. `nixos/ai.nix`, the `just deploy-ai`
  recipe, the `aperture-config` flake outputs, and `just smoke`'s `http://ai`
  model-plane curl are gone: hermes calls metal's cliproxy (`:8317`) and omlx
  (`:8000`) directly over the tailnet, so the model plane goes direct to
  `metal:8317` and the hosted Aperture node is out of the hot path — no longer built
  or deployed. The `aperture/static-key` sops secret stays: it is cliproxy's own
  inbound API-key allowlist entry (the name is a misnomer), not an Aperture credential.
- `scripts/uninstall-nix.sh` and its `docs/DEPLOY.md` "Migrating an existing
  deployment" section. Stale pre-migration artifacts from when the macOS host still
  ran Nix; the host is now provisioned by `scripts/setup.sh` alone.
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
- `docs/SECURITY-HANDOFF.md`. A dated internal security-hardening handoff, not canonical
  project documentation and not fit for a public repo; its durable architecture and
  security rationale is covered by `docs/ARCHITECTURE.md` and `docs/DEPLOY.md`.

### Security
- The shared tailnet ACL is tightened from allow-all to `autogroup:member` plus
  explicit fleet grants (hermes → metal service ports, the hermes ↔ bluebubbles
  webhook legs, metal → `yasyf-home` model ports; mirrored in
  `tailnet/policy.hujson`), and the host gained a pf anchor (`setup.sh host-pf`,
  `com.apple/000.yclaw.host`) that passes only metal to the host model ports and
  shuts the vmnet weak-host side-door (a fleet VM reaching any host-bound service
  via the `192.168.64.1` bridge gateway), keeping DHCP/DNS and a WireGuard
  `:41641` carve-out open. Applied and verified live 2026-07-13/14.
- `metal` is hardened to SIP-on and tailnet-only. It is the sole credential
  custodian (CLIProxyAPI, agent-vault, and the model-port relays run inside it),
  locked down with a `pf` anchor plus the application firewall, with
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
  rate/concurrency limits are set and locked. On the model plane, `metal`'s cliproxy
  `:8317` is both `pf`-gated to `hermes` + the host (the gate below) and enforces its
  own inbound static bearer, which `hermes` presents via `key_env` (see Fixed);
  the retired per-caller `HERMES_CLIPROXY_KEY` is gone.
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
- **Docker-proxy screens mount destinations, closing a socket-relay escape.** The
  create-body screen previously checked only bind/mount sources; it now also rejects
  any bind or mount whose destination basename is `docker.sock`. A Docker-API shim
  (socktainer, on the Apple-`container` sandbox path) transparently relays such a
  mount to its own unfiltered API — a full host escape — regardless of the source.
  Bind specs are parsed exactly as the shim parses them (`:`-split dropping empty
  segments) and non-ASCII bind/mount paths are rejected outright, so byte-split vs
  grapheme-cluster parser differentials can't smuggle a `docker.sock` target past the
  screen. Three adversarial review passes found and closed two such differentials.
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
  member metal cannot name-resolve) — and drops every OTHER tailnet node and
  the sibling vmnet-LAN guests. The scope is resolved at activation, at every boot, and on a 5-minute
  refresh, never baked into the build: if hermes is rebuilt and its IP changes, the next refresh
  re-scopes with no `darwin-rebuild`. It never fails open — a transient hermes unresolve reuses the
  sticky last-known IP, the anchor is written atomically and only persisted after the kernel accepts
  it, and with no resolvable source the anchor is fully CLOSED (loopback only), never the whole tailnet.

[Unreleased]: ../../commits/main
