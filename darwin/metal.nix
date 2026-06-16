# nix-darwin module for the `metal` macOS guest VM. Applies IN-GUEST with
# `darwin-rebuild switch --flake <repo>#metal`.
#
# metal is ONE locked-down macOS guest holding ALL credentials, its own tailnet node,
# serving four OpenAI-compatible services over the tailnet:
#   omlx        :8000   local Qwen (replaces mlx_lm.server)
#   mlx-audio   :8765   STT, ibm-granite/granite-speech-4.1-2b (replaces parakeet)
#   cliproxy    :8317   CLIProxyAPI, Codex/Gemini OAuth -> static key
#   agent-vault :14321  credential broker API  + :14322 transparent MITM proxy
#
# Persistent state lives on a virtiofs share at "/Volumes/My Shared Files/state" (the host
# shares ~/.yclaw/state); the repo is shared read-only at "/Volumes/My Shared Files/repo".
# The guest admin user is `admin` (home /Users/admin).
#
# SIP is OFF on this guest (BlueBubbles needs it on the host image this guest is cloned from).
# The tradeoff is accepted because the surface is mitigated two ways: the vault is encrypted at
# rest and every service is bound tailnet-only by the pf anchor + app-firewall allowlist below.
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
  adminUser = "admin";
  home = "/Users/${adminUser}";
  logs = "${home}/Library/Logs";
  state = "/Volumes/My Shared Files/state";

  # The broker's logical vault NAME (vault.nix: the `vault:` key is "hermes").
  vaultName = "hermes";
  vaultHome = "${state}/agent-vault";
  servicesYaml = ../nixos/vault-services.yaml;

  hfHome = "${state}/hf";

  # mlx-audio runs from a python venv (system python3 is 3.14); the wrapper builds it once.
  sttVenv = "${state}/mlx-audio/venv";

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
    export STT_MODEL=ibm-granite/granite-speech-4.1-2b STT_PORT=8765
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
  cliproxyConfigRendered = "${state}/cli-proxy-api/config.yaml";
  cliproxyWrapper = pkgs.writeShellScript "metal-cliproxy" ''
    set -euo pipefail
    KEY=$(cat ${lib.escapeShellArg apertureKeyFile})
    mkdir -p ${lib.escapeShellArg "${state}/cli-proxy-api/auth"}
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
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    exec ${pkgs.agent-vault}/bin/agent-vault server --host 0.0.0.0 --port 14321 --mitm-port 14322
  '';

  # Provisioning oneshot (ported from vault.nix:100-129): wait for /health, register the owner on
  # first boot, ensure the `hermes` vault, replace-all the service rules, (re)set the static keys.
  agentVaultProvision = pkgs.writeShellScript "metal-agent-vault-provision" ''
    set -euo pipefail
    export HOME=${lib.escapeShellArg vaultHome}
    mkdir -p "$HOME"
    set -a; . ${lib.escapeShellArg masterPasswordFile}; set +a
    ADDR=http://127.0.0.1:14321
    owner=admin@hermes.local
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
  networking.hostName = "metal";
  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 5;
  system.primaryUser = adminUser;

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
  # defaultSopsFile is a RUNTIME STRING path on the virtiofs state share, NOT a `../…` path
  # literal: a literal would import the encrypted blob into the world-readable Nix store.
  # validateSopsFiles=false is what lets a non-store path evaluate (see nixos/common.nix).
  # The age key is copied from the share to /var/lib/sops-nix/key.txt by copyAgeKey (below),
  # which runs in preActivation — BEFORE sops-nix decrypts in postActivation.
  #
  # The cliproxy/omlx/STT/agent-vault wrappers run as the `admin` GUI user, so the secrets they
  # source are owned by admin (the default 0400 root-only would be unreadable by a user agent).
  sops = {
    defaultSopsFile = "${state}/secrets.sops.yaml";
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets = {
      "vault/master-password" = {
        owner = adminUser;
      };
      "vault/static-keys" = {
        owner = adminUser;
      };
      "aperture/static-key" = {
        owner = adminUser;
      };
      "tailscale/authkey" = {
        owner = adminUser;
      };
    };
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

  # --- Activation-time imperative steps ----------------------------------------
  # Runs as root with a minimal env (env -i, coreutils+gnugrep on PATH); use absolute paths
  # for everything else.

  # Copy the age key from the share to the sops keyFile location. preActivation runs BEFORE
  # sops-nix's postActivation install, so the key is in place when sops decrypts. Fail loud if
  # the share key is absent — a node with no age key cannot decrypt any secret.
  system.activationScripts.preActivation.text = ''
    if [ ! -s /var/lib/sops-nix/key.txt ]; then
      if [ -s ${lib.escapeShellArg "${state}/age/key.txt"} ]; then
        mkdir -p /var/lib/sops-nix
        install -m 600 ${lib.escapeShellArg "${state}/age/key.txt"} /var/lib/sops-nix/key.txt
      else
        echo "metal: FATAL no age key at ${state}/age/key.txt" >&2
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
      # cache fits. Per-boot setting, re-applied on every activation.
      /usr/sbin/sysctl iogpu.wired_limit_mb=43008 || true

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

      # pf anchor — inbound to the service ports ONLY from the tailnet + RFC-1918, blocked
      # otherwise. Idempotent (only appends to pf.conf once). NEVER `pfctl -f /etc/pf.conf`
      # except on the first anchor add: a full reload flushes the dynamically-loaded vmnet/NAT
      # anchors; reload ONLY this anchor with `pfctl -a metal` on every other activation (the
      # hard-won guard from host.nix:189-204).
      PF_ANCHOR_FILE="/etc/pf.anchors/metal"
      mkdir -p /etc/pf.anchors
      cat > "$PF_ANCHOR_FILE" <<'EOF'
      table <metal_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
      pass in quick proto tcp from <metal_allowed> to any port { 8000, 8765, 8317, 14321, 14322 }
      block in quick proto tcp from any to any port { 8000, 8765, 8317, 14321, 14322 }
      EOF
      if ! grep -q 'anchor "metal"' /etc/pf.conf; then
        cat >> /etc/pf.conf <<CONF

      anchor "metal"
      load anchor "metal" from "/etc/pf.anchors/metal"
      CONF
        /sbin/pfctl -f /etc/pf.conf
      fi
      /sbin/pfctl -a metal -f "$PF_ANCHOR_FILE" 2>/dev/null || true

      # Application-firewall allowlist: the macOS app firewall silently drops inbound to unsigned
      # binaries, so the tailnet cannot reach these services until they are explicitly unblocked.
      # Idempotent (re-adding a listed app is a no-op).
      FW=/usr/libexec/ApplicationFirewall/socketfilterfw
      for BIN in \
        /opt/homebrew/bin/omlx \
        ${lib.escapeShellArg "${sttVenv}/bin/python"} \
        ${pkgs.cli-proxy-api}/bin/cli-proxy-api \
        ${pkgs.agent-vault}/bin/agent-vault; do
        if [ -e "$BIN" ]; then
          "$FW" --add "$BIN" >/dev/null 2>&1 || true
          "$FW" --unblockapp "$BIN" >/dev/null 2>&1 || true
        fi
      done
    ''
    # Tailscale: join the tailnet as `metal` with SSH. mkAfter so it runs AFTER sops-nix installs
    # the authkey secret (sops appends its install with mkAfter to this same hook). Idempotent —
    # skip if already up.
    (lib.mkAfter ''
      if [ -s ${lib.escapeShellArg tailscaleAuthkeyFile} ] \
         && ! /opt/homebrew/bin/tailscale status >/dev/null 2>&1; then
        /opt/homebrew/bin/tailscale up \
          --authkey "$(cat ${lib.escapeShellArg tailscaleAuthkeyFile})" \
          --hostname metal --ssh || true
      fi
    '')
  ];
}
