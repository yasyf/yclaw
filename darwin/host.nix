# nix-darwin host (Apple Silicon). Applies with `darwin-rebuild switch --flake .#host`.
# Owns: Homebrew (tart + OSS Tailscale), the host launchd agents (MLX Qwen, Parakeet STT,
# CLIProxyAPI, and the two tart VM runners), the CLIProxyAPI config at /etc/cli-proxy-api,
# and the activation-time pf VNC anchor + Tailscale OSS daemon hookup.
#
# Sources: docs/build-notes/tart-nixos-darwin.md §2, docs/build-notes/cliproxyapi.md §4.
{ pkgs, ... }:
let
  logs = "/Users/@@HOST_USER@@/Library/Logs";
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
  };
  # The builder must be usable by the operator and reachable as a remote store.
  nix.settings.trusted-users = [ "@@HOST_USER@@" ];

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
  # TODO(human): MLX (`mlx_lm.server`) and Parakeet (`parakeet-server`) are NOT Nix-packaged
  #   — install them out of band (pip/uv/brew) so /opt/homebrew/bin/{mlx_lm.server,parakeet-server}
  #   exist; confirm those exact binary names/paths.
  launchd.user.agents.mlx-qwen.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/mlx_lm.server"
      "--model"
      "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit"
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

  # The two tart Linux VM runners. --suspendable enables `tart suspend`; bridged networking
  # gives each VM its own LAN IP + tailnet node (so `tart ip` does NOT work — use MagicDNS).
  # en12 is verified from this host's existing tart launchagents (the openclaw/bluebubbles VMs).
  # `tart run … --net-bridged=list` enumerates interfaces if this changes.
  launchd.user.agents.tart-hermes.serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/tart"
      "run"
      "hermes"
      "--no-graphics"
      "--net-bridged=en12"
      "--suspendable"
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
      "--net-bridged=en12"
      "--suspendable"
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
  system.activationScripts.postActivation.text = ''
    # pf VNC anchor — idempotent (only appends to pf.conf once)
    PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
    mkdir -p /etc/pf.anchors
    cat > "$PF_ANCHOR_FILE" <<'EOF'
    table <vnc_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
    pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
    block in quick proto { tcp udp } from any to any port 5900:5902
    EOF
    if ! grep -q 'anchor "vnc"' /etc/pf.conf; then
      cat >> /etc/pf.conf <<CONF

    anchor "vnc"
    load anchor "vnc" from "/etc/pf.anchors/vnc"
    CONF
    fi
    pfctl -f /etc/pf.conf
  '';
}
