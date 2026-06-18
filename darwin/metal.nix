# nix-darwin module for the `metal` macOS guest VM. Applies IN-GUEST with
# `darwin-rebuild switch --flake <repo>#metal`.
#
# metal is the SIP-ON, MAX-LOCKED credential + AI services VM — one of three guests on the
# bare-macOS host (alongside `bluebubbles` and `hermes`), with its own tailnet node. It holds
# ALL credentials and serves four OpenAI-compatible services over the tailnet:
#   omlx        :8000   local Qwen (replaces mlx_lm.server)
#   mlx-audio   :8765   STT, ibm-granite/granite-speech-4.1-2b (replaces parakeet)
#   cliproxy    :8317   CLIProxyAPI, Codex/Gemini OAuth -> static key
#   agent-vault :14321  credential broker API  + :14322 transparent MITM proxy
#
# Persistent state lives on NARROW per-need virtiofs shares (the host shares only the slices of
# ~/.yclaw/state that metal owns): "/Volumes/My Shared Files/metalsecrets" (metal's age key + its
# own secrets bundle), plus agentvault / hf / mlxaudio / cliproxy for the runtime dirs. metal
# never sees hosts/hermes/ or state/hermes/. The repo is shared read-only at
# "/Volumes/My Shared Files/repo". The guest admin user is `admin` (home /Users/admin).
#
# metal runs NO iMessage and NO BlueBubbles: those live on the separate `bluebubbles` guest,
# which keeps SIP OFF (its Private API needs it) precisely so metal can stay SIP-ON and maximally
# locked down. metal holds the credentials; bluebubbles and hermes hold none.
#
# Lockdown posture: SIP on, Gatekeeper on, app firewall + a pf tailnet-only anchor, every
# sharing/remote-access surface off, and OpenSSH Remote Login off — the ONLY admin path is
# `tailscale ssh root@metal`. In-guest auto-login stays ON (set by packer) so omlx gets a GPU
# aqua session; FileVault is therefore NOT used (auto-login would negate it). Sensitive state
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

  adminUser = "admin";
  home = "/Users/${adminUser}";
  logs = "${home}/Library/Logs";

  # Narrow per-need virtiofs shares (scripts/setup.sh mounts each at /Volumes/My Shared Files/<name>):
  # metalsecrets holds ONLY metal's age key + its own secrets bundle, so metal never sees
  # hosts/hermes/ or state/hermes/. The runtime dirs are the only other state metal owns.
  metalSecrets = "/Volumes/My Shared Files/metalsecrets";

  # The broker's logical vault NAME (vault.nix: the `vault:` key is "hermes").
  vaultName = "hermes";
  vaultHome = "/Volumes/My Shared Files/agentvault";
  servicesYaml = ../nixos/vault-services.yaml;

  hfHome = "/Volumes/My Shared Files/hf";

  # mlx-audio runs from a python venv (system python3 is 3.14); the wrapper builds it once.
  sttVenv = "/Volumes/My Shared Files/mlxaudio/venv";

  # Decrypted sops secret paths (sops-nix installs to /run/secrets/<name>).
  masterPasswordFile = config.sops.secrets."vault/master-password".path;
  staticKeysFile = config.sops.secrets."vault/static-keys".path;
  apertureKeyFile = config.sops.secrets."aperture/static-key".path;
  tailscaleAuthkeyFile = config.sops.secrets."tailscale/authkey".path;

  # Wrappers: launchd has no EnvironmentFile, so each wrapper sources the secret/env it needs
  # and exec's the absolute binary. Run as the `admin` GUI user (Metal needs the login session).
  # omlx discovers the model from the HF cache on the state mount (HF_HOME) via --hf-cache
  # (default on); no --model-dir (verified: serving the 35B this way cold-loads in ~14s).
  omlxWrapper = pkgs.writeShellScript "metal-omlx" ''
    set -euo pipefail
    export HF_HOME=${lib.escapeShellArg hfHome}
    mkdir -p "$HF_HOME" ${lib.escapeShellArg "${home}/Library/Caches/omlx-kv"}
    exec /opt/homebrew/bin/omlx serve \
      --host 0.0.0.0 --port 8000 \
      --memory-guard balanced \
      --paged-ssd-cache-dir ${lib.escapeShellArg "${home}/Library/Caches/omlx-kv"} \
      --hot-cache-max-size 8GB
  '';

  # mlx-audio's own multi-threaded `mlx_audio.server` crashes granite-speech with
  # "There is no Stream(gpu, 1) in current thread" (MLX streams are per-thread). We run our
  # single-worker wrapper (darwin/stt-server.py) instead, which drives the same single-threaded
  # path the CLI uses. Idempotent venv build (skip if present); setuptools<81 kept for safety
  # (>=81 drops pkg_resources, which some transitive imports still expect on py3.14).
  sttServerPy = ./stt-server.py;
  sttWrapper = pkgs.writeShellScript "metal-mlx-audio" ''
    set -euo pipefail
    export HF_HOME=${lib.escapeShellArg hfHome}
    export STT_MODEL=${(import ../nixos/models.nix).stt} STT_PORT=8765
    mkdir -p "$HF_HOME"
    VENV=${lib.escapeShellArg sttVenv}
    if [ ! -x "$VENV/bin/python" ]; then
      mkdir -p "$(dirname "$VENV")"
      /usr/bin/python3 -m venv "$VENV"
      "$VENV/bin/python" -m pip install --upgrade pip
      "$VENV/bin/python" -m pip install mlx-audio uvicorn fastapi python-multipart "setuptools<81"
    fi
    exec "$VENV/bin/python" ${sttServerPy}
  '';

  # Render the cliproxy config from the committed template, substituting the sops static-key
  # into a runtime path the admin agent can read (the real key never enters the Nix store).
  cliproxyConfigTemplate = ./metal-cliproxyapi-config.yaml;
  cliproxyConfigRendered = "/Volumes/My Shared Files/cliproxy/config.yaml";
  cliproxyWrapper = pkgs.writeShellScript "metal-cliproxy" ''
    set -euo pipefail
    # Wait for sops-nix to decrypt the key. /run/secrets is tmpfs (empty on a cold boot) and this
    # RunAtLoad agent can win the race against the sops secret-install daemon; without the wait the
    # `cat` fails under `set -e` and the service crash-loops until kicked.
    for _ in $(seq 1 60); do [ -s ${lib.escapeShellArg apertureKeyFile} ] && break; sleep 1; done
    KEY=$(cat ${lib.escapeShellArg apertureKeyFile})
    mkdir -p ${lib.escapeShellArg "/Volumes/My Shared Files/cliproxy/auth"}
    ${pkgs.gnused}/bin/sed "s|@@APERTURE_STATIC_KEY@@|$KEY|g" \
      ${lib.escapeShellArg "${cliproxyConfigTemplate}"} > ${lib.escapeShellArg cliproxyConfigRendered}
    chmod 600 ${lib.escapeShellArg cliproxyConfigRendered}
    exec ${pkgs.cli-proxy-api}/bin/cli-proxy-api --config ${lib.escapeShellArg cliproxyConfigRendered}
  '';

  # Foreground server (launchd supervises); master password from the sops env file.
  agentVaultWrapper = pkgs.writeShellScript "metal-agent-vault" ''
    set -euo pipefail
    export HOME=${lib.escapeShellArg vaultHome}
    mkdir -p "$HOME"
    # Wait for sops-nix to decrypt on boot (tmpfs /run/secrets, RunAtLoad-vs-sops race).
    for _ in $(seq 1 60); do [ -s ${lib.escapeShellArg masterPasswordFile} ] && break; sleep 1; done
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    exec ${pkgs.agent-vault}/bin/agent-vault server --host 0.0.0.0 --port 14321 --mitm-port 14322
  '';

  # Provisioning oneshot (ported from vault.nix:100-129): wait for /health, register the owner on
  # first boot, ensure the `hermes` vault, replace-all the service rules, (re)set the static keys.
  agentVaultProvision = pkgs.writeShellScript "metal-agent-vault-provision" ''
    set -euo pipefail
    export HOME=${lib.escapeShellArg vaultHome}
    mkdir -p "$HOME"
    # Wait for sops-nix to decrypt on boot (tmpfs /run/secrets, RunAtLoad-vs-sops race).
    for _ in $(seq 1 60); do [ -s ${lib.escapeShellArg masterPasswordFile} ] && break; sleep 1; done
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    ADDR=http://127.0.0.1:14321
    owner=${adminUser}@metal.local
    AV=${pkgs.agent-vault}/bin/agent-vault

    for _ in $(seq 1 120); do ${pkgs.curl}/bin/curl -fsS "$ADDR/health" >/dev/null 2>&1 && break; sleep 1; done

    if ${pkgs.curl}/bin/curl -fsS "$ADDR/v1/status" | ${pkgs.gnugrep}/bin/grep -q '"needs_first_user":true'; then
      printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
        | "$AV" auth register --address "$ADDR" --email "$owner" --password-stdin
    elif [ ! -s "$HOME/.agent-vault/session.json" ]; then
      printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
        | "$AV" auth login --address "$ADDR" --email "$owner" --password-stdin
    fi

    "$AV" vault create ${vaultName} 2>/dev/null || true
    "$AV" vault service set --vault ${vaultName} --file ${lib.escapeShellArg "${servicesYaml}"}
    "$AV" vault credential set --vault ${vaultName} \
      $(cat ${lib.escapeShellArg staticKeysFile})
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

  # Nix is installed by the Determinate installer in-guest (it runs its own daemon), so
  # nix-darwin must NOT also manage the Nix installation — otherwise activation aborts with
  # "Determinate detected". This forgoes the `nix.*` settings options (unused here).
  nix.enable = false;

  # --- Lockdown: typed nix-darwin options --------------------------------------
  # The hardening nix-darwin exposes as typed system.defaults; everything without a typed option
  # (Remote Login, sharing services, Gatekeeper, Spotlight, Siri, telemetry) is applied
  # imperatively in postActivation below. Guest login is killed and the `>console` login-window
  # escape is disabled. Auto-login stays ON (set by packer) so omlx gets a GPU aqua session, so
  # FileVault is deliberately NOT used (it would negate auto-login); sensitive state lives on the
  # host's ~/.yclaw/state and is backed up encrypted off-box.
  system.defaults.loginwindow = {
    GuestEnabled = false;
    DisableConsoleAccess = true;
  };

  # --- Homebrew (omlx + OSS Tailscale) -----------------------------------------
  # cleanup="none" keeps untracked packages; autoUpdate=false keeps `switch` idempotent.
  # omlx is the jundot/omlx FORMULA (bin /opt/homebrew/bin/omlx); tailscale is the OSS CLI
  # (the tailscaled daemon is brew-managed; `tailscale up` runs at activation, below).
  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
    };
    taps = [ "jundot/omlx" ];
    brews = [
      "omlx"
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
  # The cliproxy/omlx/STT/agent-vault wrappers run as the `admin` GUI user, so the secrets they
  # source are owned by admin (the default 0400 root-only would be unreadable by a user agent).
  sops = {
    defaultSopsFile = "${metalSecrets}/secrets.sops.yaml";
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    # Derived from the manifest (nixos/secrets-manifest.json) — the single source of truth for
    # host->secret ownership — so this set can never drift from the encryption scope.
    secrets = lib.genAttrs manifest.hosts.metal.secrets (_: { owner = adminUser; });
  };

  # --- launchd user agents -----------------------------------------------------
  # User agents (gui session), NOT system daemons: omlx/mlx-audio need the GPU + Metal, which
  # the system domain lacks. All ProgramArguments are absolute (launchd does not use PATH or
  # expand ~). RunAtLoad + KeepAlive = restart-always, except the provision oneshot.
  launchd.user.agents.omlx.serviceConfig = {
    ProgramArguments = [ "${omlxWrapper}" ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/omlx/omlx.log";
    StandardErrorPath = "${logs}/omlx/omlx.error.log";
  };

  launchd.user.agents.mlx-audio.serviceConfig = {
    ProgramArguments = [ "${sttWrapper}" ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/mlx-audio/stt.log";
    StandardErrorPath = "${logs}/mlx-audio/stt.error.log";
  };

  launchd.user.agents.cliproxy.serviceConfig = {
    ProgramArguments = [ "${cliproxyWrapper}" ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/cliproxy/proxy.log";
    StandardErrorPath = "${logs}/cliproxy/proxy.error.log";
  };

  launchd.user.agents.agent-vault.serviceConfig = {
    ProgramArguments = [ "${agentVaultWrapper}" ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/agent-vault/server.log";
    StandardErrorPath = "${logs}/agent-vault/server.error.log";
  };

  # Provision runs once at load and exits (KeepAlive=false). It waits for the server's /health
  # before registering, so no explicit ordering against agent-vault is needed.
  launchd.user.agents.agent-vault-provision.serviceConfig = {
    ProgramArguments = [ "${agentVaultProvision}" ];
    RunAtLoad = true;
    KeepAlive = false;
    StandardOutPath = "${logs}/agent-vault/provision.log";
    StandardErrorPath = "${logs}/agent-vault/provision.error.log";
  };

  # --- boot-time system setup (system daemon) ----------------------------------
  # The postActivation script (below) sets the Metal wired-memory cap and enables pf, but
  # activation runs only on `darwin-rebuild`, NOT at boot — and BOTH reset on reboot:
  #   * iogpu.wired_limit_mb is a runtime sysctl that reverts to the macOS default (~36 GB) on
  #     boot, too small for the 35B model + KV cache, so omlx would fail/OOM on first serve.
  #   * macOS's boot-time com.apple.pfctl loads /etc/pf.conf (so the `metal` anchor rules are
  #     present) but never ENABLES pf, so the tailnet-only gate would sit inert after a reboot
  #     (including the auto-security-update reboots this module keeps on), exposing the
  #     credential services to the vmnet LAN.
  # This RunAtLoad daemon re-applies both at every boot: raise the wired cap, then reload
  # /etc/pf.conf (includes the persisted `metal` anchor) and enable pf. The guest runs no
  # vmnet/NAT anchors, so a full `-f` reload is safe here.
  launchd.daemons.metal-boot-setup.serviceConfig = {
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "wired=$(( $(/usr/sbin/sysctl -n hw.memsize)/1048576 - 6144 )); /usr/sbin/sysctl iogpu.wired_limit_mb=$wired || true; /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true; /sbin/pfctl -e 2>/dev/null || true"
    ];
    RunAtLoad = true;
    KeepAlive = false;
    StandardOutPath = "/var/log/metal-boot-setup.log";
    StandardErrorPath = "/var/log/metal-boot-setup.error.log";
  };

  # --- Activation-time imperative steps ----------------------------------------
  # Runs as root with a minimal env (env -i, coreutils+gnugrep on PATH); use absolute paths
  # for everything else.

  # Copy the age key from the share to the sops keyFile location. preActivation runs BEFORE
  # sops-nix's postActivation install, so the key is in place when sops decrypts. Fail loud if
  # the share key is absent — a node with no age key cannot decrypt any secret.
  system.activationScripts.preActivation.text = ''
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

  # Metal working-set cap, omlx idle-unload, pf tailnet-only anchor, app-firewall allowlist
  # (normal priority — none need a decrypted secret), then the tailscale join (mkAfter, so it
  # runs after sops-nix installs the authkey, which it also appends via mkAfter to this hook).
  # Idempotent throughout.
  system.activationScripts.postActivation.text = lib.mkMerge [
    ''
      # Raise the Metal wired-memory cap (Apple's default is 36 GB) so the 20 GB 35B model + KV
      # cache fits. Per-boot setting, re-applied on every activation. Derived from the guest's own
      # RAM (leave 6 GB for the OS) so it tracks the VM size instead of a hardcode.
      wired=$(( $(/usr/sbin/sysctl -n hw.memsize)/1048576 - 6144 ))
      /usr/sbin/sysctl iogpu.wired_limit_mb=$wired || true

      # omlx idle-unload: merge idle_timeout into ~/.omlx/settings.json (created by omlx on first
      # serve; JSON). Write as the admin user so ownership stays correct.
      OMLX_DIR=${lib.escapeShellArg "${home}/.omlx"}
      SETTINGS="$OMLX_DIR/settings.json"
      mkdir -p "$OMLX_DIR"
      if [ -s "$SETTINGS" ]; then
        ${pkgs.jq}/bin/jq '.idle_timeout.idle_timeout_seconds = 1800' "$SETTINGS" > "$SETTINGS.tmp"
      else
        echo '{}' | ${pkgs.jq}/bin/jq '.idle_timeout.idle_timeout_seconds = 1800' > "$SETTINGS.tmp"
      fi
      mv "$SETTINGS.tmp" "$SETTINGS"
      chown -R ${adminUser} "$OMLX_DIR"

      # pf anchor — inbound to the service ports ONLY from the tailnet (100.64.0.0/10), blocked
      # otherwise. Idempotent (only appends to pf.conf once). NEVER `pfctl -f /etc/pf.conf`
      # except on the first anchor add: a full reload flushes the dynamically-loaded vmnet/NAT
      # anchors; reload ONLY this anchor with `pfctl -a metal` on every other activation (the
      # hard-won guard from host.nix:189-204).
      PF_ANCHOR_FILE="/etc/pf.anchors/metal"
      mkdir -p /etc/pf.anchors
      cat > "$PF_ANCHOR_FILE" <<'EOF'
      # Loopback is never filtered (the agent-vault provision oneshot + service health checks hit
      # 127.0.0.1:14321). Allow ONLY the tailnet CGNAT to the five service ports; every other
      # source — including the sibling guests sharing the host's vmnet LAN bridge — is dropped.
      # RFC-1918 is deliberately NOT allowed: these credential/AI services are tailnet-only.
      pass in quick on lo0 all
      pass in quick proto tcp from 100.64.0.0/10 to any port { 8000, 8765, 8317, 14321, 14322 }
      block in quick proto tcp from any to any port { 8000, 8765, 8317, 14321, 14322 }
      EOF
      if ! grep -q 'anchor "metal"' /etc/pf.conf; then
        cat >> /etc/pf.conf <<CONF

      anchor "metal"
      load anchor "metal" from "/etc/pf.anchors/metal"
      CONF
        /sbin/pfctl -f /etc/pf.conf || true
      fi
      /sbin/pfctl -a metal -f "$PF_ANCHOR_FILE" 2>/dev/null || true
      # ENABLE pf. macOS ships pf DISABLED and only auto-enables it for Internet Sharing/vmnet —
      # which runs on the HOST, not in this guest — so, unlike host.nix, we MUST enable it here or
      # the anchor is loaded-but-never-enforced and the services are NOT actually tailnet-only.
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
      # Allowlist the ACTUAL listening binaries. omlx and the STT wrapper each serve from a Python
      # framework interpreter (the process renames itself to "omlx-server" via setproctitle, but the
      # kernel — and socketfilterfw — see the interpreter), so allowlist the Homebrew python
      # framework (omlx) and the CommandLineTools python framework (STT) by glob: version-agnostic
      # and robust across brew/CLT upgrades. cli-proxy-api/agent-vault are the real nix-store
      # listeners; tailscaled is allowlisted so direct (non-DERP) inbound and tailscale-ssh survive.
      # pf above is the real tailnet-only gate; this allowlist is per-app defense-in-depth.
      for BIN in \
        /opt/homebrew/opt/python@*/Frameworks/Python.framework/Versions/*/Resources/Python.app/Contents/MacOS/Python \
        /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/*/Resources/Python.app/Contents/MacOS/Python \
        /opt/homebrew/bin/omlx \
        ${pkgs.cli-proxy-api}/bin/cli-proxy-api \
        ${pkgs.agent-vault}/bin/agent-vault \
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
    # skip if already up. NO --shields-up (it would block hermes->metal inbound) and NO
    # --advertise-tags (advertising an undefined tag fails `tailscale up`); least-privilege
    # reachability is enforced separately by a tag:metal ACL on the tailnet.
    (lib.mkAfter ''
      # Ensure BOTH the tailnet join and the SSH server, idempotently. The SSH assertion must NOT
      # be gated on tailscale being down: OpenSSH Remote Login is disabled above, so if tailscaled
      # were already up WITHOUT --ssh, a down-gated `up --ssh` would be skipped forever and leave NO
      # admin path (the sharpest lockout vector). `tailscale set --ssh` is idempotent and applies
      # whether up or down; the cold-join branch (authkey present, tailscale down) handles first boot.
      if /opt/homebrew/bin/tailscale status >/dev/null 2>&1; then
        /opt/homebrew/bin/tailscale set --ssh=true || true
      elif [ -s ${lib.escapeShellArg tailscaleAuthkeyFile} ]; then
        /opt/homebrew/bin/tailscale up \
          --authkey "$(cat ${lib.escapeShellArg tailscaleAuthkeyFile})" \
          --hostname metal --ssh || true
      fi
    '')
  ];
}
