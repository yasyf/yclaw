# hermes VM — the agent gateway (NixOS). Adds to nixos/common.nix; do NOT redefine
# the base it already provides (boot, tailscale, sops base, admin user, nix, stateVersion).
#
# Two config surfaces (docs/build-notes/hermes-config-values.md):
#   * services.hermes-agent.settings  → ~/.hermes/config.yaml  (NO secrets; managed-mode declarative)
#   * services.hermes-agent.environmentFiles → ~/.hermes/.env   (runtime proxy/CA/BlueBubbles wiring)
#
# The agent reaches the internet ONLY through agent-vault's MITM forward proxy
# (HTTPS_PROXY), which injects the real API keys on the wire. The hermes VM holds
# none of those keys — the sole real secret that lands here is BLUEBUBBLES_PASSWORD
# (BlueBubbles is in NO_PROXY, so it cannot be wire-injected — see env section).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # --- Non-secret .env (proxy + CA trust + BlueBubbles wiring) ------------------
  # Rendered to the Nix store (world-readable) — safe because it holds NO secret.
  # BLUEBUBBLES_PASSWORD is the one secret and lives in the sops "hermes/env" file,
  # appended AFTER this file (environmentFiles order), so the secret never hits the store.
  hermesEnvFile = pkgs.writeText "hermes.env" ''
    HTTPS_PROXY=http://vault.@@TAILNET_DOMAIN@@:14322
    HTTP_PROXY=http://vault.@@TAILNET_DOMAIN@@:14322
    NO_PROXY=ai,.ts.net,localhost,127.0.0.1,@@HOST_NAME@@.@@TAILNET_DOMAIN@@,bluebubbles.@@TAILNET_DOMAIN@@
    SSL_CERT_FILE=/etc/ssl/agent-vault-ca.pem
    NODE_EXTRA_CA_CERTS=/etc/ssl/agent-vault-ca.pem
    REQUESTS_CA_BUNDLE=/etc/ssl/agent-vault-ca.pem
    CURL_CA_BUNDLE=/etc/ssl/agent-vault-ca.pem
    GIT_SSL_CAINFO=/etc/ssl/agent-vault-ca.pem
    # Dummy API keys. The SDKs refuse to send a request with an empty key, so each
    # must be non-empty to initialize; agent-vault's MITM proxy OVERWRITES the
    # Authorization header with the real, custody-held key on the wire (agent-vault.md
    # §2: "even if the client sends Authorization: Bearer dummy, the broker replaces it").
    # api.openai.com / api.exa.ai / api.honcho.dev are NOT in NO_PROXY, so they route
    # through the vault proxy and get injected. The dummy also harmlessly rides the
    # custom-provider call to http://ai (Aperture ignores inbound auth, injects per-upstream).
    # TODO(human): confirm each SDK honors HTTPS_PROXY (so vault can intercept) — Exa/Honcho/OpenAI.
    OPENAI_API_KEY=__openai__
    EXA_API_KEY=__exa__
    HONCHO_API_KEY=__honcho__
    BLUEBUBBLES_SERVER_URL=https://bluebubbles.@@TAILNET_DOMAIN@@
    BLUEBUBBLES_WEBHOOK_HOST=hermes.@@TAILNET_DOMAIN@@
    BLUEBUBBLES_WEBHOOK_PORT=8645
    BLUEBUBBLES_WEBHOOK_PATH=/bluebubbles-webhook
    BLUEBUBBLES_REQUIRE_MENTION=false
    BLUEBUBBLES_ALLOWED_USERS=@@AUTHORIZED_HANDLES@@
    BLUEBUBBLES_ALLOW_ALL_USERS=false
    BLUEBUBBLES_HOME_CHANNEL=@@AUTHORIZED_HANDLES@@
  '';

  # --- BlueBubbles readiness gate (race-fix, tart-nixos-darwin.md §4.3) ---------
  # The hermes-agent module has NO built-in readiness poll. BlueBubbles runs on a
  # separate macOS VM reached via `tailscale serve https`; if hermes starts first
  # the gateway crash-loops on connect. ExecStartPre blocks until BB answers.
  waitForBlueBubbles = pkgs.writeShellScript "wait-for-bluebubbles" ''
    set -euo pipefail
    url="https://bluebubbles.@@TAILNET_DOMAIN@@/api/v1/server/info"
    until ${pkgs.curl}/bin/curl -fsS --max-time 5 "$url" >/dev/null 2>&1; do
      echo "waiting for BlueBubbles at $url ..."
      sleep 5
    done
    echo "BlueBubbles is ready."
  '';

  # --- Honcho activation file (~/.honcho/config.json) --------------------------
  # Honcho is NOT configured via config.yaml's `memory:` block — it reads its own
  # ~/.honcho/config.json (doctor.py: "set enabled: true … to activate"). HOME for
  # the hermes user is stateDir, so the path is ${stateDir}/.honcho/config.json.
  # The HONCHO_API_KEY env (dummy) satisfies the api_key requirement; vault injects
  # the real key on api.honcho.dev. Cadence values are the architecture's starting
  # point (hybrid / depth 1 / context 2 / dialectic 3 / low).
  # TODO(human): the cadence mapping has an unresolved value conflict between the §10
  #   ledger (positional) and the catalog's per-setting recs — confirm the intended
  #   (key → value) mapping, and confirm the full honcho config.json schema (the
  #   verified keys are enabled/recallMode/writeFrequency/sessionStrategy).
  honchoConfig = pkgs.writeText "honcho-config.json" (builtins.toJSON {
    enabled = true;
    recallMode = "hybrid";
    dialecticDepth = 1;
    contextCadence = 2;
    dialecticCadence = 3;
    dialecticReasoningLevel = "low";
  });

  cfg = config.services.hermes-agent;
in
{
  networking.hostName = "hermes";

  # --- Hermes agent gateway ----------------------------------------------------
  services.hermes-agent = {
    enable = true;

    # Appended into ~/.hermes/.env in order: non-secret first, sops secret last.
    # environmentFiles is `listOf str`, so coerce the writeText derivation to its
    # store-path string (the sops path is already a string).
    environmentFiles = [
      "${hermesEnvFile}"
      config.sops.secrets."hermes/env".path
    ];

    # Full declarative config.yaml (hermes-config-values.md Part A). Nix attrset,
    # deep-merged + rendered to ~/.hermes/config.yaml. No secrets here.
    settings = {
      # ── Model plane (all three models route through Aperture at http://ai/v1) ──
      model = {
        provider = "custom";
        default = "gpt-5.5";
        base_url = "http://ai/v1";
        # api_key/key_env UNSET — Aperture is tailnet-gated.
        # TODO(human): confirm whether Aperture requires a presented key on the
        #   hermes side; if so set key_env to APERTURE_STATIC_KEY (@@APERTURE_STATIC_KEY@@).
      };
      fallback_providers = [
        {
          provider = "custom";
          model = "gemini-3.5";
          base_url = "http://ai/v1";
        }
        {
          provider = "custom";
          model = "qwen-local";
          base_url = "http://ai/v1";
        }
      ];

      # ── Agent behaviour / loop budget ──
      agent = {
        max_turns = 90;
        api_max_retries = 1;
        reasoning_effort = "medium";
        verbose = false;
        image_input_mode = "auto";
      };

      # ── Terminal / Docker sandbox ──
      terminal = {
        backend = "docker";
        cwd = "/workspace";
        # Sane default (hermes's own example image: Python 3.11 + Node 20).
        # TODO(human): pin a digest (…@sha256:…) or your own image for determinism.
        docker_image = "nikolaik/python-nodejs:python3.11-nodejs20";
        container_cpu = 2;
        container_memory = 8192;
        container_disk = 51200;
        container_persistent = true;
        docker_run_as_host_user = true;
        docker_mount_cwd_to_workspace = false;
        lifetime_seconds = 900;
        home_mode = "auto";
        timeout = 180;
        docker_forward_env = [ ];
        docker_extra_args = [ ];
        env_passthrough = [ ];
      };

      # ── Security ──
      security = {
        # Deny-by-default per the locked §10 ledger ("Private URLs | deny by default,
        # allowlist internal hosts | 🔒"). This is the SSRF guard on the agent's
        # URL-fetching tools (web_fetch/web_extract/browser) — it does NOT gate the
        # configured model (http://ai) or STT (host:8765) provider endpoints, so the
        # core stack still works. Allowlist specific internal hosts as you need them.
        # TODO(human): the catalog's per-setting code-reading (hermes-config-values.md)
        #   recommended `true`; the §10 ledger says deny-by-default. Following the
        #   ledger. Confirm — and if the agent must browse internal hosts, add them to
        #   the allowlist rather than flipping this global flag.
        allow_private_urls = false;
        allow_lazy_installs = false;
        redact_secrets = true;
        tirith_enabled = false;
        website_blocklist.enabled = false;
      };

      tool_loop_guardrails = {
        warnings_enabled = true;
        hard_stop_enabled = true;
        warn_after = {
          exact_failure = 2;
          same_tool_failure = 3;
          idempotent_no_progress = 2;
        };
        hard_stop_after = {
          exact_failure = 5;
          same_tool_failure = 8;
          idempotent_no_progress = 5;
        };
      };

      # ── Browser (local in-VM Chromium) ──
      browser = {
        allow_private_urls = false;
        inactivity_timeout = 120;
        record_sessions = false;
      };

      # ── Web search & extract (Exa; EXA_API_KEY injected by vault) ──
      web.backend = "exa";

      # ── Memory: built-in curated notes (MEMORY.md/USER.md) ──
      # These are the ONLY valid keys in the `memory:` block (cli-config.yaml.example).
      # Honcho is a SEPARATE plugin: it is NOT `memory.provider` (no such key) — it is
      # activated by `enabled: true` in ${HERMES_HOME-sibling}/.honcho/config.json,
      # provisioned below, plus the HONCHO_API_KEY env (dummy; vault injects the real key).
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
        memory_char_limit = 2200;
        user_char_limit = 1375;
        nudge_interval = 10;
        flush_min_turns = 6;
      };
      # Optional Hermes-side Honcho overrides; most config lives in ~/.honcho/config.json.
      honcho = { };

      # ── STT: Parakeet on the host via an OpenAI-compatible shim ──
      stt = {
        enabled = true;
        provider = "openai";
        openai = {
          # Host's tailnet name on :8765 — added to NO_PROXY so it stays DIRECT.
          base_url = "http://@@HOST_NAME@@.@@TAILNET_DOMAIN@@:8765/v1";
          api_key = "local";
          model = "whisper-1";
        };
      };

      # ── TTS: Piper (local VITS, no key) ──
      tts = {
        provider = "piper";
        piper = {
          voice = "en_US-lessac-medium";
          use_cuda = false;
          length_scale = 1.0;
        };
      };

      # ── Image generation: OpenAI gpt-image-2 (OPENAI_API_KEY injected by vault) ──
      image_gen = {
        provider = "openai";
        openai.model = "gpt-image-2-medium";
        use_gateway = false;
      };

      # ── Auxiliary slot routing ──
      # compression → main (= http://ai); vision + web_extract → openai key (via vault).
      auxiliary = {
        compression.provider = "main";
        vision.provider = "openai";
        web_extract.provider = "openai";
      };

      # ── Compression thresholds ──
      compression = {
        enabled = true;
        threshold = 0.50;
        target_ratio = 0.20;
        protect_last_n = 20;
        protect_first_n = 3;
      };

      # ── Skills & autonomy ──
      skills = {
        creation_nudge_interval = 10;
        write_approval = false;
        guard_agent_created = false;
      };
      curator = {
        enabled = true;
        prune_builtins = true;
      };
      delegation = {
        max_iterations = 50;
        subagent_auto_approve = true;
        max_spawn_depth = 1;
      };

      # ── Privacy ──
      privacy.redact_pii = true;

      # ── Platform toolsets (locked stack: CLI + BlueBubbles only) ──
      platform_toolsets = {
        cli = [ "hermes-cli" ];
        # hermes-telegram is the standard full messaging bundle (terminal, file,
        # web, vision, image_gen, tts, browser, skills, todo, cronjob, send_message).
        # TODO(human): pick hermes-telegram bundle vs an explicit list.
        bluebubbles = [ "hermes-telegram" ];
      };

      # ── LSP (Nix-provided servers; nothing self-installs) ──
      lsp = {
        enabled = true;
        install_strategy = "manual";
        wait_mode = "document";
        wait_timeout = 5.0;
        # TODO(human): enumerate the language servers to ship via Nix (incl. nixd)
        #   and pin each servers.<id>.command to its Nix store path.
      };

      # ── Dashboard: tailnet-only, loopback bind → no auth gate engages ──
      # Launch flags live in the systemd unit, not here. There is no dashboard.enabled key.
      # TODO(human): if you ever bind to the VM's tailnet IP that counts as PUBLIC
      #   and forces an auth provider.
      dashboard = { };

      # ── Plugins (image_gen/openai only; observability stays OFF) ──
      plugins.enabled = [ "image_gen/openai" ];

      # ── Logging ──
      logging.level = "INFO";
    };
  };

  # BLUEBUBBLES_PASSWORD is the one real secret that lands in the hermes VM by
  # design: BlueBubbles is in NO_PROXY, so agent-vault cannot inject its credential
  # on the wire. The encrypted sops "hermes/env" carries it (BLUEBUBBLES_PASSWORD=
  # @@BLUEBUBBLES_PASSWORD@@) and is appended last into ~/.hermes/.env.
  # TODO(human): confirm this is acceptable vs the DoD "no real secret in hermes VM"
  #   stance — if not, route BlueBubbles through the proxy or a non-NO_PROXY path.
  sops.secrets."hermes/env" = { };

  # --- agent-vault MITM CA → OS trust store ------------------------------------
  # Rust/rustls clients (the `gws` Google CLI) IGNORE SSL_CERT_FILE and read only
  # the system store, so the .env CA vars are necessary but NOT sufficient.
  # TODO(human): bootstrap fetches GET http://vault.@@TAILNET_DOMAIN@@:14321/v1/mitm/ca.pem
  #   into ./nixos/agent-vault-ca.pem and commits the PUBLIC PEM (a CA cert is not a secret).
  security.pki.certificateFiles = [ ./agent-vault-ca.pem ];

  # --- In-VM Docker sandbox (terminal.backend = "docker") ----------------------
  virtualisation.docker.enable = true;
  # The hermes-agent module's default user is "hermes" (hermes-nixos-module.md §2).
  # TODO(human): confirm the module's user name is "hermes" before relying on this group.
  users.users.hermes.extraGroups = [ "docker" ];

  # --- Honcho config provisioning (symlink to the flake-rendered file) ---------
  # L+ keeps it always matching the flake (managed mode → config is declarative).
  systemd.tmpfiles.rules = [
    "d ${cfg.stateDir}/.honcho 0750 ${cfg.user} ${cfg.group} - -"
    "L+ ${cfg.stateDir}/.honcho/config.json - - - - ${honchoConfig}"
  ];

  # --- BlueBubbles readiness gate ----------------------------------------------
  # List-wrapped so a future second ExecStartPre appends cleanly (a bare scalar
  # would merge awkwardly with a later list def).
  systemd.services.hermes-agent.serviceConfig.ExecStartPre = [ waitForBlueBubbles ];
}
