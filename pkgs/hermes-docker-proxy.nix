# hermes-docker-proxy — the default-deny Docker-socket filter that lets the hermes
# agent run code-exec containers WITHOUT docker-group (root-equivalent) access
# (security finding H6). Pure-stdlib Go (no module deps -> vendorHash = null),
# CGO-free, so it cross-builds for aarch64-linux (the VM) and aarch64-darwin
# (local verification). Source + the screening policy's unit tests live in
# ./hermes-docker-proxy; doCheck runs them at build time.
{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "hermes-docker-proxy";
  version = "0.1.0";

  src = ./hermes-docker-proxy;

  # No external imports — the module graph is empty, so there is nothing to vendor.
  vendorHash = null;

  env.CGO_ENABLED = "0";
  subPackages = [ "." ];

  # Run the policy unit tests (route allowlist + create-body screening) as part of
  # the build — a regression in the screen fails `nix build`, not just CI.
  doCheck = true;

  meta = {
    description = "Default-deny filtering proxy in front of the Docker socket (yclaw H6)";
    mainProgram = "hermes-docker-proxy";
    platforms = lib.platforms.unix;
  };
}
