# OCI image for the container-native `vault` node (creds custodian). Self-contained; deploy
# converts the docker-archive with plain skopeo (see pkgs/hermes-agent-image/image.nix).
{ pkgs }:
let
  machinesManifest = builtins.fromJSON (builtins.readFile ../../machines.json);
  # Pinned magicsock port — container-pf's WG carve-out is dest-port-keyed; never a literal.
  wireguardPort = machinesManifest.machines.host.wireguard_port;

  # Everything the entrypoint invokes by bare name (config.Env PATH points here). Link ONLY
  # /bin: the rootfs owns /etc, and letting buildEnv symlink /etc too collides.
  runtimeEnv = pkgs.buildEnv {
    name = "vault-container-runtime";
    pathsToLink = [ "/bin" ];
    paths = [
      pkgs.agent-vault
      pkgs.cli-proxy-api
      pkgs.socat
      pkgs.tailscale
      pkgs.curl
      pkgs.gnugrep
      pkgs.gnused
      pkgs.coreutils # base64 (decode the env-file secrets), install, mktemp
      pkgs.util-linux # setpriv (privilege drop)
      pkgs.bash
      pkgs.tini
    ];
  };

  # The minimal image rootfs has NO /etc — bake the load-bearing paths.
  rootfs = pkgs.runCommand "vault-container-rootfs" { } ''
    mkdir -p $out/etc/ssl/certs $out/run $out/var/run/tailscale $out/var/lib/vault $out/root
    chmod 700 $out/root

    # The literal path every CA env consumer points at.
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt

    # tailscale rewrites /etc/resolv.conf at runtime over the writable overlay; empty placeholder.
    : > $out/etc/resolv.conf

    # root + vault (1000: agent-vault, reads master-password) + proxy (1001: cliproxy/relays,
    # no group 0, no master-password); bind-mount file access is host-enforced for either uid,
    # so proxy still writes its cliproxy state (cc-notes ca8ac58f).
    printf 'root:x:0:0:root:/root:/bin/sh\nvault:x:1000:1000:vault services:/var/lib/vault:/bin/sh\nproxy:x:1001:1001:proxy services:/var/lib/vault:/bin/sh\n' \
      > $out/etc/passwd
    printf 'root:x:0:\nvault:x:1000:\nproxy:x:1001:\n' > $out/etc/group

    install -Dm755 ${./entrypoint.sh} $out/entrypoint.sh
    install -Dm755 ${./mint-hermes-token.sh} $out/mint-hermes-token.sh
  '';
in
# Run reference (bind mounts + --cap-add NET_ADMIN): scripts/host/container-vault.sh.
pkgs.dockerTools.streamLayeredImage {
  name = "vault";
  tag = "latest";
  contents = [
    rootfs
    runtimeEnv
  ];
  # /tmp needs the sticky bit; set it here so tar preserves the mode (store perms would drop it).
  extraCommands = "mkdir -m 1777 tmp";
  config = {
    # tini PID 1 (-g: signal the whole group so the svc loops die on stop).
    Cmd = [
      "${runtimeEnv}/bin/tini"
      "-g"
      "--"
      "${runtimeEnv}/bin/bash"
      "/entrypoint.sh"
    ];
    Env = [
      "PATH=${runtimeEnv}/bin"
      "HOME=/root"
      "CLIPROXY_CONFIG_TEMPLATE=${./cliproxyapi-config.yaml}"
      "VAULT_SERVICES_YAML=${../../nixos/vault-services.yaml}"
      "TS_WG_PORT=${toString wireguardPort}"
      "container=oci"
    ];
    User = "0";
  };
}
