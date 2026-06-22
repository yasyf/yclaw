# Security hardening — handoff

Status of the June 2026 per-VM isolation + audit-remediation work as of 2026-06-21.
Implemented work is on `main`. Decisions made along the way are recorded as `cc-notes`
(`cc-notes log --tag design`); this document is the human-readable summary and the
runbook for what is left.

"Verified" below means static checks done on a dev box: `nix eval` of both configs,
`nix build` of the Go services (tests run in `checkPhase`), `bash -n`, a real age/sops
cross-decrypt, resolved image digests. It does NOT mean live-tested on the VMs — see
[Live validation](#live-validation-required-needs-the-running-vms).

## What is done (committed + statically verified)

| Area | Change | Finding |
|------|--------|---------|
| Crypto | Per-VM age keypairs + per-host bundles; `nixos/secrets-manifest.json` is the single source of truth; host age key removed | core, H1 |
| Shares | metal gets narrow per-need virtiofs shares, not the whole state tree | H1 |
| Tailnet | yclaw tags + admin-SSH added to the live ACL; per-node ephemeral tagged keys via an OAuth client (in the keychain) | H3, H4 |
| Credential plane | agent-vault proxy token minted from metal at bootstrap; distinct rotatable hermes cliproxy key; proxy rate limits | H5, L1, M9 |
| Network | metal pf fail-loud + scoped to hermes + host runtime-resolved IPs; bluebubbles `:1234` firewalled; omlx/STT bound to the tailnet IP, not `0.0.0.0` | H2, H3, H4, M2, M3 |
| Confinement | gVisor `runsc` default runtime **+** a default-deny Docker-socket proxy; hermes dropped from the docker group | H6 |
| Hygiene | keychain auto-lock; config.json `0600`; builder + base images digest-pinned | M4, M6, M7, M8 |

## Done this session (2026-06-21)

- **M2 — model/STT services bound to the tailnet IP.** `darwin/metal.nix` resolves
  `tailscale ip -4` at wrapper start (polls for tailscaled, fail-loud after 120s) and
  binds omlx `:8000` + STT `:8765` to it; `darwin/stt-server.py` honours `STT_HOST`
  (default loopback). They no longer listen on the vmnet LAN even if pf is down.
- **M2 — STT app-auth dropped as unnecessary.** STT is an internal tailnet service; the
  ACL (the `tag:hermes` to `metal:8765` grant) + pf are the authentication. An app bearer would put a
  needless secret on the agent. The same logic means `HERMES_CLIPROXY_KEY` could later be
  dropped too (rely on the ACL for `:8317`) — a follow-up, not done.
- **H6 — Docker root-equivalence removed.** New `hermes-docker-proxy` (pure-stdlib Go,
  `pkgs/hermes-docker-proxy`): a default-deny proxy in front of `/run/docker.sock` that
  allowlists exactly the agent's code-exec calls and screens every `POST
  /containers/create` body (no host-root binds, privileged, devices, host namespaces,
  runtime overrides, or non-allowlisted caps). hermes is no longer in the docker group; a
  dedicated proxy user owns the real socket and the agent reaches the filtered one via
  `DOCKER_HOST`. **Needs the live test below before it is trusted.**
- **H3/H4 — tailnet ACL applied ADDITIVELY (the deployment tailnet is shared).** The
  tailnet (`tail71af5d.ts.net`) is not dedicated to yclaw: it hosts other production nodes
  (`tag:sprite/gcp/zo/modal`), GCP route auto-approvers, `svc:n8n`, and a default
  **allow-all** rule. The repo's `tailnet/policy.hujson` (default-deny, yclaw-only) and the
  old `tailscale-acl.yml` workflow would have deauthorized those nodes, so:
  - the yclaw `tagOwners` + an admin-SSH rule were added **additively** to the live ACL
    (nothing removed) via the Tailscale API. Backup: `~/yclaw-tailscale-acl-backup.hujson`.
  - the node-key OAuth client (`auth_keys` write, owns the three tags) was created and
    stored in the keychain (`yclaw-ts-oauth-client-id` / `-secret`) — bootstrap can now
    mint tagged keys.
  - `.github/workflows/tailscale-acl.yml` was **removed** (force-replace is unsafe here).
  - **Consequence (closed by the pf gate below):** the tailnet ACL itself stays allow-all, so
    east-west is not restricted at the ACL layer. metal's hermes+host restriction is enforced by
    `pf` instead (next bullet), not by the ACL.
- **metal restricted to hermes + host — pf scoped to RUNTIME-resolved IPs.** pf has no hostname
  matching, so `darwin/metal.nix`'s `metal-pf-anchor` admits ONLY metal's two legitimate consumers
  to the five service ports (`8000/8765/8317/14321/14322`): hermes (resolved by hostname, `tailscale
  ip -4 hermes`) and the host admin machine (its tailnet IP, injected by `bootstrap.sh` over the SSH
  path into `/etc/pf.anchors/metal-allowed-hosts` — the host hits `metal:14321` for the bootstrap CA
  fetch + Google-OAuth admin, and its Mac is an existing tailnet member metal cannot name-resolve).
  Every OTHER tailnet node (sprite/gcp/zo/modal) and the sibling vmnet-LAN guests are dropped. The
  script runs at activation, at every boot (AFTER pf already enforces the persisted anchor, so the
  up-to-120s resolve-wait never opens a window), and on a 5-minute `metal-pf-refresh` that self-heals
  an IP change with no rebuild. It never fails open: a transient hermes unresolve reuses the sticky
  last-known IP, the anchor is written atomically and loaded into the kernel before the file is
  persisted, and with no resolvable source it is fully CLOSED (loopback only), never the whole
  tailnet. This restores the "the tailnet is the auth" premise behind dropping STT app-auth (M2) and
  unblocks dropping `HERMES_CLIPROXY_KEY`. **Host-IP note:** if the host's tailnet IP changes, re-run
  `just bootstrap` (or re-write `metal-allowed-hosts` over `tailscale ssh root@metal`) so the host
  keeps reaching `metal:14321` for OAuth admin.

## Live validation (required — needs the running VMs)

None of this can be checked from a dev box; run it on the host after `just bootstrap`.

- [ ] **H6 / Docker proxy (the new one):** from a real code-exec session, `docker run -v
      /:/host …` (and `--privileged`, `--runtime=runc`) must be **refused**, while normal
      code-exec still works (container create with the `/workspace` bind, exec, image
      pull). Check `journalctl -u hermes-docker-proxy` for `DENY` lines. If a legitimate
      mount source lives outside `/var/lib/hermes`, widen `HERMES_DOCKER_PROXY_BIND_ROOTS`
      in the service env. Confirm `getent group docker` does NOT list `hermes`.
- [ ] **M2 / tailnet bind:** `omlx`/STT answer on `http://metal:8000|8765` from hermes but
      NOT on metal's loopback/vmnet address; `lsof -i :8000 -i :8765` shows the tailnet IP.
- [ ] **Isolation:** on metal the hermes bundle must NOT decrypt with metal's key —
      `SOPS_AGE_KEY_FILE=<metal key> sops -d hosts/hermes/secrets.sops.yaml` fails; with
      hermes's key it succeeds and shows only `tailscale/authkey` + `hermes/env`. Host has
      no `/var/lib/sops-nix/key.txt`.
- [ ] **Share boundary:** inside the metal guest, `ls "/Volumes/My Shared Files/"` shows
      only metal's narrow shares; `hosts/hermes` is not mountable.
- [ ] **Credential plane (L1):** a brokered tool call (Exa/Honcho/OpenAI) from hermes
      returns **200, not 407**; `~/.hermes/.env` ends with `HTTPS_PROXY=http://av_agt_…`.
- [ ] **Tailnet:** `tailscale status` shows each yclaw node carrying its tag; admin
      `tailscale ssh root@hermes` works (the additive ssh rule).

### Migration of in-flight VMs
Seeding is only-if-missing, so existing VMs keep the OLD global key on a plain rebuild.
Re-run secret collection to mint per-host keys/bundles + per-node tailnet keys (needs the
keychain OAuth client), remove the stale `~/.yclaw/state/{age/key.txt,secrets.sops.yaml,
vm-secrets/}`, drop metal's stale `/var/lib/sops-nix/key.txt`, and redeploy hermes via
boot+reboot (disk-replace), not `switch`. Full steps: `docs/DEPLOY.md`.

## Remaining work

### 1. Live validation (you, on the running VMs)
- **pf hermes+host gate (done this session, code-verified — needs the live check):** from a tailnet
  node that is NEITHER hermes NOR this host, `nc -vz metal 8000` (also `8765`/`8317`/`14321`)
  **fails**; from hermes AND from the host it succeeds; `pfctl -a metal -sr` on metal shows pass rules
  for hermes's tailnet IP + the host IP (from `/etc/pf.anchors/metal-allowed-hosts`), NOT
  `100.64.0.0/10`, plus the catch-all `block`. Reboot metal and re-check — the boot setup must
  re-resolve and leave the block rule resident. Logs: `/var/log/metal-pf-refresh.log`,
  `/var/log/metal-boot-setup.{log,error.log}`, and the `metal: pf anchor sources = …` lines.
- **C1 / docker proxy:** `docker run -v /:/host` from a code-exec session must be **refused**
  (`journalctl -u hermes-docker-proxy` shows `DENY`) while normal code-exec works; widen
  `HERMES_DOCKER_PROXY_BIND_ROOTS` if a legit mount source is outside `/var/lib/hermes`;
  `getent group docker` has no `hermes`.
- **C2 / M2:** omlx/STT answer on `metal:8000|8765` from hermes, not on metal's loopback/vmnet IP.
- Isolation cross-decrypt, share boundary, credential plane (200 not 407), tailnet tags +
  admin SSH — the full checklist above.

### 2. Decisions (you)
- **D1 — Google OAuth scopes.** `scripts/connect-google-oauth.py` requests `gmail.modify`,
  `calendar`, `drive`, `spreadsheets`, `documents`, `presentations`, `tasks`. Evidence: the
  upstream `google-workspace` skill uses gmail (send/search/reply/modify-labels), calendar,
  drive (upload/share), sheets, and docs. If you do not use Slides/Tasks, drop
  `presentations`/`tasks`; keep `gmail.modify` (the skill sends + relabels). Narrowing reduces
  capability and needs a re-consent run, so it is left to you.
- **D2 — `subagent_auto_approve` / delegation budget.** `nixos/hermes.nix` keeps
  `subagent_auto_approve = true`, `max_iterations = 50`, `max_turns = 90` (autonomous by
  design, now contained by gVisor + the socket proxy). Decide whether to add an approval gate
  for high-risk tools.
- **D3 — disable bluebubbles Screen Sharing after bring-up.** Once tailnet access works,
  `sudo launchctl disable system/com.apple.screensharing` + the ARDAgent `kickstart
  -deactivate -stop` on the guest (as metal does).

### 3. Code follow-ups (I implement on request)
- **Drop `HERMES_CLIPROXY_KEY` (now unblocked — metal restricted to hermes + host).** cliproxy
  `:8317` is now reachable only by hermes + the host (the pf gate above), so for hermes's model
  traffic the bearer is redundant for access by the same "tailnet is the auth" logic. Removing it
  means dropping it from `hermes/env` + the manifest + the model `key_env` AND relaxing cliproxy's
  required-key in `darwin/metal-cliproxyapi-config.yaml`. Optional — you may keep the key for caller
  distinction / independent rotation.
- **Rootless Docker (construction-level H6).** The socket proxy contains H6; the stronger fix
  is rootless docker so a daemon escape lands unprivileged. Blocked today by the upstream
  module's `isSystemUser` hermes with no login session / static uid; pinning the uid +
  subuid/subgid + lingering would unblock it. The socket proxy also has a residual symlink
  TOCTOU (see `pkgs/hermes-docker-proxy/policy.go`).
- **C3 — M1: vault static keys on agent-vault argv (won't-fix).** `vault credential set` only
  accepts `KEY=VALUE` positional args, so the keys land in `ps`. Low practical risk (same
  `admin` user, brief provision window). Upstream stdin/`--file` support or a credentials-HTTP-
  API rewrite would fix it.

## Quick map: status by finding

| # | Finding | State |
|---|---------|-------|
| core,H1 | global key / monolithic bundle / broad share | **done** |
| H2 | pf fail-open | **done** (fail-loud) |
| H3,H4 | tailnet ACL absent / reusable key | **done** (tags + per-node keys added additively; hermes+host east-west now enforced by the runtime-resolved pf anchor) |
| H5,L1 | hermes bearer / dead custody plane | **done** in code; needs live check |
| H6 | agent = VM root | **done** in code (runsc + socket proxy); needs live test; rootless = follow-up |
| M1 | keys on argv | **won't-fix** (upstream limit) |
| M2 | omlx/STT no auth | **done** (tailnet-bound; metal now restricted to hermes + host via the runtime-resolved pf anchor, so "the tailnet is the auth" holds) |
| M3,M4 | bluebubbles :1234 / config perms | **done** |
| M5 | bluebubbles VNC RFC1918 | **operator step** — D3 |
| M6 | keychain unlocked | **done** |
| M7,M8 | mutable image tags | **done** (digest-pinned) |
| M9 | broker limits / OAuth scopes / auto-approve | rate limits **done**; scopes+auto-approve — D1/D2 |
