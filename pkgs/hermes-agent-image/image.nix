# OCI image for the container-native hermes-agent (Architecture B). dockerTools emits a
# Docker-format archive, but apple/container's `image load` needs OCI-layout — the deploy
# step converts with PLAIN skopeo (n2c's patched skopeo is the broken one, not this path):
#   skopeo --insecure-policy copy docker-archive:IN.tar oci-archive:OUT.tar:hermes-agent:latest
# Built on the aarch64-linux hermes guest; the OCI archive is loaded on the host.
#
# The agent, its config.yaml, and the static env layer are derived from the SAME evaluated
# `services.hermes-agent` the VM uses (hermesConfig below) — zero drift, no duplicated settings.
{
  pkgs,
  hermesConfig,
}:
let
  agent = hermesConfig.package;
  stateDir = hermesConfig.stateDir;
  hermesHome = "${stateDir}/.hermes";

  # builtins.toJSON of the exact declarative settings; the entrypoint merges it to config.yaml.
  settingsJson = pkgs.writeText "hermes-config.json" (builtins.toJSON hermesConfig.settings);

  # environmentFiles[0] IS the module's hermesEnvFile store path (nixos/hermes.nix), the .env
  # layer-1 static block — reused verbatim so the container and VM never diverge.
  staticEnv = builtins.head hermesConfig.environmentFiles;

  # Everything the entrypoint and agent invoke by bare name (config.Env PATH points here).
  # Link ONLY /bin: the rootfs owns /etc, and letting buildEnv symlink /etc too collides.
  # Binaries resolve their libs by store RPATH.
  runtimeEnv = pkgs.buildEnv {
    name = "hermes-container-runtime";
    pathsToLink = [ "/bin" ];
    paths = [
      agent
      pkgs.docker # the client CLI; talks to the mounted hermes-docker-proxy socket
      pkgs.tailscale # tailscale + tailscaled (overlay pins the current release)
      pkgs.sops
      pkgs.coreutils
      pkgs.util-linux # setpriv (privilege drop)
      (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
      pkgs.bash
      pkgs.tini
    ];
  };

  # The minimal image rootfs has NO /etc — bake the load-bearing paths.
  rootfs = pkgs.runCommand "hermes-container-rootfs" { } ''
    mkdir -p \
      $out/etc/ssl/certs $out/run $out/var/run/tailscale \
      $out${hermesHome} $out${builtins.dirOf hermesHome} $out/root
    chmod 700 $out/root

    # The literal path every CA env var in the static env points at.
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt

    # tailscale rewrites /etc/resolv.conf at runtime over the writable overlay; empty placeholder.
    : > $out/etc/resolv.conf

    # root + the unprivileged hermes user (uid/gid 1000) the agent drops to. The host proxy socket
    # is gid 1000, but the idmap presents it as guest root:root — the entrypoint drop carries group
    # 0 so the agent can connect(). cc-notes ca8ac58f.
    printf 'root:x:0:0:root:/root:/bin/sh\nhermes:x:1000:1000:hermes agent:${stateDir}:/bin/sh\n' \
      > $out/etc/passwd
    printf 'root:x:0:\nhermes:x:1000:\n' > $out/etc/group

    install -Dm755 ${./entrypoint.sh} $out/entrypoint.sh
  '';
in
# Reference for the supervisor (Phase 2f). The proxy socket bind is the da1c63 surface; the idmap
# maps its host gid 1000 to guest root:root, so the entrypoint drop carries group 0 to connect()
# (cc-notes ca8ac58f). The real tun needs --cap-add NET_ADMIN (verified: TUN_CREATE_OK).
#
#   container run --name hermes --cap-add NET_ADMIN \
#     --network <custom-non-nat-net> \
#     --volume ~/.yclaw/state/hermes:/var/lib/hermes \
#     --volume ~/.yclaw/state/hermes-ts-state:/var/lib/tailscale \
#     --volume ~/.yclaw/state/hosts/hermes/key.txt:/run/secrets/age-key:ro \
#     --volume ~/.yclaw/state/hosts/hermes/secrets.sops.yaml:/run/secrets/secrets.sops.yaml:ro \
#     --volume ~/.yclaw/state/hosts/hermes/node.env:/run/config/node.env:ro \
#     --volume ~/.yclaw/state/hosts/hermes/agent-vault-token:/run/secrets/agent-vault-token:ro \
#     --volume /run/hermes-docker-proxy/docker.sock:/run/hermes-docker-proxy/docker.sock \
#     hermes-agent:latest
pkgs.dockerTools.streamLayeredImage {
  name = "hermes-agent";
  tag = "latest";
  contents = [ rootfs runtimeEnv ];
  # /tmp needs the sticky bit; set it here so tar preserves the mode (store perms would drop it).
  extraCommands = "mkdir -m 1777 tmp";
  config = {
    # tini PID 1 (-g: signal the whole group so the tailscaled loop dies on stop).
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
      "HERMES_STATE_DIR=${stateDir}"
      "HERMES_HOME=${hermesHome}"
      "HERMES_STATIC_ENV=${staticEnv}"
      "HERMES_CONFIG_JSON=${settingsJson}"
      "container=oci"
    ];
    User = "0";
  };
}
