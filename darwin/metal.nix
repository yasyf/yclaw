# nix-darwin module for the `metal` macOS guest VM. Applies IN-GUEST with
# `darwin-rebuild switch --flake <repo>#metal`.
#
# metal is the SIP-ON, MAX-LOCKED credential + AI services VM — one of three guests on the
# bare-macOS host (alongside `bluebubbles` and `hermes`), with its own tailnet node. It holds
# ALL credentials and serves four services over the tailnet (the two model ports are thin socat
# relays to the host model plane on yasyf-home — hermes keeps calling metal:8000/8765 unchanged):
#   rapid-mlx   :8000   relay -> the host athome activator (idle-unload Qwen)
#   mlx-audio   :8765   relay -> the host STT (Parakeet TDT 0.6b v2, English-only)
#   cliproxy    :8317   CLIProxyAPI, Codex/Gemini OAuth -> static key
#   agent-vault :14321  credential broker API  + :14322 transparent MITM proxy
#
# Persistent state lives on NARROW per-need virtiofs shares (the host shares only the slices of
# ~/.yclaw/state that metal owns): "/Volumes/My Shared Files/metalsecrets" (metal's age key + its
# own secrets bundle), plus agentvault / cliproxy for the runtime dirs. metal
# never sees hosts/hermes/ or state/hermes/. The repo is shared read-only at
# "/Volumes/My Shared Files/repo". The guest admin user is `admin` (home /Users/admin).
#
# metal runs NO iMessage and NO BlueBubbles: those live on the separate `bluebubbles` guest,
# which keeps SIP OFF (its Private API needs it) precisely so metal can stay SIP-ON and maximally
# locked down. metal holds the credentials; bluebubbles and hermes hold none.
#
# Lockdown posture: SIP on, Gatekeeper on, app firewall + a pf tailnet-only anchor, every
# sharing/remote-access surface off, and OpenSSH Remote Login off — the ONLY admin path is
# `tailscale ssh root@metal`. In-guest auto-login is DROPPED by packer (VM_AUTOLOGIN=drop, the
# account-lockout fix) — it is NOT required for the GPU, since the services run as UserName=admin
# daemons and MLX/Metal works headless (verified). FileVault is NOT used regardless. Sensitive state
# lives on the host's ~/.yclaw/state, backed up encrypted off-box; the vault is also encrypted
# at rest, and every service is bound tailnet-only by the pf anchor + app-firewall allowlist.
#
# Ports the host.nix launchd/pf/app-firewall patterns and the vault.nix agent-vault server +
# provisioning oneshot (systemd -> launchd). Sources: darwin/host.nix, nixos/vault.nix,
# nixos/common.nix, the metal-vm-service-commands memory file.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  manifest = builtins.fromJSON (builtins.readFile ../nixos/secrets-manifest.json);
  machinesManifest = builtins.fromJSON (builtins.readFile ../machines.json);

  adminUser = "admin";
  home = "/Users/${adminUser}";
  logs = "${home}/Library/Logs";

  # /nix is a SEPARATE Determinate-Nix APFS volume, mounted late at boot. A RunAtLoad LaunchDaemon can
  # win the race and try to exec its /nix-store program before /nix is mounted; launchd reports "could
  # not execute program" and exits the service 78 (via xpcproxy) → "respawning too quickly" penalty box
  # → the service stays DOWN across a reboot until a human kicks it. wait4path prefixes each daemon's
  # ProgramArguments with /bin/wait4path — the sanctioned primitive for exactly this race (it lives on
  # the sealed system volume, always present at boot, and blocks on a kqueue EVFILT_FS watch until the
  # path materializes; nix-darwin's own org.nixos.nix-daemon plist uses the same
  # `sh -c "/bin/wait4path /nix/store && exec …"` shape) — so no daemon fast-fails on the /nix race
  # and a reboot (incl. the auto-security-update reboots and `just redeploy`) self-heals. wait4path
  # has NO timeout and wakes only on mount events, so it guards ONLY /nix store paths — NEVER virtiofs
  # sub-paths (tart's per-share paths materialize on stat under one AppleVirtIOFS automount, no FS
  # event) or sockets; those keep the bounded waits in mkDaemonPreamble below.
  wait4path =
    args:
    let
      prog = lib.escapeShellArg (builtins.head args);
      rest = builtins.tail args;
    in
    [
      "/bin/sh"
      "-c"
    ]
    ++ (
      if rest == [ ] then
        [ "/bin/wait4path ${prog} && exec ${prog}" ]
      else
        [
          ''/bin/wait4path ${prog} && exec ${prog} "$@"''
          "_"
        ]
        ++ rest
    );

  # Shared bounded-wait helpers (scripts/lib/wait.sh — self-contained by design), embedded verbatim
  # into the wrappers below. TAILSCALE is wait.sh's binary seam: launchd hands wrappers no brew PATH.
  waitLib = builtins.readFile ../scripts/lib/wait.sh;

  # Narrow per-need virtiofs shares (scripts/setup.sh mounts each at /Volumes/My Shared Files/<name>):
  # metalsecrets holds ONLY metal's age key + its own secrets bundle, so metal never sees
  # hosts/hermes/ or state/hermes/. The runtime dirs are the only other state metal owns.
  metalSecrets = "/Volumes/My Shared Files/metalsecrets";

  # The broker's logical vault NAME (vault.nix: the `vault:` key is "hermes").
  vaultName = "hermes";
  # agent-vault's state root: it keeps everything under $AGENT_VAULT_HOME/.agent-vault (the
  # state-dir override added by pkgs/agent-vault-state-dir.patch) — the same on-disk layout it
  # wrote when HOME pointed at the share, so zero data migration.
  vaultStateDir = "/Volumes/My Shared Files/agentvault";
  servicesYaml = ../nixos/vault-services.yaml;

  # Share mountpoints the daemon preambles block on at boot (scripts/setup.sh mounts each here).
  cliproxyShare = "/Volumes/My Shared Files/cliproxy";
  repoShare = "/Volumes/My Shared Files/repo";

  # The RESOLVED socat executable: bin/socat is a symlink to bin/socat1, and the app firewall keys
  # entries on the resolved binary's identity — `--add .../bin/socat` registers NOTHING while the
  # running process is socat1, so ALF silently swallows the relay's inbound (observed live
  # 2026-07-14: TCP handshakes completed via the listen backlog but accept() never fired). The
  # wrappers and both firewall loops all use this one path so exec target == allowlisted binary.
  socatBin = "${pkgs.socat}/bin/socat1";

  # Decrypted sops secret paths (sops-nix installs to /run/secrets/<name>).
  masterPasswordFile = config.sops.secrets."vault/master-password".path;
  staticKeysFile = config.sops.secrets."vault/static-keys".path;
  cliproxyKeyFile = config.sops.secrets."cliproxy/api-key".path;
  tailscaleAuthkeyFile = config.sops.secrets."tailscale/authkey".path;

  # Shared daemon-boot preamble (reboot hardening). Each wrapper below is a launchd RunAtLoad daemon
  # that, on a cold boot, races three not-yet-ready things: tart's ASYNC virtiofs share auto-mount,
  # sops-nix's /run/secrets decrypt (tmpfs, empty until then), and a sane process env — launchd hands
  # daemons an UNSET HOME and root's inaccessible CWD (/var/root, mode 700), so a Python daemon crashes
  # resolving `~` and on `rich`'s import-time os.getcwd(). A wrapper that FAILS FAST on any of these is
  # penalty-boxed by launchd ("respawning too quickly") and stays DOWN until a human kicks it. So BLOCK
  # until every precondition holds — then the daemon starts cleanly on the first attempt and a reboot
  # self-heals — and pin HOME + a readable CWD. The waits fail LOUD on exhaustion (the helper's non-zero
  # return trips the wrapper's `set -e`; KeepAlive re-waits) rather than exec'ing against a missing
  # share/secret. `shares` are paths under tart's single AppleVirtIOFS automount (wait_path_exists's
  # `test -e` access triggers + verifies the on-demand mount, since the per-share paths never appear
  # in `mount`); `secrets` are /run/secrets files the wrapper still sources/cats itself.
  mkDaemonPreamble =
    {
      shares ? [ ],
      secrets ? [ ],
    }:
    ''
      ${waitLib}
      TAILSCALE=/opt/homebrew/bin/tailscale
      export HOME=${lib.escapeShellArg home}
      ${lib.concatMapStrings (m: ''
        wait_path_exists ${lib.escapeShellArg m}
      '') shares}
      ${lib.concatMapStrings (f: ''
        wait_file_nonempty ${lib.escapeShellArg f}
      '') secrets}
      cd "$HOME"
    '';

  # Wrappers: launchd has no EnvironmentFile, so each wrapper sources the secret/env it needs
  # and exec's the absolute binary. The daemons run as `adminUser` so they read the admin-owned
  # sops secrets; MLX/Metal GPU works headless from a daemon context — no login session needed.
  # rapid-mlx (8000) and mlx-audio (8765) now run as thin socat TCP relays to the model plane on
  # the HOST (yasyf-home), which serves both behind its own idle-unload activator (Phase 5). Each
  # relay binds THIS node's tailnet IP on the port hermes already calls and forwards to the host's
  # tailnet IP, so hermes keeps calling metal:8000 / metal:8765 unchanged — the relay carries no
  # shares, no HF cache, and no model env. As of Phase 6 the in-guest venvs + models are gone; the
  # host is the sole model plane.
  rapidMlxWrapper = pkgs.writeShellScript "metal-rapid-mlx" ''
    set -euo pipefail
    ${mkDaemonPreamble { }}
    # Bind to THIS node's tailnet (CGNAT 100.64.0.0/10) IPv4 instead of 0.0.0.0, so the port is never
    # exposed on the vmnet LAN bridge even if the pf anchor is down — the pf anchor (scoped to
    # hermes's resolved tailnet IP) stays the PRIMARY gate; this is the bind-layer backstop (M2).
    # Both resolves fail LOUD on exhaustion (a relay bound/forwarding to nothing is useless); set -e
    # aborts and KeepAlive restarts the wrapper to retry once tailscaled is up. yasyf-home is the
    # host node; `tailscale ip -4 yasyf-home` answers from the netmap once tailscaled is Running.
    TSIP="$(wait_tailscale_ip)"
    HOSTIP="$(wait_tailscale_ip yasyf-home)"
    # connect-timeout only bounds TCP connect to the host's always-resident activator — the slow
    # cold model wake happens at the HTTP layer behind an already-accepted connection — so with
    # max-children it caps the forked-child pile-up when the host is in the netmap but unreachable.
    # -t 600 covers a client that half-closes after its request (socat's default post-EOF grace is
    # 0.5 s, which would kill a >0.5 s generation mid-stream) while bounding orphaned children.
    exec ${socatBin} -t 600 \
      "TCP-LISTEN:8000,bind=$TSIP,fork,max-children=64,reuseaddr,nodelay" \
      "TCP:$HOSTIP:8000,nodelay,connect-timeout=10"
  '';

  # This daemon relays 8765 to the host, same shape as the rapid-mlx wrapper above. The host now
  # serves STT (Parakeet via the athome activator); the retired in-guest fallback is gone.
  sttWrapper = pkgs.writeShellScript "metal-mlx-audio" ''
    set -euo pipefail
    ${mkDaemonPreamble { }}
    # Tailnet-only bind (M2) — see the rapid-mlx wrapper.
    TSIP="$(wait_tailscale_ip)"
    HOSTIP="$(wait_tailscale_ip yasyf-home)"
    # Relay options: see the rapid-mlx wrapper.
    exec ${socatBin} -t 600 \
      "TCP-LISTEN:8765,bind=$TSIP,fork,max-children=64,reuseaddr,nodelay" \
      "TCP:$HOSTIP:8765,nodelay,connect-timeout=10"
  '';

  # Render the cliproxy config from the committed template, substituting the sops cliproxy/api-key
  # into a runtime path the admin agent can read (the real key never enters the Nix store).
  cliproxyConfigTemplate = ./metal-cliproxyapi-config.yaml;
  cliproxyConfigRendered = "/Volumes/My Shared Files/cliproxy/config.yaml";
  cliproxyWrapper = pkgs.writeShellScript "metal-cliproxy" ''
    set -euo pipefail
    ${mkDaemonPreamble {
      shares = [ cliproxyShare ];
      secrets = [ cliproxyKeyFile ];
    }}
    KEY=$(cat ${lib.escapeShellArg cliproxyKeyFile})
    mkdir -p ${lib.escapeShellArg "/Volumes/My Shared Files/cliproxy/auth"}
    ${pkgs.gnused}/bin/sed -e "s|@@CLIPROXY_API_KEY@@|$KEY|g" \
      ${lib.escapeShellArg "${cliproxyConfigTemplate}"} > ${lib.escapeShellArg cliproxyConfigRendered}
    chmod 600 ${lib.escapeShellArg cliproxyConfigRendered}
    exec ${pkgs.cli-proxy-api}/bin/cli-proxy-api --config ${lib.escapeShellArg cliproxyConfigRendered}
  '';

  # Foreground server (launchd supervises); master password from the sops env file.
  agentVaultWrapper = pkgs.writeShellScript "metal-agent-vault" ''
    set -euo pipefail
    ${mkDaemonPreamble {
      shares = [ vaultStateDir ];
      secrets = [ masterPasswordFile ];
    }}
    export AGENT_VAULT_HOME=${lib.escapeShellArg vaultStateDir}
    # The pidfile lives on the PERSISTENT share, so it survives reboots; agent-vault's liveness
    # check is PID-existence only, and post-reboot PID reuse makes it refuse to start ("server is
    # already running") forever. launchd is the single-instance supervisor here — the pidfile is
    # only for manual CLI use — so a pidfile at wrapper-exec time is stale by definition.
    rm -f "$AGENT_VAULT_HOME/.agent-vault/agent-vault.pid"
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    # Proxy rate limits (instance-wide — agent-vault has no per-vault knob). hermes is the SOLE
    # proxy consumer, so instance-wide == per-vault here. Tune these to taste; LOCK pins them so a
    # runtime call cannot widen them. (M9.)
    export AGENT_VAULT_RATELIMIT_PROXY_RATE=15
    export AGENT_VAULT_RATELIMIT_PROXY_BURST=100
    export AGENT_VAULT_RATELIMIT_PROXY_CONCURRENCY=32
    export AGENT_VAULT_RATELIMIT_LOCK=true
    exec ${pkgs.agent-vault}/bin/agent-vault server --host 0.0.0.0 --port 14321 --mitm-port 14322
  '';

  # Provisioning oneshot (ported from vault.nix:100-129): wait for /health, register the owner on
  # first boot, ensure the `hermes` vault, replace-all the service rules, (re)set the static keys.
  agentVaultProvision = pkgs.writeShellScript "metal-agent-vault-provision" ''
    set -euo pipefail
    ${mkDaemonPreamble {
      shares = [ vaultStateDir ];
      secrets = [ masterPasswordFile ];
    }}
    export AGENT_VAULT_HOME=${lib.escapeShellArg vaultStateDir}
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    ADDR=http://127.0.0.1:14321
    owner=${adminUser}@metal.local
    AV=${pkgs.agent-vault}/bin/agent-vault

    wait_for "agent-vault /health" 120 1 ${pkgs.curl}/bin/curl -fs -o /dev/null "$ADDR/health"

    if ${pkgs.curl}/bin/curl -fsS "$ADDR/v1/status" | ${pkgs.gnugrep}/bin/grep -q '"needs_first_user":true'; then
      printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
        | "$AV" auth register --address "$ADDR" --email "$owner" --password-stdin
    elif [ ! -s "$AGENT_VAULT_HOME/.agent-vault/session.json" ]; then
      printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
        | "$AV" auth login --address "$ADDR" --email "$owner" --password-stdin
    fi

    "$AV" vault create ${vaultName} 2>/dev/null || true
    "$AV" vault service set --vault ${vaultName} --file ${lib.escapeShellArg "${servicesYaml}"}
    "$AV" vault credential set --vault ${vaultName} \
      $(cat ${lib.escapeShellArg staticKeysFile})

    # Ensure the injection-only proxy agent for the hermes vault exists (409 if already created —
    # swallow it). bootstrap.sh then `agent rotate`s this agent to mint hermes's proxy token, which
    # carries credential injection on the matched hosts but can never read/reveal a raw key. (L1.)
    "$AV" agent create ${vaultName} --vault ${vaultName}:proxy 2>/dev/null || true
  '';

  # Scope metal's five service ports to its two legitimate consumers, resolved at RUNTIME (boot,
  # activation, and a periodic refresh — never baked into the build):
  #   * hermes (the runtime client), by HOSTNAME — `tailscale ip -4 hermes`. If hermes is rebuilt and
  #     its tailnet IP changes, the next resolve re-scopes with no darwin-rebuild.
  #   * the host admin machine, whose tailnet IP is NOT yclaw-named (it is the operator's own Mac, an
  #     existing tailnet member) so it cannot be resolved here — bootstrap.sh writes it into
  #     `metal-allowed-hosts` over the SSH path (which the gate never blocks) and kicks this refresh.
  #     The host reaches `metal:14321` directly for the bootstrap CA fetch + Google-OAuth admin.
  # This is the PRIMARY hermes/host-only gate: the deployment tailnet is SHARED and its ACL is
  # allow-all, so the ACL does not restrict metal — pf does, here, dropping every OTHER tailnet node
  # and the sibling vmnet-LAN guests. Never fail-OPEN: with no resolvable source
  # the anchor is fully CLOSED (lo0 only), never the whole CGNAT.
  #
  # $1 = poll attempts (1s apart) to wait for tailscaled + the hermes peer. A transient hermes
  # unresolve reuses the last-known hermes IP (sticky state) so a blip never drops hermes; it never
  # widens. The anchor is written atomically (temp + rename) and loaded into the kernel BEFORE the
  # file is persisted, with the load failure surfaced — so the on-disk file (the boot-time `load
  # anchor` source) can never claim a ruleset the kernel does not actually hold.
  # The five service ports, derived from the canonical machines manifest (machines.json) so the pf
  # anchor can never drift from it. builtins.fromJSON sorts attrsets, so the manifest's service
  # order is pinned here by name to keep the historical port order.
  pfPortServices = [
    "rapid-mlx"
    "mlx-audio"
    "cliproxy"
    "agent-vault"
  ];
  pfPorts = lib.concatMap (
    name:
    let
      svc = machinesManifest.machines.metal.services.${name};
    in
    [ svc.port ] ++ lib.optional (svc ? mitm_port) svc.mitm_port
  ) pfPortServices;

  pfAnchorScript = pkgs.writeShellScript "metal-pf-anchor" ''
    set -u
    ${waitLib}
    TAILSCALE=/opt/homebrew/bin/tailscale
    ANCHOR_DIR="/etc/pf.anchors"
    ANCHOR_FILE="$ANCHOR_DIR/metal"
    HOSTS_FILE="$ANCHOR_DIR/metal-allowed-hosts"
    HERMES_STATE="$ANCHOR_DIR/.metal-hermes-ip"
    PORTS="{ ${lib.concatMapStringsSep ", " toString pfPorts} }"
    # A single bare IPv4 host — NO CIDR. Both writers (tailscale ip -4; bootstrap.sh) emit a bare /32,
    # so refusing a mask stops a fat-fingered/hostile `0.0.0.0/0` line in metal-allowed-hosts from
    # widening the gate to the whole tailnet. A malformed octet still gets rejected by pfctl at load,
    # which fail-CLOSED leaves the prior ruleset in force (see the load check below).
    IPV4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
    mkdir -p "$ANCHOR_DIR"

    HERMES_IP="$(wait_tailscale_ip hermes "''${1:-10}")" || HERMES_IP=""
    # Remember a good resolve; reuse the last-known IP on a transient unresolve so a blip never DROPS
    # hermes. Never resolved + no prior state => hermes simply absent (fail-closed, NOT the CGNAT).
    if printf '%s' "$HERMES_IP" | grep -Eq "$IPV4"; then
      printf '%s\n' "$HERMES_IP" > "$HERMES_STATE.tmp" && mv -f "$HERMES_STATE.tmp" "$HERMES_STATE"
    elif [ -s "$HERMES_STATE" ]; then
      HERMES_IP=$(cat "$HERMES_STATE")
    else
      HERMES_IP=""
    fi

    # Allowed sources = hermes + the host admin IP(s). Each host line must be a single bare IPv4
    # before it can reach a pf rule, so the file can neither inject pf syntax nor widen to a fat CIDR.
    SOURCES=""
    [ -n "$HERMES_IP" ] && SOURCES="$HERMES_IP"
    if [ -s "$HOSTS_FILE" ]; then
      while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '[:space:]')
        printf '%s' "$line" | grep -Eq "$IPV4" && SOURCES="''${SOURCES:+$SOURCES }$line"
      done < "$HOSTS_FILE"
    fi

    # Build the desired anchor in a temp file. No source => CLOSED (lo0 pass + block-all): the very
    # first bring-up before hermes joins and before the host has injected its IP.
    TMP=$(mktemp "$ANCHOR_DIR/.metal.XXXXXX") || { echo "metal: ERROR mktemp failed for pf anchor" >&2; exit 1; }
    {
      echo "# Generated at runtime by metal-pf-anchor (hermes by hostname; host IPs from metal-allowed-hosts)."
      echo "# lo0 is never filtered (agent-vault provision + health checks hit 127.0.0.1:14321)."
      echo "pass in quick on lo0 all"
      for s in $SOURCES; do
        echo "pass in quick proto tcp from $s to any port $PORTS"
      done
      echo "block in quick proto tcp from any to any port $PORTS"
    } > "$TMP"

    # Watchdog: pf can sit loaded-but-DISABLED (macOS boots that way, and an out-of-band `pfctl -d`
    # would too), in which case a resident block rule filters NOTHING — and cliproxy/agent-vault bind
    # 0.0.0.0, so pf is their SOLE gate. If our block rule is already resident but pf is off, re-enable
    # it (idempotent), so the 5-min refresh guards the ENGINE, not just the ruleset (the boot daemon
    # only re-enables at boot). Runs before the skip below so an unchanged ruleset cannot bypass it.
    if /sbin/pfctl -a metal -sr 2>/dev/null | grep -q 'block' && ! /sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      echo "metal: WARN pf was disabled with the metal anchor resident — re-enabling" >&2
      /sbin/pfctl -e 2>/dev/null || true
    fi

    # Skip the reload only when the desired ruleset already matches the persisted file AND the kernel
    # actually has the anchor loaded (a block rule resident) — so a stale/empty kernel anchor or a
    # changed source set always forces a reload, while a steady-state refresh stays quiet.
    if cmp -s "$TMP" "$ANCHOR_FILE" && /sbin/pfctl -a metal -sr 2>/dev/null | grep -q 'block'; then
      rm -f "$TMP"
      exit 0
    fi
    # Load into the kernel FIRST; persist the file (the boot-time `load anchor` source) only once pf
    # has accepted it, and surface a load failure instead of swallowing it. ALWAYS reloads when not
    # current (cheap; pf STATE survives a rule reload), so a prior failed load self-heals.
    if /sbin/pfctl -a metal -f "$TMP" 2>/dev/null; then
      mv -f "$TMP" "$ANCHOR_FILE"
      echo "metal: pf anchor sources = ''${SOURCES:-CLOSED (no hermes, no host yet)}"
    else
      rm -f "$TMP"
      echo "metal: ERROR pfctl rejected the metal anchor — previous ruleset left in force" >&2
      exit 1
    fi
  '';

  # metal-pf-refresh runs this loop RESIDENT under KeepAlive instead of as a StartInterval oneshot: on
  # macOS Tahoe the StartInterval timer silently stopped firing (the job still exits 0 when kickstarted
  # — only the timer died), while launchd's process-liveness KeepAlive stays reliable. The loop
  # self-paces with `sleep 300`; pfAnchorScript runs as a CHILD (`|| true`) so its per-tick exit (0 skip
  # / 1 pfctl reject) never kills the loop and trips KeepAlive's 10s ThrottleInterval churn.
  pfRefreshLoop = pkgs.writeShellScript "metal-pf-refresh-loop" ''
    while true; do
      ${pfAnchorScript} 3 || true
      sleep 300
    done
  '';

  # Re-applied at EVERY boot (postActivation runs only on darwin-rebuild, and both the Metal wired
  # cap and pf reset on reboot). Raise the wired cap, reload pf.conf (re-loads the persisted `metal`
  # anchor — last-known-good), ENABLE pf and fail LOUD (non-zero, recorded by launchd) if it does not
  # come up, THEN refresh the anchor to hermes's current tailnet IP. The refresh runs AFTER pf is
  # already enforcing the persisted anchor, so waiting up to 120s for tailscaled never opens a window.
  # Final gate: assert the metal block rule is actually RESIDENT in the kernel — `Status: Enabled`
  # alone passes even with an empty anchor (e.g. if the pf.conf reload failed), which would leave the
  # 0.0.0.0-bound credential ports open; the block rule is the real default-deny.
  # The launchctl `disable` overrides live in /var/db/com.apple.xpc.launchd/disabled.plist, which is
  # RESET to the deploy-time baseline on reboot — so the manifest debloat must be re-applied at EVERY
  # boot, not just on darwin-rebuild (postActivation). Shared by postActivation (immediate effect on a
  # redeploy) and bootSetupScript (reboot survival). System jobs in the `system/` domain; the admin
  # account's per-user agents in the session-independent `user/<uid>` domain — NOT `gui/<uid>`: metal
  # is headless (no Aqua session), so `gui/` does not exist and every op there fails 125. All `|| true`:
  # SIP refuses a protected label silently, and a label absent on this build no-ops.
  debloatDisableScript = ''
    ADMIN_UID=$(/usr/bin/id -u ${adminUser})
    for L in ${toString machinesManifest.debloat.metal.system}; do
      /bin/launchctl disable "system/$L" >/dev/null 2>&1 || true
    done
    for L in ${toString machinesManifest.debloat.metal.gui}; do
      /bin/launchctl disable "user/$ADMIN_UID/$L" >/dev/null 2>&1 || true
    done
  '';

  bootSetupScript = pkgs.writeShellScript "metal-boot-setup" ''
    set -u
    wired=$(( $(/usr/sbin/sysctl -n hw.memsize)/1048576 - 6144 ))
    /usr/sbin/sysctl iogpu.wired_limit_mb=$wired || true
    /sbin/pfctl -f /etc/pf.conf 2>/dev/null || echo 'metal: ERROR pfctl -f /etc/pf.conf failed' >&2
    /sbin/pfctl -e 2>/dev/null || true
    if ! /sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      echo 'metal: FATAL pf not enabled after boot setup — credential services exposed to vmnet LAN' >&2
      exit 1
    fi
    ${pfAnchorScript} 120
    if ! /sbin/pfctl -a metal -sr 2>/dev/null | grep -q 'block'; then
      echo 'metal: FATAL metal pf anchor has no block rule after boot setup — credential ports exposed' >&2
      exit 1
    fi
    # Re-apply the manifest debloat (the override db resets on reboot; postActivation runs only on
    # darwin-rebuild). Non-fatal — a debloat miss must never block the boot's security-critical pf gate.
    ${debloatDisableScript}
  '';
in
{
  # Evaluate-only manifest sanity: every secret metal owns must exist in the catalog (the single
  # source of truth that scripts/lib/secrets.sh also reads), so an ownership/catalog drift fails
  # `nix flake check` instead of producing an undecryptable bundle at runtime.
  assertions = map (key: {
    assertion = manifest.catalog ? ${key};
    message = "metal: secret '${key}' is in hosts.metal.secrets but missing from manifest.catalog";
  }) manifest.hosts.metal.secrets;

  networking.hostName = "metal";
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 5;
  system.primaryUser = adminUser;

  # CLI helper on the system PATH (/run/current-system/sw/bin) so bootstrap can mint hermes's
  # agent-vault proxy token over `tailscale ssh root@metal`. `agent rotate` needs the provisioned
  # master session, which lives under AGENT_VAULT_HOME=vaultStateDir (where the provision daemon
  # registered it) — so run it as admin with that override. `--token-only` is idempotent and prints
  # ONLY the raw proxy token. A bare `agent-vault` is NOT on root's SSH PATH (nix-store binary), and
  # root has no session, which is why bootstrap must go through this helper.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "metal-mint-hermes-token"
      "exec /usr/bin/sudo -u ${adminUser} /usr/bin/env HOME=${lib.escapeShellArg home} AGENT_VAULT_HOME=${lib.escapeShellArg vaultStateDir} ${pkgs.agent-vault}/bin/agent-vault agent rotate ${vaultName} --token-only")

    # In-guest redeploy over `tailscale ssh root@metal -- metal-redeploy`: rebuild metal from the
    # read-only repo virtiofs share. Runs as root (the only admin path), so no sudo. The GitHub token
    # is sourced HERE, in-guest, from the sops static-keys bundle — the running guest has NO token in
    # its nix.conf (nix.enable=false above, so nix-darwin manages no `nix.*` settings at all), yet
    # darwin-rebuild must fetch the flake's github: inputs under github.com's anonymous rate limit.
    # vault/static-keys decrypts to a dotenv KEY=VALUE block (manifest envblock), so source it like
    # the master-password wrappers above to put $GITHUB_TOKEN in the env. The token rides into nix via
    # a MULTI-LINE NIX_CONFIG (experimental-features + access-tokens) built right here on metal: such a
    # value must NEVER be passed across `tailscale ssh` — the remote arg vector word-splits on the
    # newline and the login shell runs a truncated command (the bootstrap.sh:240 lesson), so the
    # token-bearing config is assembled in-guest, never shipped over the SSH boundary.
    (pkgs.writeShellScriptBin "metal-redeploy" ''
      set -euo pipefail
      set -a; . ${lib.escapeShellArg staticKeysFile}; set +a
      export NIX_CONFIG="experimental-features = nix-command flakes
      access-tokens = github.com=$GITHUB_TOKEN"
      # nix's libgit2 refuses to evaluate the repo flake from the virtiofs share (owned by the host
      # user, not root) unless the path is a git safe.directory — set it idempotently for root.
      ${pkgs.git}/bin/git config --global --get-all safe.directory 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -qxF ${lib.escapeShellArg repoShare} \
        || ${pkgs.git}/bin/git config --global --add safe.directory ${lib.escapeShellArg repoShare}
      exec /run/current-system/sw/bin/darwin-rebuild switch --flake ${lib.escapeShellArg "${repoShare}#metal"}
    '')
  ];

  # Nix is installed by the Determinate installer in-guest (it runs its own daemon), so
  # nix-darwin must NOT also manage the Nix installation — otherwise activation aborts with
  # "Determinate detected". This forgoes the `nix.*` settings options (unused here).
  nix.enable = false;

  # nix-darwin defaults `security.pam.services.sudo_local.enable = true`, which symlinks
  # /etc/pam.d/sudo_local at activation. At metal's FIRST boot that write races macOS's own
  # first-boot /etc/pam.d setup and fails ("Operation not permitted"), aborting activation before
  # the Homebrew bundle + the tailnet join ever run. metal is headless (no Touch ID) so it needs no
  # sudo_local — disable nix-darwin's management of it; stock sudo works fine without the file.
  security.pam.services.sudo_local.enable = false;

  # --- Lockdown: typed nix-darwin options --------------------------------------
  # The hardening nix-darwin exposes as typed system.defaults; everything without a typed option
  # (Remote Login, sharing services, Gatekeeper, Spotlight, Siri, telemetry) is applied
  # imperatively in postActivation below. Guest login is killed and the `>console` login-window
  # escape is disabled. Auto-login is DROPPED by packer (VM_AUTOLOGIN=drop, the account-lockout fix);
  # it is NOT required for the GPU (services are UserName=admin daemons, MLX works headless), and
  # FileVault is deliberately NOT used regardless; sensitive state lives on the
  # host's ~/.yclaw/state and is backed up encrypted off-box.
  system.defaults.loginwindow = {
    GuestEnabled = false;
    DisableConsoleAccess = true;
  };

  # --- Homebrew (OSS Tailscale) ------------------------------------------------
  # cleanup="none" keeps untracked packages; autoUpdate=false keeps `switch` idempotent.
  # tailscale is the OSS CLI (the tailscaled daemon is brew-managed; `tailscale up` runs at
  # activation, below). metal no longer serves a local model, so the python@3.14 keg the retired
  # in-guest rapid-mlx venv built from is dropped — cleanup="none" leaves any already-installed copy
  # on disk (harmless, unlisted) and a fresh image never installs it.
  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
    };
    brews = [
      "tailscale"
    ];
  };

  # --- Secrets (sops-nix) ------------------------------------------------------
  # defaultSopsFile is a RUNTIME STRING path on the narrow metalsecrets share, NOT a `../…` path
  # literal: a literal would import the encrypted blob into the world-readable Nix store.
  # validateSopsFiles=false is what lets a non-store path evaluate (see nixos/common.nix).
  # The age key is copied from the share to /var/lib/sops-nix/key.txt by copyAgeKey (below),
  # which runs in preActivation — BEFORE sops-nix decrypts in postActivation.
  #
  # The cliproxy/rapid-mlx/STT/agent-vault wrappers run as the `admin` GUI user, so the secrets they
  # source are owned by admin (the default 0400 root-only would be unreadable by a user agent).
  sops = {
    defaultSopsFile = "${metalSecrets}/secrets.sops.yaml";
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    # Derived from the manifest (nixos/secrets-manifest.json) — the single source of truth for
    # host->secret ownership — so this set can never drift from the encryption scope.
    secrets = lib.genAttrs manifest.hosts.metal.secrets (_: { owner = adminUser; });
  };

  # --- launchd daemons for the AI + credential services ------------------------
  # System daemons running as `adminUser`, NOT user agents. nix-darwin loads user agents via
  # `launchctl asuser <uid>`, which needs a live Aqua GUI session — but metal runs headless
  # (tart --no-graphics), so no such session exists and the asuser load aborts activation
  # (RC=134) before the Homebrew bundle + tailnet join even run. Running these as UserName=admin
  # system daemons loads them in the global context (no GUI session) while still running as the
  # admin uid, so they read the admin-owned sops secrets.
  # MLX/Metal GPU compute is verified to work headless from a daemon context (no login session),
  # so rapid-mlx/mlx-audio do NOT need a GUI session. All ProgramArguments are absolute (launchd does
  # not use PATH or expand ~). RunAtLoad + KeepAlive = restart-always, except the provision oneshot.
  launchd.daemons.rapid-mlx.serviceConfig = {
    ProgramArguments = wait4path [ "${rapidMlxWrapper}" ];
    UserName = adminUser;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/rapid-mlx/rapid-mlx.log";
    StandardErrorPath = "${logs}/rapid-mlx/rapid-mlx.error.log";
  };

  launchd.daemons.mlx-audio.serviceConfig = {
    ProgramArguments = wait4path [ "${sttWrapper}" ];
    UserName = adminUser;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/mlx-audio/stt.log";
    StandardErrorPath = "${logs}/mlx-audio/stt.error.log";
  };

  launchd.daemons.cliproxy.serviceConfig = {
    ProgramArguments = wait4path [ "${cliproxyWrapper}" ];
    UserName = adminUser;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/cliproxy/proxy.log";
    StandardErrorPath = "${logs}/cliproxy/proxy.error.log";
  };

  launchd.daemons.agent-vault.serviceConfig = {
    ProgramArguments = wait4path [ "${agentVaultWrapper}" ];
    UserName = adminUser;
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/agent-vault/server.log";
    StandardErrorPath = "${logs}/agent-vault/server.error.log";
  };

  # Provision oneshot: SuccessfulExit=false relaunches it until it exits 0 (the script is
  # idempotent), then leaves it alone — a boot-race failure self-heals instead of staying down.
  # ThrottleInterval stays at the 10s launchd default: lowering it + a fast-exiting job is the
  # "respawning too quickly" penalty box. It waits for the server's /health before registering,
  # so no explicit ordering against agent-vault is needed.
  launchd.daemons.agent-vault-provision.serviceConfig = {
    ProgramArguments = wait4path [ "${agentVaultProvision}" ];
    UserName = adminUser;
    RunAtLoad = true;
    KeepAlive = {
      SuccessfulExit = false;
    };
    StandardOutPath = "${logs}/agent-vault/provision.log";
    StandardErrorPath = "${logs}/agent-vault/provision.error.log";
  };

  # --- boot-time system setup (system daemon) ----------------------------------
  # postActivation (below) sets the Metal wired cap, enables pf, and scopes the anchor to hermes +
  # the host — but activation runs only on `darwin-rebuild`, NOT at boot, and all three reset on reboot:
  #   * iogpu.wired_limit_mb is a runtime sysctl that reverts to the macOS default on boot; re-applying
  #     it keeps the GPU wired cap tracking the guest's RAM (metal serves no local model now).
  #   * macOS's boot-time com.apple.pfctl loads /etc/pf.conf (so the `metal` anchor rules are present)
  #     but never ENABLES pf, so the gate would sit inert after a reboot (including the
  #     auto-security-update reboots this module keeps on), exposing the credential services.
  # bootSetupScript (defined above) re-applies all of it at every boot: raise the cap, reload + enable
  # pf and fail LOUD if it does not come up, then re-resolve the allowed sources and re-scope the anchor.
  # SuccessfulExit=false relaunches the (idempotent) oneshot until it exits 0, so a transient pf/
  # tailscaled failure self-heals; ThrottleInterval stays at the 10s default (penalty-box trap).
  launchd.daemons.metal-boot-setup.serviceConfig = {
    ProgramArguments = wait4path [ "${bootSetupScript}" ];
    RunAtLoad = true;
    KeepAlive = {
      SuccessfulExit = false;
    };
    StandardOutPath = "/var/log/metal-boot-setup.log";
    StandardErrorPath = "/var/log/metal-boot-setup.error.log";
  };

  # Periodic anchor refresh: a RESIDENT KeepAlive loop (pfRefreshLoop) that re-resolves hermes +
  # re-reads the host allow-list every 5 min and re-scopes the pf anchor if a source moved (hermes
  # destroyed + recreated, or a host IP change) — so the gate self-heals WITHOUT a reboot or
  # darwin-rebuild. launchd's StartInterval timer proved unreliable on macOS Tahoe (it stopped firing
  # while the job still ran clean on demand), so the loop self-paces under process-liveness KeepAlive.
  # Never loosens: a transient hermes unresolve reuses the sticky last-known IP, and an unchanged
  # source set skips the reload, so established pf state is left intact.
  launchd.daemons.metal-pf-refresh.serviceConfig = {
    ProgramArguments = wait4path [ "${pfRefreshLoop}" ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "/var/log/metal-pf-refresh.log";
    StandardErrorPath = "/var/log/metal-pf-refresh.error.log";
  };

  # --- Activation-time imperative steps ----------------------------------------
  # Runs as root with a minimal env (env -i, coreutils+gnugrep on PATH); use absolute paths
  # for everything else.

  # Copy the age key from the share to the sops keyFile location. preActivation runs BEFORE
  # sops-nix's postActivation install, so the key is in place when sops decrypts. Fail loud if
  # the share key is absent — a node with no age key cannot decrypt any secret.
  system.activationScripts.preActivation.text = ''
    # One-time cleanup of the retired /nix-race trampoline (replaced by wait4path in the daemon
    # ProgramArguments; two clean reboot gates passed 2026-07-03).
    rm -f /usr/local/lib/yclaw/metal-wait-nix

    if [ ! -s /var/lib/sops-nix/key.txt ]; then
      if [ -s ${lib.escapeShellArg "${metalSecrets}/key.txt"} ]; then
        mkdir -p /var/lib/sops-nix
        install -m 600 ${lib.escapeShellArg "${metalSecrets}/key.txt"} /var/lib/sops-nix/key.txt
      else
        echo "metal: FATAL no age key at ${metalSecrets}/key.txt" >&2
        exit 1
      fi
    fi
  '';

  # Metal working-set cap, one-time omlx + retired-fallback cleanup, pf tailnet-only anchor, app-firewall allowlist
  # (normal priority — none need a decrypted secret), then the tailscale join (mkAfter, so it
  # runs after sops-nix installs the authkey, which it also appends via mkAfter to this hook).
  # Idempotent throughout.
  system.activationScripts.postActivation.text = lib.mkMerge [
    ''
      # Set the Metal wired-memory cap from the guest's own RAM (leave 6 GB for the OS). metal serves
      # no local model now, so this is just headroom bookkeeping — kept so the cap tracks the VM size
      # on any resize instead of a hardcode. Per-boot setting, re-applied on every activation.
      wired=$(( $(/usr/sbin/sysctl -n hw.memsize)/1048576 - 6144 ))
      /usr/sbin/sysctl iogpu.wired_limit_mb=$wired || true

      # One-time cleanup of the retired omlx engine (replaced by rapid-mlx 2026-07-12): its
      # settings/state, SSD KV cache, logs, and app-firewall allowlist entry.
      rm -rf ${lib.escapeShellArg "${home}/.omlx"} ${lib.escapeShellArg "${home}/Library/Caches/omlx-kv"} ${lib.escapeShellArg "${logs}/omlx"}
      /usr/libexec/ApplicationFirewall/socketfilterfw --remove /opt/homebrew/bin/omlx >/dev/null 2>&1 || true

      # One-time cleanup of the retired in-guest model fallback (Phase 6, 2026-07-14): metal no longer
      # serves models directly — rapid-mlx/mlx-audio are thin socat relays to the host plane — so the
      # fallback venvs and their python app-firewall entries are dead. The rapid-mlx venv is
      # guest-local; the mlxaudio venv is reached through the still-mounted share (the resize drops
      # that share afterward, so this re-runs every activation and no-ops once gone). Idempotent.
      rm -rf ${lib.escapeShellArg "${home}/.venvs/rapid-mlx"} "/Volumes/My Shared Files/mlxaudio/venv"
      for PYFW in \
        /opt/homebrew/opt/python@*/Frameworks/Python.framework/Versions/*/Resources/Python.app/Contents/MacOS/Python \
        /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/*/Resources/Python.app/Contents/MacOS/Python; do
        if [ -e "$PYFW" ]; then
          /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$PYFW" >/dev/null 2>&1 || true
        fi
      done

      # The service daemons run as `admin` and log under admin's ~/Library/Logs; launchd needs each
      # StandardOutPath's parent dir to exist, so pre-create them owned by admin.
      mkdir -p ${lib.escapeShellArg "${logs}/rapid-mlx"} ${lib.escapeShellArg "${logs}/mlx-audio"} \
        ${lib.escapeShellArg "${logs}/cliproxy"} ${lib.escapeShellArg "${logs}/agent-vault"}
      chown ${adminUser} ${lib.escapeShellArg "${logs}/rapid-mlx"} ${lib.escapeShellArg "${logs}/mlx-audio"} \
        ${lib.escapeShellArg "${logs}/cliproxy"} ${lib.escapeShellArg "${logs}/agent-vault"}

      # pf anchor — scope the five service ports to hermes (resolved by hostname) + the host admin IP.
      # metal-pf-anchor writes /etc/pf.anchors/metal and reloads just this anchor. This is the PRIMARY
      # gate: the shared deployment tailnet's ACL is allow-all, so pf — not the ACL — is what limits
      # metal to hermes + the host. NEVER `pfctl -f /etc/pf.conf` except on the first anchor add (a
      # full reload flushes the dynamically-loaded vmnet/NAT anchors); the script reloads ONLY this
      # anchor with `pfctl -a metal` (the hard-won guard from host.nix:189-204).
      ${pfAnchorScript}
      # Wire the anchor into pf.conf ONCE (first activation) so the boot-time `pfctl -f` reloads it.
      if ! grep -q 'anchor "metal"' /etc/pf.conf; then
        cat >> /etc/pf.conf <<CONF

      anchor "metal"
      load anchor "metal" from "/etc/pf.anchors/metal"
      CONF
        /sbin/pfctl -f /etc/pf.conf || true
      fi
      # ENABLE pf. macOS ships pf DISABLED and only auto-enables it for Internet Sharing/vmnet —
      # which runs on the HOST, not in this guest — so, unlike host.nix, we MUST enable it here or
      # the anchor is loaded-but-never-enforced and the services are NOT actually restricted.
      # `-e` is idempotent enough (no-ops with a harmless error if pf is already enabled). The
      # scoped anchor only blocks the five ports, so enabling pf never touches ssh/tailscale.
      /sbin/pfctl -e 2>/dev/null || true

      # Application firewall: ON + stealth + logging, plus a per-binary allowlist. The macOS app
      # firewall silently drops inbound to unsigned binaries, so the tailnet cannot reach these
      # services until they are explicitly unblocked; tailscaled is allowlisted too so direct
      # (non-DERP) inbound and the tailscale-ssh path survive. Idempotent (each call is a no-op
      # when already applied). NOTE: deliberately NO --setblockall — "block all incoming" overrides
      # this allowlist and would drop both the five services and tailscaled, cutting service
      # inbound AND the only admin path; pf above is the tailnet-only default-deny.
      FW=/usr/libexec/ApplicationFirewall/socketfilterfw
      "$FW" --setglobalstate on >/dev/null 2>&1 || true
      "$FW" --setstealthmode on >/dev/null 2>&1 || true
      "$FW" --setloggingmode on >/dev/null 2>&1 || true
      # Allowlist the ACTUAL listening binaries. socat is the listener for 8000/8765 (the relays to
      # the host) — a nix-store binary, so it takes the same stale-entry cleanup as cli-proxy-api/
      # agent-vault below. cli-proxy-api/agent-vault are the real nix-store listeners; tailscaled is
      # allowlisted so direct (non-DERP) inbound and tailscale-ssh survive. The in-guest python
      # frameworks are NO LONGER allowlisted — the model fallback they served is retired (Phase 6),
      # and the cleanup above removes their stale entries.
      # pf above is the real tailnet-only gate; this allowlist is per-app defense-in-depth.
      # Nix-store listeners get a NEW path on every rebuild, but their adhoc signature keeps the
      # same Identifier — socketfilterfw then dedups `--add` against the STALE entry (rc=0, no new
      # entry) while enforcement compares CDHashes and silently DROPS the new binary's inbound
      # (observed live 2026-07-04: agent-vault unreachable after the state-dir patch rebuild).
      # Remove any other /nix/store entry for the same binary basename before adding the current one.
      for BIN in \
        ${pkgs.cli-proxy-api}/bin/cli-proxy-api \
        ${pkgs.agent-vault}/bin/agent-vault \
        ${socatBin}; do
        NAME=$(/usr/bin/basename "$BIN")
        "$FW" --listapps 2>/dev/null \
          | /usr/bin/grep -oE "/nix/store/[^ ]*/bin/$NAME" \
          | /usr/bin/grep -vxF "$BIN" \
          | while IFS= read -r STALE; do "$FW" --remove "$STALE" >/dev/null 2>&1 || true; done
      done
      for BIN in \
        ${pkgs.cli-proxy-api}/bin/cli-proxy-api \
        ${pkgs.agent-vault}/bin/agent-vault \
        ${socatBin} \
        /opt/homebrew/bin/tailscaled; do
        if [ -e "$BIN" ]; then
          "$FW" --add "$BIN" >/dev/null 2>&1 || true
          "$FW" --unblockapp "$BIN" >/dev/null 2>&1 || true
        fi
      done

      # OpenSSH Remote Login OFF. `systemsetup -setremotelogin off` needs Full Disk Access — which
      # the activation context does NOT have — so it silently no-ops; disable the sshd LaunchDaemon
      # directly instead (FDA-independent, idempotent). macOS sshd is independent of tailscale ssh
      # (served inside tailscaled), so this does NOT cut admin access: the ONLY admin path becomes
      # `tailscale ssh root@metal`, and tailscaled is left running.
      /bin/launchctl disable system/com.openssh.sshd >/dev/null 2>&1 || true
      /bin/launchctl bootout system/com.openssh.sshd >/dev/null 2>&1 || true

      # Disable every sharing / remote-access surface — metal is headless and tailnet-only.
      # `launchctl disable` writes the persistent override db (survives reboot). This does NOT
      # touch the host's tart console (tart exposes the guest framebuffer at the virtualization
      # layer, independent of the guest's Screen Sharing), so a console fallback remains.
      /bin/launchctl disable system/com.apple.screensharing >/dev/null 2>&1 || true
      /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
        -deactivate -stop >/dev/null 2>&1 || true
      /bin/launchctl disable system/com.apple.smbd >/dev/null 2>&1 || true
      /bin/launchctl disable system/com.apple.AppleFileServer >/dev/null 2>&1 || true
      /usr/sbin/cupsctl --no-share-printers >/dev/null 2>&1 || true
      /bin/launchctl disable system/com.apple.InternetSharing >/dev/null 2>&1 || true
      /usr/sbin/systemsetup -f -setremoteappleevents off >/dev/null 2>&1 || true
      /usr/bin/AssetCacheManagerUtil deactivate >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults write com.apple.amp.mediasharingd home-sharing-enabled -int 0 >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults -currentHost write com.apple.Bluetooth PrefKeyServicesEnabled -bool false >/dev/null 2>&1 || true

      # Guest account off (belt-and-suspenders with system.defaults.loginwindow.GuestEnabled),
      # Gatekeeper assessments ON, Spotlight indexing OFF.
      /usr/sbin/sysadminctl -guestAccount off >/dev/null 2>&1 || true
      /usr/sbin/spctl --global-enable >/dev/null 2>&1 || true
      /usr/bin/mdutil -a -i off >/dev/null 2>&1 || true

      # --- Aggressive debloat: disable non-essential background daemons + agents -----------------
      # metal is a headless MLX compute node: no Apple ID, no iCloud, no Time Machine target, no
      # local user activity. The OS's indexing, media-analysis, Apple-Intelligence, telemetry,
      # proactivity, Siri, location, Game-Center, Screen-Time, Continuity, Find-My and
      # experiment/differential-privacy subsystems are pure overhead here — periodic CPU/RAM spikes
      # plus attack surface. `launchctl disable` writes the persistent
      # override db (survives reboot), so no bootSetupScript duplication is needed. System jobs
      # (/System/Library/LaunchDaemons) are addressed in the `system/` domain; the admin account's
      # per-user agents (/System/Library/LaunchAgents) in the `user/<uid>/` domain — NOT `gui/<uid>/`:
      # metal is headless (--no-graphics, no Aqua session), so the `gui/` domain does not exist and
      # every `gui/<uid>/…` op fails `125: Domain does not support specified action`. The `user/`
      # domain is session-independent (works with or without a login window) and writes the same
      # durable override, so it disables these agents on headless metal where `gui/` cannot. The
      # label lists live in machines.json (debloat.metal — the canonical manifest; bluebubbles
      # consumes its own deliberate subset). Domains were read off this build's own
      # /System/Library/Launch{Daemons,Agents} (the guests share the cirruslabs macos-tahoe base),
      # not guessed. All `|| true`: SIP is ON (a protected label is refused silently) and a label
      # absent on this build no-ops.
      # KEPT ENABLED deliberately: ReportCrash + spindump (LOCAL crash diagnostics — only the Apple
      # telemetry SUBMISSION is cut, via SubmitDiagInfo) and softwareupdated (security updates, set
      # further down). tmutil kills Time Machine's auto-schedule; the backupd daemons are belt-and-braces.
      /usr/bin/tmutil disable >/dev/null 2>&1 || true
      # The launchctl-disable loops are shared with bootSetupScript (which re-runs them at every boot,
      # because the override db resets to the deploy-time baseline on reboot). Applied here too so a
      # redeploy takes effect immediately without waiting for a reboot.
      ${debloatDisableScript}
      # Power: never nap or sleep (a sleeping VM drops the services) — but the DISPLAY should sleep:
      # awake it costs the host ~20% of a core in PVG frame encodes, asleep 0% (measured 2026-07-14).
      /usr/bin/pmset -a powernap 0 womp 0 sleep 0 disksleep 0 displaysleep 1 >/dev/null 2>&1 || true

      # Reduce surface / noise: Siri, analytics submission, AirDrop, Handoff, Wi-Fi power. The
      # user-domain writes go through the admin login session (auto-login is on); best-effort and
      # re-applied each activation. The VM uses virtio ethernet, so -setairportpower usually
      # no-ops (no airport device).
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults write com.apple.assistant.support "Assistant Enabled" -bool false >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults write com.apple.Siri StatusMenuVisible -bool false >/dev/null 2>&1 || true
      /usr/bin/defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" AutoSubmit -bool false >/dev/null 2>&1 || true
      /usr/bin/defaults write "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" ThirdPartyDataSubmit -bool false >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults write com.apple.NetworkBrowser DisableAirDrop -bool true >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false >/dev/null 2>&1 || true
      /usr/bin/sudo -u ${adminUser} /usr/bin/defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false >/dev/null 2>&1 || true
      /usr/sbin/networksetup -setairportpower en0 off >/dev/null 2>&1 || true

      # KEEP automatic security updates ON — deliberate: with everything else locked down, XProtect
      # / security responses must keep flowing. Major OS auto-install is left OFF.
      /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true >/dev/null 2>&1 || true
      /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true >/dev/null 2>&1 || true
      /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true >/dev/null 2>&1 || true
      /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true >/dev/null 2>&1 || true

      # Sudo: admin keeps password-gated `%admin` sudo (the macOS default) — we add NO passwordless
      # rule, and nix-darwin needs none here (darwin-rebuild prompts). The admin account password is
      # random-generated by scripts/lib/secrets.sh into the dedicated yclaw keychain
      # (yclaw.keychain-db, service yclaw-metal-admin-pass; unlocked via yclaw-keychain-password in the
      # login keychain) and passed to packer via PKR_VAR_vm_admin_pass at image-build time (the packer
      # var default is the @@VM_ADMIN_PASS@@ placeholder), closing the cirruslabs base image's default
      # admin/admin hole; it is never hardcoded here.
    ''
    # Tailscale: join the tailnet as `metal` with SSH. mkAfter so it runs AFTER sops-nix installs
    # the authkey secret (sops appends its install with mkAfter to this same hook). Idempotent —
    # skip if already up. NO --shields-up (it would block hermes->metal inbound). --advertise-tags
    # =tag:metal binds this node to the tag:metal ACL grants in tailnet/policy.hujson — that file
    # now OWNS tag:metal (the source of truth the per-node minted key is also tagged against), so
    # advertising it succeeds; it is what enforces least-privilege east-west reachability.
    (lib.mkAfter ''
      # tailscaled is brew-installed (homebrew module above) but is NOT registered as a system
      # daemon on a fresh node, and `tailscale up` needs it running — register + start it
      # (idempotent), then wait for the daemon to answer before joining. Best-effort (`|| true`):
      # a daemon that never answers falls through to the same guarded branches as before. NOTE:
      # `tailscale status` answering is deliberately weaker than wait_tailscale_running (which
      # requires BackendState=Running) — a fresh logged-out node must proceed to `tailscale up`.
      ${waitLib}
      # FIRST-INSTALL ONLY. `install-system-daemon` TERMINATES a running tailscaled and its
      # re-load silently fails on this base (observed live 2026-07-03: log ends at "got signal
      # terminated", node offline until the next boot's RunAtLoad) — so running it on every
      # activation cut the tailnet, and with it the only admin path, on every `metal-redeploy`.
      if [ ! -f /Library/LaunchDaemons/com.tailscale.tailscaled.plist ]; then
        /opt/homebrew/bin/tailscaled install-system-daemon \
          || echo "metal: ERROR tailscaled install-system-daemon failed" >&2
        /bin/launchctl bootstrap system /Library/LaunchDaemons/com.tailscale.tailscaled.plist 2>/dev/null || true
      fi
      wait_for "tailscaled answering" 30 2 /bin/sh -c '/opt/homebrew/bin/tailscale status >/dev/null 2>&1' || true
      # Ensure BOTH the tailnet join and the SSH server, idempotently. Gate on the backend actually
      # being Running (joined) — NOT on `tailscale status` succeeding, which returns 0 even when the
      # daemon is up but LOGGED OUT (so the old guard skipped the cold-join `up` forever). The SSH
      # assertion must not be down-gated: OpenSSH Remote Login is disabled above, so leaving the node
      # up WITHOUT --ssh would cut the only admin path. `tailscale set --ssh` is idempotent.
      if /opt/homebrew/bin/tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"'; then
        /opt/homebrew/bin/tailscale set --ssh=true || true
      elif [ -s ${lib.escapeShellArg tailscaleAuthkeyFile} ]; then
        /opt/homebrew/bin/tailscale up \
          --authkey "$(cat ${lib.escapeShellArg tailscaleAuthkeyFile})" \
          --hostname metal --ssh --advertise-tags=tag:metal || true
      fi
    '')
  ];
}
