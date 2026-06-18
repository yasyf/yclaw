# hermes VM — the agent gateway (NixOS). Adds to nixos/common.nix; do NOT redefine
# the base it already provides (boot, tailscale, sops base, admin user, nix, stateVersion).
#
# Two config surfaces:
#   * services.hermes-agent.settings  → ~/.hermes/config.yaml  (NO secrets; managed-mode declarative)
#   * services.hermes-agent.environmentFiles → ~/.hermes/.env   (runtime proxy/CA/BlueBubbles wiring)
#
# The agent reaches the internet ONLY through agent-vault's MITM forward proxy
# (HTTPS_PROXY), which injects the real API keys on the wire. The hermes VM holds
# none of those keys — the sole real secret that lands here is BLUEBUBBLES_PASSWORD
# (BlueBubbles is in NO_PROXY, so it cannot be wire-injected — see env section).
{
  config,
  pkgs,
  inputs,
  ...
}:
let
  # --- Non-secret .env (proxy + CA trust + BlueBubbles wiring) ------------------
  # Rendered to the Nix store (world-readable) — safe because it holds NO secret.
  # BLUEBUBBLES_PASSWORD is the one secret and lives in the sops "hermes/env" file,
  # appended AFTER this file (environmentFiles order), so the secret never hits the store.
  hermesEnvFile = pkgs.writeText "hermes.env" ''
    HTTPS_PROXY=http://metal:14322
    HTTP_PROXY=http://metal:14322
    NO_PROXY=ai,metal,bluebubbles,.ts.net,localhost,127.0.0.1
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
    # Dummy API keys. The SDKs refuse to send a request with an empty key, so each
    # must be non-empty to initialize; agent-vault's MITM proxy OVERWRITES the
    # Authorization header with the real, custody-held key on the wire — even if the
    # client sends Authorization: Bearer dummy, the broker replaces it.
    # api.openai.com / api.exa.ai / api.honcho.dev are NOT in NO_PROXY, so they route
    # through the vault proxy and get injected. The dummy also harmlessly rides the
    # custom-provider call to http://ai (Aperture ignores inbound auth, injects per-upstream).
    # TODO(human): confirm each SDK honors HTTPS_PROXY (so vault can intercept) — Exa/Honcho/OpenAI.
    OPENAI_API_KEY=__openai__
    EXA_API_KEY=__exa__
    HONCHO_API_KEY=__honcho__
    BLUEBUBBLES_SERVER_URL=https://bluebubbles
    BLUEBUBBLES_WEBHOOK_HOST=hermes
    BLUEBUBBLES_WEBHOOK_PORT=8645
    BLUEBUBBLES_WEBHOOK_PATH=/bluebubbles-webhook
    BLUEBUBBLES_REQUIRE_MENTION=false
    BLUEBUBBLES_ALLOW_ALL_USERS=false
  '';

  # --- BlueBubbles readiness gate (race-fix) -----------------------------------
  # The hermes-agent module has NO built-in readiness poll. BlueBubbles runs on a
  # separate macOS VM reached via `tailscale serve https`; if hermes starts first
  # the gateway crash-loops on connect. ExecStartPre blocks until BB answers.
  waitForBlueBubbles = pkgs.writeShellScript "wait-for-bluebubbles" ''
    set -uo pipefail
    # /api/v1/server/info needs the password and returns 401 without it — but a 401 still
    # means the server is UP. So check reachability (any HTTP response), NOT -f (which would
    # treat 401 as failure and wait forever). curl exits 0 on any response, non-zero only if
    # it can't connect at all.
    url="https://bluebubbles/api/v1/server/info"
    until ${pkgs.curl}/bin/curl -sS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
      echo "waiting for BlueBubbles at $url ..."
      sleep 5
    done
    echo "BlueBubbles is reachable."
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

  # --- Patched hermes-agent package (upstream fixes pulled from PRs) -----------
  # We rebuild the pinned package from patched source (no fork; reuses hermes-agent's
  # own nixpkgs + inputs). Each fix is an upstream PR, fetched as its `.diff` and applied
  # via `applyPatches`. A non-applying patch fails the build loudly on a rev bump — so the
  # pinned hash both verifies the download and pins the exact diff content we tested.
  #
  #   * PR #45717 — fix(bluebubbles): prevent duplicate processing and DM-to-group
  #     misrouting. Covers BOTH the DM-misroute privacy fix (issue #24157) and the
  #     double-send dedup (issues #34372/#30708):
  #       - _resolve_chat_guid no longer falls back to participant membership, so a bare
  #         handle can never resolve to a group chat (DM replies stop leaking into groups).
  #       - the webhook handler synthesizes the DM GUID (`any;-;<sender>`) for chat-less,
  #         non-group events, so the reply targets the 1:1.
  #       - drops `updated-message` from `_MESSAGE_EVENTS` AND the webhook subscription,
  #         plus a GUID-keyed dedup cache, so one iMessage is no longer processed twice.
  #   * PR #18366 — fix: make /busy command available on gateway platforms. Removes
  #     `cli_only=True` from the `busy` CommandDef and adds a gateway `_handle_busy_command`
  #     + dispatch, so `/busy` works on the BlueBubbles path (issue #18362).
  ha = inputs.hermes-agent;
  haSystem = pkgs.stdenv.hostPlatform.system;
  haPkgs = import ha.inputs.nixpkgs {
    system = haSystem;
    config.allowUnfree = true;
  };
  prPatch = num: hash: haPkgs.fetchpatch {
    url = "https://github.com/NousResearch/hermes-agent/pull/${toString num}.diff";
    inherit hash;
  };
  patchedHermesSrc = haPkgs.applyPatches {
    name = "hermes-agent-src-patched";
    src = ha;
    patches = [
      (prPatch 45717 "sha256-odBb8kxvIjHue131FB0xAzIx0994BJjUe6cTwMeneH4=")
      (prPatch 18366 "sha256-Q28QQH/S5oWt2stDHIXfDBUnUCppN1q8B64LMmzx2Bc=")
    ];
  };
  patchedHermesAgent = haPkgs.callPackage "${patchedHermesSrc}/nix/hermes-agent.nix" {
    inherit (ha.inputs) uv2nix pyproject-nix pyproject-build-systems;
    npm-lockfile-fix = ha.inputs.npm-lockfile-fix.packages.${haSystem}.default;
    rev = ha.rev or null;
  };

  models = import ./models.nix;

  cfg = config.services.hermes-agent;
in
{
  networking.hostName = "hermes";

  # --- Persistent agent state externalized to the host -------------------------
  # /var/lib/hermes (the hermes-agent stateDir: honcho memory, sessions, ~/.hermes config) is
  # mounted from the host's ~/.yclaw/state/hermes over virtiofs (tag `hermesstate`, shared rw by
  # the tart-hermes runner in scripts/setup.sh). The state survives destroying/rebuilding the VM
  # and is covered by `just backup`. `nofail` so a host that boots hermes without the share (e.g.
  # an image smoke-build) degrades to ephemeral in-VM state instead of failing the boot.
  fileSystems."/var/lib/hermes" = {
    device = "hermesstate";
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  # --- Hermes agent gateway ----------------------------------------------------
  services.hermes-agent = {
    enable = true;

    # Rebuilt from patched source — see patchedHermesAgent above (DM-reply routing fix).
    package = patchedHermesAgent;

    # Appended into ~/.hermes/.env in order: non-secret first, sops secret last.
    # environmentFiles is `listOf str`, so coerce the writeText derivation to its
    # store-path string (the sops path is already a string).
    environmentFiles = [
      "${hermesEnvFile}"
      "/var/lib/node-config/node.env"
      config.sops.secrets."hermes/env".path
    ];

    # Full declarative config.yaml. Nix attrset,
    # deep-merged + rendered to ~/.hermes/config.yaml. No secrets here.
    settings = {
      # ── Model plane (all three models route through Aperture at http://ai/v1) ──
      model = {
        provider = "custom";
        default = "gpt-5.5";
        base_url = "http://ai/v1";
        # api_key/key_env UNSET — Aperture authenticates by tailnet identity (the source
        # node), not a presented bearer (verified: requests with a dummy `Bearer -` route
        # fine). The cliproxy upstream's real key is injected by Aperture, not by hermes.
      };
      fallback_providers = [
        {
          provider = "custom";
          model = "gemini-3-pro-preview";
          base_url = "http://ai/v1";
        }
        {
          provider = "custom";
          model = models.qwen;
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
        # TODO(human): the per-setting code-reading recommended `true`;
        #   the §10 ledger says deny-by-default. Following the
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
          # metal's tailnet name on :8765 — covered by .ts.net in NO_PROXY so it stays DIRECT.
          base_url = "http://metal:8765/v1";
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
  # The deploy flow fetches GET http://metal:14321/v1/mitm/ca.pem into
  # ./nixos/agent-vault-ca.pem (the committed file is the @@AGENT_VAULT_CA_PEM@@ placeholder; a
  # CA public cert is not a secret). Baked into the system trust store so rustls clients — which
  # ignore SSL_CERT_FILE and read only the system store — also trust the metal MITM proxy.
  security.pki.certificateFiles = [ ./agent-vault-ca.pem ];

  # --- In-VM Docker sandbox (terminal.backend = "docker") ----------------------
  virtualisation.docker.enable = true;
  # The hermes-agent service runs with a restricted systemd PATH that lacks the docker CLI,
  # so the code-execution tool's `docker` lookup fails ("Docker executable not found in PATH").
  # Put the docker client on the service PATH (verified: without this, execute_code errors).
  systemd.services.hermes-agent.path = [ config.virtualisation.docker.package ];
  # The hermes-agent module's default user is "hermes".
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
