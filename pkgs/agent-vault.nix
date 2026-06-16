# Infisical agent-vault — the credential broker for the `vault` VM.
# Pure-Go (modernc SQLite, CGO_ENABLED=0). Source pinned via the flake input
# `agent-vault-src`; see docs/build-notes/agent-vault.md for the authoritative extraction.
{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "agent-vault";
  # Research preview — pinned to 30ff25ce8f3c8cfd855e4e2d3e7713bb0b007eed.
  version = "0-unstable-2026-06-14";

  inherit src;

  # go.sum is committed, so the module graph is fixed. The real hash is printed by
  # the first `nix build`; bootstrap.sh substitutes it.
  vendorHash = "sha256-tGvx2+2ZaKX6zymxvgALCPyvzKiUlL7Rbzpl7O/F4vg=";

  env.CGO_ENABLED = "0";

  # main package is the module root (Dockerfile: `go build -o /agent-vault` with no path).
  subPackages = [ "." ];

  # The Go binary embeds the Vite frontend at internal/server/webdist via //go:embed.
  # That dir is produced by `npm run build` (web/) and is NOT checked in, so a headless
  # build needs the dir to exist. A stub index.html satisfies the embed for an API+proxy-only
  # deployment (we never serve the UI). VERIFIED: the package builds with this stub.
  preBuild = ''
    if [ ! -e internal/server/webdist/index.html ]; then
      mkdir -p internal/server/webdist
      printf '<!doctype html><title>agent-vault</title>' > internal/server/webdist/index.html
    fi
  '';

  # Version stamping is optional (Dockerfile injects it); omitted — does not affect runtime.

  meta = {
    description = "Infisical agent-vault: TLS-terminating credential broker (static keys + OAuth)";
    homepage = "https://github.com/Infisical/agent-vault";
    license = lib.licenses.mit;
    mainProgram = "agent-vault";
    platforms = lib.platforms.linux;
  };
}
