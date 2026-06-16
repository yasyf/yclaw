# Shared base for every NixOS Linux VM (hermes, vault). Booted by tart from a
# nixos-generators `raw-efi` image. NOT imported by ai.nix (Aperture is a hosted
# Tailscale service, not a VM — see nixos/ai.nix).
#
# Sources: docs/build-notes/tart-nixos-darwin.md §1.3, §3.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # --- Boot (tart / Apple Virtualization EFI) ----------------------------------
  # The raw-efi IMAGE provides its own bootloader + root partition at normal priority,
  # overriding the mkDefault values below. Those defaults exist so the *standalone*
  # nixosConfiguration (consumed by `nixos-rebuild` and `nix flake check`) is COMPLETE —
  # without a filesystem + bootloader it fails to evaluate.
  #   * GRUB EFI + efiInstallAsRemovable → writes \EFI\BOOT\BOOTAA64.EFI, the removable
  #     path Apple VZ boots (tart's fresh nvram has no Boot#### entry).
  #   * canTouchEfiVariables = false — REQUIRED by GRUB's efiInstallAsRemovable assertion.
  #   * console=hvc0 — Apple VZ virtio console (`tart run --serial`); raw-efi also adds ttyS0.
  boot.loader.grub = {
    enable = lib.mkDefault true;
    efiSupport = true;
    efiInstallAsRemovable = lib.mkDefault true;
    device = lib.mkDefault "nodev";
  };
  boot.loader.efi.canTouchEfiVariables = false;
  boot.kernelParams = [ "console=hvc0" ];
  boot.growPartition = true;
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # --- Networking --------------------------------------------------------------
  # Bridged networking gives each VM its own LAN IP (tart --net-bridged). DHCP for
  # the LAN address; Tailscale provides MagicDNS for the per-node names.
  networking.useDHCP = lib.mkDefault true;

  # Credential custody is cooperative (HTTPS_PROXY), not a hard firewall — the
  # architecture deliberately does NOT require default-DROP (hermes-home-server.md §5).
  # Each VM opens only the tailnet-facing ports it serves.
  networking.firewall.enable = lib.mkDefault false;

  # --- Tailscale (each VM is its own tailnet node) -----------------------------
  # Per-node tailscaled so MagicDNS resolves `ai`, `vault`, `hermes`, `bluebubbles`.
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    useRoutingFeatures = "client";
    # TODO(human): on nixos-25.05 confirm `extraUpFlags` (current) vs `extraUpArgs` (older).
    extraUpFlags = [
      "--ssh"
      "--accept-dns"
      "--accept-routes"
    ];
  };

  # --- Secrets (sops-nix) ------------------------------------------------------
  # The Tailscale auth key is the one secret every VM needs at first boot. The
  # encrypted file is a bootstrap-time artifact (the human supplies @@TS_AUTHKEY@@);
  # validateSopsFiles=false lets `nix flake check` evaluate before bootstrap encrypts it.
  sops = {
    defaultSopsFile = ../secrets/secrets.sops.yaml;
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets."tailscale/authkey" = { };
  };

  # --- Base access -------------------------------------------------------------
  # Tailscale SSH gates login by tailnet identity; a wheel user is the landing target.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = false; # use `tailscale ssh`

  # --- Nix ---------------------------------------------------------------------
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.config.allowUnfree = true;

  # Pinned once; bump deliberately. (Matches the nixos-25.05 channel.)
  system.stateVersion = "25.05";
}
