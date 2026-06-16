# nix-darwin host (Apple Silicon). Applies with `darwin-rebuild switch --flake .#host`.
# Owns: Homebrew (tart + OSS Tailscale), the host launchd agents (MLX Qwen, Parakeet STT,
# CLIProxyAPI, and the two tart VM runners), the CLIProxyAPI config at /etc/cli-proxy-api,
# and the activation-time pf VNC anchor + Tailscale OSS daemon hookup.
#
# Sources: docs/build-notes/tart-nixos-darwin.md §2, docs/build-notes/cliproxyapi.md §4.
{ pkgs, lib, ... }:
let
  home = "/Users/@@HOST_USER@@";
  logs = "${home}/Library/Logs";
in
{
  networking.hostName = "@@HOST_NAME@@";
  nixpkgs.hostPlatform = "aarch64-darwin";

  # nix-darwin uses an integer here (NOT the "25.05" NixOS string).
  system.stateVersion = 5;

  # Recent nix-darwin requires this for user-scoped options (homebrew, launchd.user.*).
  system.primaryUser = "@@HOST_USER@@";

  # --- aarch64-linux build host (nix.linux-builder) ----------------------------
  # Builds the NixOS raw-efi VM images locally: a small NixOS VM (aarch64-linux on
  # Apple Silicon) that nix offloads aarch64-linux derivations to. This is what makes
  # `just build-images` / `bootstrap` work without an external builder.
  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 4;
    # The default builder disk is too small for the hermes closure + the 5 GB raw-efi image
    # (the build VM runs out of space mid-`mv`). Give it room.
    config = {
      # nix-darwin's builder profile pins diskSize=20480; override it.
      virtualisation.diskSize = lib.mkForce (60 * 1024); # MiB
      # Default builder RAM (~3 GB) OOM-kills `npm ci` when building hermes-agent's
      # tui/web frontends from source (host has 128 GiB, so this is free headroom).
      virtualisation.memorySize = lib.mkForce (16 * 1024); # MiB
    };
  };
  # The builder must be usable by the operator and reachable as a remote store.
  nix.settings.trusted-users = [ "@@HOST_USER@@" ];

  # Leave the host's existing Touch-ID-for-sudo config alone. /etc/pam.d/sudo_local
  # already enables pam_tid + pam_reattach (homebrew) and is out of scope for this stack;
  # letting nix-darwin manage it would rewrite the auth path. Disable management so the
  # working file survives untouched.
  security.pam.services.sudo_local.enable = false;

  # --- Homebrew (tart + OSS Tailscale) -----------------------------------------
  # cleanup="none" keeps untracked packages; autoUpdate=false keeps `switch` idempotent.
  # brews."tailscale" gives the OSS tailscale CLI (the system tailscaled is a newer
  # mise-built daemon already installed on this host — see the activation note below).
  # tart is the cirruslabs/cli FORMULA, not a cask (verified: /opt/homebrew/bin/tart ->
  # Cellar/tart/2.32.1, listed by `brew list --formula`).
  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
    };
    taps = [ "cirruslabs/cli" ];
    brews = [
      "tailscale"
      "cirruslabs/cli/tart"
      "gum" # TUI for scripts/collect-secrets.sh
    ];
  };

  # --- Install the CLIProxyAPI config to a stable absolute path -----------------
  # launchd does NOT expand ~, so the agent passes an absolute --config; etc keeps it
  # in sync with the repo file on every `switch`.
  environment.etc."cli-proxy-api/config.yaml".source = ./cliproxyapi-config.yaml;

  # --- Host launchd agents -----------------------------------------------------
  # User agents (gui session), NOT system daemons: MLX/Parakeet need the GPU + Metal,
  # which the system domain lacks. All ProgramArguments are absolute (launchd does not
  # use PATH or expand ~). RunAtLoad + KeepAlive = restart-always.
  # MLX and Parakeet are installed out of band (not Nix-packaged). MLX is a mise pipx tool
  # (`mise use -g pipx:mlx-lm`); the absolute binary lives under the mise install dir. The
  # server runs WITHOUT a pinned --model so it loads the requested model lazily on the first
  # request (no multi-GB download at launchd start, verified); the qwen-local fallback request
  # carries the real MLX model id. Parakeet (STT) is still TODO(human): `parakeet-server` is not
  # yet installed (out of scope for the smoke tests — voice transcription only).
  launchd.user.agents.mlx-qwen.serviceConfig = {
    ProgramArguments = [
      "${home}/.local/share/mise/installs/pipx-mlx-lm/latest/bin/mlx_lm.server"
      "--host"
      "0.0.0.0"
      "--port"
      "8080"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/mlx/qwen.log";
    StandardErrorPath = "${logs}/mlx/qwen.error.log";
  };

  launchd.user.agents.parakeet-stt.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/parakeet-server"
      "--port"
      "8765"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/parakeet/stt.log";
    StandardErrorPath = "${logs}/parakeet/stt.error.log";
  };

  # CLIProxyAPI is Nix-packaged (pkgs.cli-proxy-api). Port comes from the config file, so the
  # agent only passes --config (absolute).
  launchd.user.agents.cliproxyapi.serviceConfig = {
    ProgramArguments = [
      "${pkgs.cli-proxy-api}/bin/cli-proxy-api"
      "--config"
      "/etc/cli-proxy-api/config.yaml"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/cliproxyapi/proxy.log";
    StandardErrorPath = "${logs}/cliproxyapi/proxy.error.log";
  };

  # The two tart Linux VM runners (NO --suspendable — `tart suspend` is macOS-guest-only and
  # errors on Linux VMs). NAT networking (tart default — no --net-bridged): this host's only
  # active uplink is Wi-Fi (en1) and both wired ports (en0, USB-LAN en12) are unplugged, so
  # bridged networking has no carrier. The VMs reach the internet through the host's NAT and
  # join the tailnet via MagicDNS regardless of uplink. A virtiofs --dir share (tag `sops`)
  # seeds the age key. (If a wired port is later restored, add `--net-bridged=<iface>` back.)
  # en12 is verified from this host's existing tart launchagents (the openclaw/bluebubbles VMs).
  # `tart run … --net-bridged=list` enumerates interfaces if this changes.
  launchd.user.agents.tart-hermes.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/tart"
      "run"
      "hermes"
      "--no-graphics"
      # Drain the guest serial console to /dev/null. Without a console sink, a headless
      # `--no-graphics` boot HANGS once the virtio console ring fills (verified) — `--serial`
      # works only because it drains the PTY. /dev/null is the launchd-friendly equivalent.
      "--serial-path=/dev/null"
      "--dir=${home}/.config/yclaw/vm-secrets:ro,tag=sops"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/Tart/hermes.log";
    StandardErrorPath = "${logs}/Tart/hermes.error.log";
  };

  launchd.user.agents.tart-vault.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/tart"
      "run"
      "vault"
      "--no-graphics"
      # Drain the guest serial console to /dev/null. Without a console sink, a headless
      # `--no-graphics` boot HANGS once the virtio console ring fills (verified) — `--serial`
      # works only because it drains the PTY. /dev/null is the launchd-friendly equivalent.
      "--serial-path=/dev/null"
      "--dir=${home}/.config/yclaw/vm-secrets:ro,tag=sops"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    StandardOutPath = "${logs}/Tart/vault.log";
    StandardErrorPath = "${logs}/Tart/vault.error.log";
  };

  # --- Activation-time imperative steps ----------------------------------------
  # Runs as root after the main activation. One idempotent step: the pf VNC anchor
  # (from tart-nixos-darwin.md §2.3; the grep guard appends to pf.conf once).
  #
  # The OSS Tailscale system daemon is intentionally NOT managed here: this host already
  # runs a newer mise-built `tailscaled` (1.98.5) as the system daemon with `tailscale ssh`
  # live, so re-pointing /usr/local/bin/tailscaled at the older Homebrew binary (1.96.4) and
  # re-running `install-system-daemon` would downgrade a working setup. Leave it alone.
  #
  # The application-firewall allowlist matters: the macOS app firewall blocks inbound to
  # unsigned binaries, so Aperture (the `ai` node) cannot reach cli-proxy-api (:8317) or the
  # MLX server (:8080) back over the tailnet until those binaries are explicitly unblocked.
  system.activationScripts.postActivation.text = ''
    # pf VNC anchor — idempotent (only appends to pf.conf once)
    PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
    mkdir -p /etc/pf.anchors
    cat > "$PF_ANCHOR_FILE" <<'EOF'
    table <vnc_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
    pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
    block in quick proto { tcp udp } from any to any port 5900:5902
    EOF
    # CRITICAL: `pfctl -f /etc/pf.conf` reloads the MAIN ruleset, which flushes the
    # dynamically-loaded vmnet / Internet-Sharing NAT anchors (shared_v4 / shared_v6 /
    # network_isolation) that the tart VMs rely on for internet + tailnet egress. Running it
    # on every activation silently kills every VM's egress (all model calls via http://ai
    # time out) until the VMs are restarted. So only do the full reload when we ACTUALLY add
    # the anchor declaration (first run / after a pf.conf reset); on every other activation
    # reload ONLY the vnc anchor with `pfctl -a vnc`, which leaves the NAT anchors untouched.
    if ! grep -q 'anchor "vnc"' /etc/pf.conf; then
      cat >> /etc/pf.conf <<CONF

    anchor "vnc"
    load anchor "vnc" from "/etc/pf.anchors/vnc"
    CONF
      pfctl -f /etc/pf.conf
    fi
    pfctl -a vnc -f "$PF_ANCHOR_FILE" 2>/dev/null || true

    # Application-firewall allowlist for the host model services. Without this the macOS app
    # firewall silently drops inbound connections from the tailnet to these unsigned binaries,
    # so `http://ai/v1` (Aperture -> cliproxy / qwen-local) hangs. Idempotent (re-adding an
    # already-listed app is a no-op).
    FW=/usr/libexec/ApplicationFirewall/socketfilterfw
    CLIPROXY_BIN="${pkgs.cli-proxy-api}/bin/cli-proxy-api"
    MLX_PY="${home}/.local/share/mise/installs/pipx-mlx-lm/latest/bin/python"
    "$FW" --add "$CLIPROXY_BIN" >/dev/null 2>&1 || true
    "$FW" --unblockapp "$CLIPROXY_BIN" >/dev/null 2>&1 || true
    if [ -e "$MLX_PY" ]; then
      "$FW" --add "$MLX_PY" >/dev/null 2>&1 || true
      "$FW" --unblockapp "$MLX_PY" >/dev/null 2>&1 || true
    fi
  '';
}
