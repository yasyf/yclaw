# Rendered artifact — NOT a NixOS host.
#
# Aperture is a HOSTED Tailscale service (the `ai` tailnet node); its config lives in
# the dashboard JSON editor at http://ai/ui -> Settings -> JSON editor. There is no
# machine to provision here. This derivation renders the Aperture `providers` config so
# it stays committed and reproducible; `just deploy-ai` prints it for paste into the
# dashboard.
#
# Routing is by string membership of the request `model` in a provider's `models` array;
# Aperture appends the full incoming request path to `baseurl` and injects `apikey` as the
# configured `authorization` header. See docs/build-notes/aperture-routing.md.
#
# TODO(human): confirm in the live Aperture dashboard that the gateway's MagicDNS hostname
#   is exactly `ai` (hermes reaches it at http://ai/v1), and that MagicDNS is enabled for
#   the tailnet. The architecture assumes the hostname is `ai`.
# TODO(human): the config-API verb/path was summarized by the fetch tool, not seen verbatim.
#   Do NOT assert `PUT /api/config` as fact — confirm the real endpoint from http://ai/ui
#   network calls or the JSON editor's export/import before scripting an apply step.
# TODO(human): record the CLIProxyAPI static key (@@APERTURE_STATIC_KEY@@) in the Aperture
#   dashboard, NOT in this flake — the Nix store is world-readable. The real key now comes from
#   the sops `aperture/static-key` secret (~/.yclaw/state/secrets.sops.yaml), not the Nix store;
#   the placeholder below is left unresolved on purpose and injected from sops at deploy time.
# TODO(human): the model ids `gpt-5.5` / `gemini-3.5` may be placeholders. Hit
#   `GET http://@@HOST_NAME@@.@@TAILNET_DOMAIN@@:8317/v1/models` after the Codex/Gemini
#   logins to read the real upstream ids; use those here directly or rename them via
#   CLIProxyAPI's `oauth-model-alias` block.
{ writeText, lib }:

writeText "aperture-providers.json" (builtins.toJSON {
  providers = {
    cliproxy = {
      name = "CLIProxyAPI (Codex + Gemini OAuth -> static key)";
      # HOST:PORT only — NO /v1. hermes sends /v1/... and Aperture appends the full path;
      # a trailing /v1 here doubles to /v1/v1/... (HTTP 405). gpt-5.5 and gemini-3.5 share
      # this entry: both route to CLIProxyAPI's unified /v1/chat/completions, which maps the
      # model id to the right OAuth account.
      baseurl = "http://@@HOST_NAME@@.@@TAILNET_DOMAIN@@:8317";
      models = [ "gpt-5.5" "gemini-3-pro-preview" ];
      apikey = "@@APERTURE_STATIC_KEY@@";
      authorization = "bearer";
      compatibility.openai_chat = true;
    };
    qwen-local = {
      name = "Local Qwen (mlx_lm.server)";
      baseurl = "http://@@HOST_NAME@@.@@TAILNET_DOMAIN@@:8080";
      models = [ "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit" ];
      compatibility.openai_chat = true;
    };
  };
})
