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
# configured `authorization` header.
#
# Setup notes:
# - The gateway's MagicDNS hostname must be `ai` (hermes reaches it at http://ai/v1), with
#   MagicDNS enabled for the tailnet.
# - The CLIProxyAPI static key (@@APERTURE_STATIC_KEY@@) is recorded in the Aperture dashboard,
#   NOT baked into this flake (the Nix store is world-readable). It comes from the sops
#   `aperture/static-key` secret and is injected at deploy time; the placeholder stays unresolved.
# - Resolve the real upstream model ids after the Codex/Gemini logins via
#   `GET http://metal:8317/v1/models`, then use them here or alias via
#   CLIProxyAPI's `oauth-model-alias` block.
{ writeText, lib }:

let
  models = import ./models.nix;
in
writeText "aperture-providers.json" (builtins.toJSON {
  providers = {
    cliproxy = {
      name = "CLIProxyAPI (Codex + Gemini OAuth -> static key)";
      # HOST:PORT only — NO /v1. hermes sends /v1/... and Aperture appends the full path;
      # a trailing /v1 here doubles to /v1/v1/... (HTTP 405). gpt-5.5 and gemini-3.5 share
      # this entry: both route to CLIProxyAPI's unified /v1/chat/completions, which maps the
      # model id to the right OAuth account.
      baseurl = "http://metal:8317";
      models = [ "gpt-5.5" "gemini-3-pro-preview" ];
      apikey = "@@APERTURE_STATIC_KEY@@";
      authorization = "bearer";
      compatibility.openai_chat = true;
    };
    qwen-local = {
      name = "Local Qwen (omlx)";
      baseurl = "http://metal:8000";
      # omlx derives the model id from the HF cache dir, replacing "/" with "--"
      # (verified: mlx-community/Qwen3-4B-4bit-DWQ -> mlx-community--Qwen3-4B-4bit-DWQ).
      models = [ models.qwen ];
      compatibility.openai_chat = true;
    };
  };
})
