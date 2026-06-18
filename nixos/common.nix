# Shared base for every NixOS Linux VM (just hermes now). Booted by tart from a
# nixos-generators `raw-efi` image. NOT imported by ai.nix (Aperture is a hosted
# Tailscale service, not a VM — see nixos/ai.nix).
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
  # virtiofs must be loaded BEFORE stage-2 activation: the node-config seeding (below) mounts
  # the tart `--dir` share during the activation script, which runs before systemd loads modules.
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
  # architecture deliberately does NOT require default-DROP.
  # Each VM opens only the tailnet-facing ports it serves.
  networking.firewall.enable = lib.mkDefault false;

  # --- Tailscale (each VM is its own tailnet node) -----------------------------
  # Per-node tailscaled so MagicDNS resolves `ai`, `hermes`, `bluebubbles`, `metal`.
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    useRoutingFeatures = "client";
    # TODO(human): on nixos-25.05 confirm `extraUpFlags` (current) vs `extraUpArgs` (older).
    # --advertise-tags=tag:hermes: the per-node key minted in scripts/lib/secrets.sh is already
    # tagged, but advertising the tag is what binds this node to the tag:hermes ACL grants in
    # tailnet/policy.hujson (the source of truth that owns the tag, so advertising it succeeds).
    extraUpFlags = [
      "--ssh"
      "--accept-dns"
      "--accept-routes"
      "--advertise-tags=tag:hermes"
    ];
  };

  # --- Secrets (sops-nix) ------------------------------------------------------
  # The Tailscale auth key is the one secret every VM needs at first boot. The
  # encrypted file is a bootstrap-time artifact (the human supplies @@TS_AUTHKEY@@);
  # validateSopsFiles=false lets `nix flake check` evaluate before bootstrap encrypts it.
  #
  # defaultSopsFile is a RUNTIME STRING path, NOT a `../…` path literal: a literal would
  # import the encrypted blob into the (world-readable, GENERIC) image store closure and
  # bake one machine's secrets into every published image. The string keeps the blob OUT
  # of the store — it is seeded onto the node's persistent root at first boot by
  # seedNodeConfig (below), so one published image carries no per-user secrets and works
  # on any machine. validateSopsFiles=false is what lets a non-store path evaluate:
  # sops-nix's manifest-for.nix asserts the in-store invariant ONLY when validation is on.
  sops = {
    defaultSopsFile = "/var/lib/node-config/secrets.sops.yaml";
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    secrets."tailscale/authkey" = { };
  };

  # --- First-boot node-config seeding (tart virtiofs share) --------------------
  # NOTHING per-user is baked into the (world-readable, GENERIC) image; the host injects it
  # at runtime via `tart run --dir=<dir>:ro,tag=sops` (a virtiofs mount), so one published
  # image works on any machine. sops-nix installs secrets in the `setupSecrets` ACTIVATION
  # script (pre-systemd, so fileSystems mounts aren't up yet) — so this seeding is itself an
  # activation script that mounts the share by hand and must run BEFORE setupSecrets.
  #
  # Copied from the share into persistent runtime paths:
  #   key.txt            → /var/lib/sops-nix/key.txt               REQUIRED  (age private key)
  #   secrets.sops.yaml  → /var/lib/node-config/secrets.sops.yaml  REQUIRED  (encrypted secrets;
  #                          this is the runtime path sops.defaultSopsFile points at, above)
  #   node.env           → /var/lib/node-config/node.env           OPTIONAL  (non-secret KEY=VALUE)
  #   agent-vault-ca.pem → /var/lib/node-config/agent-vault-ca.pem OPTIONAL  (public MITM CA)
  #
  # Idempotent: once the REQUIRED pair is on the VM's persistent root the share is not
  # re-read. Fail-fast (STYLEGUIDE): a node that boots without the age key or the sops blob
  # aborts activation loudly rather than limping on with no secrets. The two OPTIONAL files
  # are tolerated-if-absent — not every node ships a node.env or a CA.
  system.activationScripts.seedNodeConfig = {
    deps = [ "specialfs" ];
    text = ''
      if [ -s /var/lib/sops-nix/key.txt ] && [ -s /var/lib/node-config/secrets.sops.yaml ]; then
        echo "seedNodeConfig: node already configured"
      else
        echo "seed-diag: /proc/filesystems virtio: [$(${pkgs.gnugrep}/bin/grep -i virtio /proc/filesystems | tr '\n' ',')]"
        echo "seed-diag: virtio devices: [$(ls /sys/bus/virtio/devices 2>/dev/null | tr '\n' ',')]"
        echo "seed-diag: dmesg virtio_fs: [$(dmesg 2>/dev/null | ${pkgs.gnugrep}/bin/grep -iE 'virtio.fs|virtiofs' | tail -3 | tr '\n' '|')]"
        echo "seed-diag: modprobe: [$(${pkgs.kmod}/bin/modprobe virtiofs 2>&1; echo rc=$?)]"
        install -d -m 700 /var/lib/sops-nix /var/lib/node-config /run/node-config-src
        for tag in sops com.apple.virtio-fs.automount; do
          out="$(${pkgs.util-linux}/bin/mount -t virtiofs -o ro "$tag" /run/node-config-src 2>&1)"
          if [ $? -eq 0 ]; then
            src=/run/node-config-src
            echo "seed-diag: MOUNTED tag=$tag contents=[$(ls -a "$src" 2>/dev/null | tr '\n' ',')]"
            [ -s "$src/key.txt" ] && install -m 600 "$src/key.txt" /var/lib/sops-nix/key.txt && echo "seedNodeConfig: installed age key"
            [ -s "$src/secrets.sops.yaml" ] && install -m 600 "$src/secrets.sops.yaml" /var/lib/node-config/secrets.sops.yaml && echo "seedNodeConfig: installed secrets.sops.yaml"
            [ -s "$src/node.env" ] && install -m 644 "$src/node.env" /var/lib/node-config/node.env && echo "seedNodeConfig: installed node.env"
            [ -s "$src/agent-vault-ca.pem" ] && install -m 644 "$src/agent-vault-ca.pem" /var/lib/node-config/agent-vault-ca.pem && echo "seedNodeConfig: installed agent-vault-ca.pem"
            ${pkgs.util-linux}/bin/umount "$src" 2>/dev/null || true
            break
          else
            echo "seed-diag: mount tag=$tag failed: [$out]"
          fi
        done
        [ -s /var/lib/sops-nix/key.txt ] || { echo "seedNodeConfig: FATAL no age key (key.txt) from share" >&2; exit 1; }
        [ -s /var/lib/node-config/secrets.sops.yaml ] || { echo "seedNodeConfig: FATAL no secrets.sops.yaml from share" >&2; exit 1; }
      fi
    '';
  };
  # Run the seeding before sops decrypts (deps merge, so sops-nix's own ordering is kept).
  system.activationScripts.setupSecrets.deps = [ "seedNodeConfig" ];

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
