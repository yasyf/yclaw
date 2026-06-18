# CLIProxyAPI — the host-side OAuth→static-key proxy (Codex + Gemini-personal).
# Runs on the macOS host (aarch64-darwin) under launchd; built via buildGoModule.
# Source pinned via the flake input `cliproxyapi-src`.
{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "cli-proxy-api";
  # Pinned to bbef8da454c88ad09d6e589f7ddce5ed2eeddb51 (module path .../v7).
  version = "7-unstable-2026-06-15";

  inherit src;

  vendorHash = "sha256-AIue9XBsfsKGClRLB1DCME+36crapnOdQrEICFYG1a0=";

  # Upstream and the release workflow both build with cgo enabled.
  env.CGO_ENABLED = "1";

  # Build only the server entrypoint (`go build ./cmd/server`).
  subPackages = [ "cmd/server" ];

  # buildGoModule names the binary after the package dir (`server`); upstream ships it
  # as `cli-proxy-api`, which is the name darwin/host.nix and the architecture doc invoke.
  postInstall = ''
    mv "$out/bin/server" "$out/bin/cli-proxy-api"
  '';

  meta = {
    description = "CLIProxyAPI: OAuth-in/static-key-out OpenAI-compatible proxy for Codex + Gemini";
    homepage = "https://github.com/router-for-me/CLIProxyAPI";
    license = lib.licenses.mit;
    mainProgram = "cli-proxy-api";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
