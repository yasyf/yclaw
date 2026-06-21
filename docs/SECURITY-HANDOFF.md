# Security hardening — handoff

Status of the June 2026 per-VM isolation + audit-remediation work, and everything
still open. The implemented work is on `main` (commits `4a6a34f..572f4d1`, pushed).
This document is the runbook for finishing it.

## What is done (committed + statically verified)

Verified here means `nix eval` of both configs, `bash -n` on every touched script,
a real age/sops cross-decrypt proving isolation, and resolved image digests. It does
NOT mean live-tested on the VMs — see [Live validation](#live-validation-required).

| Area | Change | Finding |
|------|--------|---------|
| Crypto | Per-VM age keypairs + per-host bundles; `nixos/secrets-manifest.json` is the single source of truth; host age key removed | core, H1 |
| Shares | metal gets narrow per-need virtiofs shares, not the whole state tree | H1 |
| Tailnet | `tailnet/policy.hujson` ACL + per-node ephemeral tagged keys via OAuth client | H3, H4 |
| Credential plane | agent-vault proxy token minted from metal at bootstrap; distinct rotatable hermes cliproxy key; proxy rate limits | H5, L1, M9 |
| Network | metal pf fail-loud; bluebubbles `:1234` firewalled | H2, M3 |
| Confinement | gVisor `runsc` default docker runtime (partial — see C1) | H6 |
| Hygiene | keychain auto-lock; config.json `0600`; builder + base images digest-pinned | M4, M6, M7, M8 |

---

## Part A — Tailscale setup (drive via Chrome)

Bootstrap will not succeed until this is done. It is purely console + secret
placement; no repo code changes. A Chrome-driving session (or you) does it.

### A0. Preconditions
- Be signed into the Tailscale admin console in the Chrome profile the automation drives.
- Know the tailnet name (e.g. `tailXXXX.ts.net` or the org domain) — visible in the console URL / DNS page. This is `TS_TAILNET`.

### A1. Apply the ACL policy (must happen BEFORE any node advertises a tag)
1. Open `https://login.tailscale.com/admin/acls/file`.
2. Replace the editor contents with `tailnet/policy.hujson` from this repo (it defines `tag:hermes`/`tag:metal`/`tag:bluebubbles`, the default-deny grants, and the `ssh` rule that keeps `tailscale ssh` working — do not drop that rule).
3. Save. The console validates HuJSON; fix any tailnet-specific reference (e.g. if `autogroup:admin` needs to be a concrete user on this tailnet).

Alternative (instead of pasting): set the three GitHub secrets in A3 and let
`.github/workflows/tailscale-acl.yml` apply it on the next push to `main`.

### A2. Create the node-key OAuth client (for `secrets.sh` key minting)
1. Open `https://login.tailscale.com/admin/settings/oauth`.
2. Generate an OAuth client with the **`auth_keys` write** scope, and attach the tags `tag:hermes`, `tag:metal`, `tag:bluebubbles` to the client (a client can only mint keys for tags it owns; tagOwners in A1 already list `autogroup:admin`).
3. Capture the client **id** and **secret** — the secret is shown once in a modal.
4. Place them in the host's dedicated yclaw keychain (the names `secrets.sh` reads):
   ```sh
   security add-generic-password -U -a "$USER" -s yclaw-ts-oauth-client-id \
     -l 'yclaw Tailscale OAuth client id' -w '<CLIENT_ID>' "$HOME/Library/Keychains/yclaw.keychain-db"
   security add-generic-password -U -a "$USER" -s yclaw-ts-oauth-client-secret \
     -l 'yclaw Tailscale OAuth client secret' -w '<CLIENT_SECRET>' "$HOME/Library/Keychains/yclaw.keychain-db"
   ```

### A3. Create the ACL-workflow OAuth client (for CI) and set GitHub secrets
1. Same OAuth page: generate a client with the **`policy_file` write** scope (separate client = least privilege; one client with both scopes also works).
2. Set the repo secrets (via `gh` or the GitHub settings UI):
   ```sh
   gh secret set TS_API_CLIENT_ID     --body '<POLICY_CLIENT_ID>'
   gh secret set TS_API_CLIENT_SECRET --body '<POLICY_CLIENT_SECRET>'
   gh secret set TS_TAILNET           --body '<tailnet-name>'
   ```

### A4. Chrome-automation notes
- Start with `tabs_context_mcp`; open a NEW tab (don't reuse) and `navigate` to the URLs above.
- The OAuth-secret reveal is a one-time modal — `read_page` it and capture the secret before closing.
- Do NOT trigger native `confirm()`/`alert()` dialogs (they freeze the extension). The OAuth/ACL flows are normal form pages; "Generate" and "Save" are page buttons, safe.
- The client secret cannot be re-shown. If it scrolls past, delete the client and regenerate.

### A5. Order of operations
Apply ACL (A1), then create the clients so they can own the tags (A2/A3), then run
`just bootstrap`. A node advertising `tag:X` before the tagOwners exist is rejected
by `tailscale up`.

---

## Live validation (required — needs the running VMs)

None of this can be checked from a dev box; run it on the host after `just bootstrap`.

- [ ] **Isolation:** on metal, the hermes bundle must NOT decrypt with metal's key — `SOPS_AGE_KEY_FILE=<metal key> sops -d hosts/hermes/secrets.sops.yaml` fails; with hermes's key it succeeds and shows only `tailscale/authkey` + `hermes/env`. Host has no `/var/lib/sops-nix/key.txt`.
- [ ] **Share boundary:** inside the metal guest, `ls "/Volumes/My Shared Files/"` shows only metal's narrow shares; `hosts/hermes` and other hosts' keys are not mountable.
- [ ] **Credential plane (L1):** a brokered tool call (Exa/Honcho/OpenAI) from hermes returns **200, not 407**; `~/.hermes/.env` ends with `HTTPS_PROXY=http://av_agt_…:hermes@metal:14322`; `metal:8317/:8000/:8765` (in NO_PROXY) still go DIRECT.
- [ ] **Confinement:** `docker info | grep Runtime` on hermes shows `runsc`; a real code-exec workload (the `nikolaik/python-nodejs` image) runs under runsc without syscall-compat breakage.
- [ ] **Tailnet:** `tailscale status` shows each node carrying its tag; an untagged tailnet peer is denied `:8317`/`:14321`.
- [ ] **CI:** the `tailscale-acl.yml` run is green once A3 secrets are set.

### Migration of in-flight VMs
Seeding is only-if-missing, so existing VMs keep the OLD global key on a plain rebuild.
- Re-run secret collection to mint per-host keys/bundles + per-node tailnet keys (needs the A2 OAuth client). Remove the now-unproduced `~/.yclaw/state/{age/key.txt,secrets.sops.yaml,vm-secrets/}`.
- metal: remove stale `/var/lib/sops-nix/key.txt` + old bundle before `darwin-rebuild`.
- hermes: re-seeds on `just deploy hermes` (disk-replace); deploy via boot+reboot, not `switch`.
Full steps: `docs/DEPLOY.md`, "Migrating an existing deployment".

---

## Part C — Remaining code work (design, not yet implemented)

### C1 — Full H6: remove the agent's docker-group root-equivalence
gVisor `runsc` is the default runtime (workloads sandboxed), but `hermes` is still in
the `docker` group, so a prompt-injected agent can `docker run --runtime=runc -v /:/host`
to reach VM root. Phase-1 per-host keys bound the blast radius (a rooted hermes
decrypts only its own bundle, not metal's upstream keys), but root-equivalence remains.

Rootless docker is blocked: the `hermes` user is `isSystemUser` with a kernel-allocated uid, so
there is no `/run/user/<uid>` for the rootless socket and the rootless module is gated
on a non-root login user.

**Recommended: a docker-socket-proxy.** Run a proxy (e.g. `tecnativa/docker-socket-proxy`
or a NixOS equivalent) exposing a filtered docker API on a unix socket; remove
`users.users.hermes.extraGroups = ["docker"]`; set `DOCKER_HOST=unix:///run/docker-proxy.sock`
in the hermes-agent unit env. Deny the dangerous surface (`POST /containers/create` with
`HostConfig.Binds`/`Privileged`/host-mount, `--runtime` override, `/exec` to privileged
containers). The hard part: the agent legitimately creates containers with a workspace
bind mount, so the allowlist must permit that one mount path while denying host-root
mounts — this needs iteration against the real code-exec tool. Files: `nixos/hermes.nix`.
Verify: nix eval + a live `docker run -v /:/host` from a code-exec session must be
refused while normal code-exec still works.

### C2 — M2: bind metal's model services to the tailnet, add app auth
omlx `:8000` and STT `:8765` bind `0.0.0.0` with no app-layer auth (STT's key is the
literal `"local"`). The Phase-2 ACL + pf now gate WHO reaches them, so this is
defense-in-depth. Two parts, both needing the tailnet IP resolved at runtime:
- Bind to the tailnet interface: in the omlx/STT wrappers (`darwin/metal.nix`), resolve
  `tailscale ip -4` after tailscaled is up and pass it as the bind host instead of
  `0.0.0.0` (handle the startup race — wait for tailscale, like the existing sops waits).
- App auth: `darwin/stt-server.py` is our code — add an optional bearer check gated by an
  env var; have hermes present it (another small secret to plumb via the manifest). omlx
  is third-party (`omlx serve`) — confirm whether it supports an API key; if not, it stays
  network-gated (document). Risk: a wrong bind makes the service unreachable — validate live.

### C3 — M1: vault static keys on agent-vault argv (upstream-limited)
`darwin/metal.nix` runs `vault credential set --vault hermes $(cat staticKeysFile)`; the
keys land in argv (visible in `ps`). agent-vault's `credential set` only accepts
`KEY=VALUE` positional args — no stdin/`--file` — so there is no clean fix without an
agent-vault API rewrite or an upstream feature. Low practical risk (same `admin` user,
brief provision window, values already readable via `/run/secrets`). Recommend: file an
upstream request for stdin support, or rewrite provisioning to use the credentials HTTP
API with a file-bodied `curl -d @file`. Left as-is for now.

---

## Part D — Open decisions (need your input — cannot be guessed)

### D1 — M9: narrow the Google OAuth scopes
`scripts/connect-google-oauth.py` requests broad scopes: `gmail.modify`, `calendar`,
`drive`, `spreadsheets`, `documents`, `presentations`, `tasks`. A compromised agent could
use all of them. Narrowing blindly breaks features, so tell me which the agent actually
uses and I'll cut the rest (e.g. drop `drive`/`spreadsheets`/`documents`/`presentations`
if it only does mail + calendar; downgrade `gmail.modify` to `gmail.readonly` if it never
sends). Also consider least-privilege on the BlueBubbles account + rotate-on-compromise.

### D2 — M9: `subagent_auto_approve` / delegation budget
`nixos/hermes.nix` sets `subagent_auto_approve = true`, `max_iterations = 50`,
`max_turns = 90` — no human gate on tool execution. This is by design (autonomous home
agent) and is now partly contained by gVisor; with C1 (socket-proxy) it's well contained.
Decide whether to keep full autonomy or add an approval gate for high-risk tools. Left
as-is pending your call.

### D3 — M5: disable bluebubbles Screen Sharing after bring-up
The bluebubbles VNC pf anchor is intentionally open to the RFC1918 LAN for the one-time
GUI bring-up. After bring-up completes and tailnet access works, disable it on the guest:
`sudo launchctl disable system/com.apple.screensharing` + the ARDAgent
`kickstart -deactivate -stop` (as metal does). This is an operator step, not a code change.

---

## Quick map: status by finding

| # | Finding | State |
|---|---------|-------|
| core,H1 | global key / monolithic bundle / broad share | **done** |
| H2 | pf fail-open | **done** (fail-loud) |
| H3,H4 | tailnet ACL absent / reusable key | **done** in code; needs Part A |
| H5,L1 | hermes bearer / dead custody plane | **done** in code; needs live check |
| H6 | agent = VM root | **partial** (runsc); C1 remains |
| M1 | keys on argv | **won't-fix** (upstream limit) — C3 |
| M2 | omlx/STT no auth | **deferred** — C2 |
| M3,M4 | bluebubbles :1234 / config perms | **done** |
| M5 | bluebubbles VNC RFC1918 | **operator step** — D3 |
| M6 | keychain unlocked | **done** |
| M7,M8 | mutable image tags | **done** (digest-pinned) |
| M9 | broker limits / OAuth scopes / auto-approve | rate limits **done**; scopes+auto-approve — D1/D2 |
