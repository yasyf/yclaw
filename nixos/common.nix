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
  # virtiofs must be loaded BEFORE stage-2 activation: the age-key seeding (below) mounts the
  # tart `--dir` share during the activation script, which runs before systemd loads modules.
  # Loading it in the initrd guarantees availability at that point.
  boot.initrd.kernelModules = [ "virtiofs" ];
  boot.initrd.availableKernelModules = [ "virtio_pci" ];
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

  # --- Age-key seeding (tart virtiofs share) -----------------------------------
  # The age private key is NOT baked into the (world-readable) image; the host shares it
  # into the VM at runtime via `tart run --dir=sops:<dir>` (a virtiofs mount, tag `sops`).
  # sops-nix installs secrets in the `setupSecrets` ACTIVATION script (pre-systemd, so
  # fileSystems mounts aren't up yet) — so this seeding is itself an activation script that
  # mounts the share by hand and must run BEFORE setupSecrets. Idempotent: once the key is on
  # the VM's persistent root it is not re-copied; tolerant if the share is absent (so a
  # mis-launched VM still boots for diagnosis rather than bricking activation).
  system.activationScripts.seedSopsAgeKey = {
    deps = [ "specialfs" ];
    text = ''
      if [ -s /var/lib/sops-nix/key.txt ]; then
        echo "seedSopsAgeKey: key already present"
      else
        echo "seed-diag: /proc/filesystems virtio: [$(${pkgs.gnugrep}/bin/grep -i virtio /proc/filesystems | tr '\n' ',')]"
        echo "seed-diag: virtio devices: [$(ls /sys/bus/virtio/devices 2>/dev/null | tr '\n' ',')]"
        echo "seed-diag: dmesg virtio_fs: [$(dmesg 2>/dev/null | ${pkgs.gnugrep}/bin/grep -iE 'virtio.fs|virtiofs' | tail -3 | tr '\n' '|')]"
        echo "seed-diag: modprobe: [$(${pkgs.kmod}/bin/modprobe virtiofs 2>&1; echo rc=$?)]"
        install -d -m 700 /var/lib/sops-nix /run/sops-age-src
        for tag in sops com.apple.virtio-fs.automount; do
          out="$(${pkgs.util-linux}/bin/mount -t virtiofs -o ro "$tag" /run/sops-age-src 2>&1)"
          if [ $? -eq 0 ]; then
            echo "seed-diag: MOUNTED tag=$tag contents=[$(ls -a /run/sops-age-src 2>/dev/null | tr '\n' ',')]"
            [ -s /run/sops-age-src/key.txt ] && install -m 600 /run/sops-age-src/key.txt /var/lib/sops-nix/key.txt && echo "seedSopsAgeKey: installed age key"
            ${pkgs.util-linux}/bin/umount /run/sops-age-src 2>/dev/null || true
            break
          else
            echo "seed-diag: mount tag=$tag failed: [$out]"
          fi
        done
        [ -s /var/lib/sops-nix/key.txt ] || echo "seedSopsAgeKey: FAILED to obtain key"
      fi
    '';
  };
  # Run the seeding before sops decrypts (deps merge, so sops-nix's own ordering is kept).
  system.activationScripts.setupSecrets.deps = [ "seedSopsAgeKey" ];

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
