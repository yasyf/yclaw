# Image-only module: build the hermes disk image with systemd-repart (no KVM, no VM), so CI on
# GitHub's KVM-less aarch64 runners can build it. Imported ONLY by mkImage (flake.nix), never by
# the standalone nixosConfiguration — it adds nothing the running system evaluates.
#
# GRUB's config was generated inside the retired make-disk-image VM; repart cannot run that, so
# the bootloader is systemd-boot (nixos/common.nix) and this module hand-seeds the ESP the way
# systemd-boot-builder.py would on the first switch. The kernel/initrd EFI names are computed
# from the toplevel at build time to byte-match that writer, so the first in-guest
# `nixos-rebuild switch` converges on the seeded generation instead of double-copying it.
{
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  toplevel = config.system.build.toplevel;
  timeout =
    if config.boot.loader.timeout == null then "menu-force" else toString config.boot.loader.timeout;
  espContents = pkgs.runCommand "hermes-esp-contents" { } ''
    kernel="$(readlink -f ${toplevel}/kernel)"
    initrd="$(readlink -f ${toplevel}/initrd)"
    kname="$(basename "$(dirname "$kernel")")-$(basename "$kernel").efi"
    iname="$(basename "$(dirname "$initrd")")-$(basename "$initrd").efi"
    # The real loader binary must sit at BOTH the systemd path and the EFI removable path: Apple
    # VZ boots the removable path, and every future `bootctl status` gates the next switch on
    # detecting systemd-boot here (version equality → the switch's update is a no-op).
    sdboot=${config.systemd.package}/lib/systemd/boot/efi/systemd-bootaa64.efi
    install -D -m 0644 "$sdboot" "$out/EFI/systemd/systemd-bootaa64.efi"
    install -D -m 0644 "$sdboot" "$out/EFI/BOOT/BOOTAA64.EFI"
    install -D -m 0644 "$kernel" "$out/EFI/nixos/$kname"
    install -D -m 0644 "$initrd" "$out/EFI/nixos/$iname"
    mkdir -p "$out/loader/entries"
    printf 'type1\n' > "$out/loader/entries.srel"
    printf 'timeout ${timeout}\ndefault nixos-generation-1.conf\nconsole-mode keep\n' \
      > "$out/loader/loader.conf"
    {
      printf 'title NixOS\nsort-key nixos\nversion Generation 1\n'
      printf 'linux /EFI/nixos/%s\ninitrd /EFI/nixos/%s\n' "$kname" "$iname"
      printf 'options init=${toplevel}/init %s\n' "$(cat ${toplevel}/kernel-params)"
    } > "$out/loader/entries/nixos-generation-1.conf"
  '';
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  image.repart = {
    name = "hermes";
    partitions = {
      # ESP first, root last (10-/20-) so the runtime growpart extends the trailing root
      # partition. mkfsOptions below sets the FILESYSTEM labels the by-label mounts need
      # (repartConfig.Label is GPT-only); the ESP stays a fixed 1G — systemd-boot parks the
      # kernel+initrd here per generation, and Minimize is flaky for vfat.
      "10-esp" = {
        contents."/".source = espContents;
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "ESP";
          SizeMinBytes = "1G";
          SizeMaxBytes = "1G";
        };
      };
      "20-root" = {
        storePaths = [ toplevel ];
        contents."/nix-path-registration".source =
          "${pkgs.closureInfo { rootPaths = [ toplevel ]; }}/registration";
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "nixos";
          Minimize = "guess";
        };
      };
    };
    mkfsOptions = {
      vfat = [ "-n" "ESP" ];
      ext4 = [ "-L" "nixos" ];
    };
  };
}
