# hermes VM — the agent gateway (NixOS). Adds to nixos/common.nix; do NOT redefine
# the base it already provides (boot, tailscale, sops base, admin user, nix, stateVersion).
#
# Two config surfaces:
#   * services.hermes-agent.settings  → ~/.hermes/config.yaml  (NO secrets; managed-mode declarative)
#   * services.hermes-agent.environmentFiles → ~/.hermes/.env   (runtime proxy/CA/BlueBubbles wiring)
#
# The agent reaches the internet ONLY through agent-vault's MITM forward proxy
# (HTTPS_PROXY), which injects the real API keys on the wire. The proxy URL carries the
# per-host agent-vault PROXY TOKEN (http://<token>:hermes@metal:14322) — minted from metal at
# bootstrap and rendered into /var/lib/node-config/agent-vault-proxy.env by the activation
# script below (the token is the custody-plane credential that authorizes injection on the
# matched hosts; without it agent-vault 407s every brokered request). The hermes VM holds
# none of the upstream API keys — the sole real secret that lands here is BLUEBUBBLES_PASSWORD
# (BlueBubbles is in NO_PROXY, so it cannot be wire-injected — see env section).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # Single source of truth for host->secret ownership (nixos/secrets-manifest.json). The
  # sops.secrets read-selectors below derive from it, so they can never drift from the
  # encryption scope scripts/lib/secrets.sh applies.
  manifest = builtins.fromJSON (builtins.readFile ./secrets-manifest.json);

  # --- Non-secret .env (proxy + CA trust + BlueBubbles wiring) ------------------
  # Rendered to the Nix store (world-readable) — safe because it holds NO secret.
  # BLUEBUBBLES_PASSWORD is the one secret and lives in the sops "hermes/env" file,
  # appended AFTER this file (environmentFiles order), so the secret never hits the store.
  hermesEnvFile = pkgs.writeText "hermes.env" ''
    NO_PROXY=ai,metal,bluebubbles,.ts.net,localhost,127.0.0.1
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
    # H6: the agent's docker CLI talks to the FILTERED socket (hermes-docker-proxy),
    # not the real /run/docker.sock — hermes is no longer in the docker group. The
    # proxy default-denies everything except the code-exec calls and screens every
    # container-create body (no host-root binds / privileged / runc / host-ns). See
    # the hermes-docker-proxy service below.
    DOCKER_HOST=unix:///run/hermes-docker-proxy/docker.sock
    # Dummy API keys. The SDKs refuse to send a request with an empty key, so each
    # must be non-empty to initialize; agent-vault's MITM proxy OVERWRITES the
    # Authorization header with the real, custody-held key on the wire — even if the
    # client sends Authorization: Bearer dummy, the broker replaces it.
    # api.openai.com / api.exa.ai / api.honcho.dev are NOT in NO_PROXY, so they route
    # through the vault proxy and get injected. The model (custom provider) call rides no
    # dummy and no bearer: it reaches metal's cliproxy directly on :8317, which is pf-gated to
    # hermes + the host ("the tailnet is the auth"), so the model plane needs no key_env.
    # TODO(human): confirm each SDK honors HTTPS_PROXY (so vault can intercept) — Exa/Honcho/OpenAI.
    OPENAI_API_KEY=__openai__
    EXA_API_KEY=__exa__
    HONCHO_API_KEY=__honcho__
    # BLUEBUBBLES_SERVER_URL + BLUEBUBBLES_WEBHOOK_HOST are deliberately NOT set here. Unlike
    # metal's HTTP services (bare `metal` is fine), these two need the node FQDN:
    #   * the BlueBubbles server is reached over `tailscale serve https`, whose Let's Encrypt cert
    #     is for `bluebubbles.<tailnet>` only — bare `bluebubbles` fails the TLS handshake (SNI).
    #   * the webhook server binds to BLUEBUBBLES_WEBHOOK_HOST; bare `hermes` resolves to 127.0.0.2
    #     (/etc/hosts) so it would bind to loopback, unreachable by BlueBubbles.
    # bootstrap.sh renders both as FQDNs into node.env (using the real TAILNET_DOMAIN); node.env is
    # appended after this file in environmentFiles, so those values win. Keeping the FQDN out of
    # this store-baked file preserves the generic image (the @@TAILNET_DOMAIN@@ genericity guard).
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
    # The cert is FQDN-only, so resolve the node's tailnet domain at runtime (no @@TAILNET_DOMAIN@@
    # baked into the generic image) and probe the FQDN — bare `bluebubbles` fails the TLS handshake.
    domain="$(${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r .MagicDNSSuffix)"
    url="https://bluebubbles.$domain/api/v1/server/info"
    until ${pkgs.curl}/bin/curl -sS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
      echo "waiting for BlueBubbles at $url ..."
      sleep 5
    done
    echo "BlueBubbles is reachable."
  '';

  # --- Honcho global config (~/.honcho/config.json) — REMOTE cloud -------------
  # Honcho is the memory provider (memory.provider = "honcho" in settings below).
  # The plugin's config chain is $HERMES_HOME/honcho.json → ~/.honcho/config.json →
  # env. HOME for the hermes user is stateDir, so this seeds ${stateDir}/.honcho/config.json.
  #
  # REMOTE, not self-hosted: `environment = "production"` selects the Honcho cloud and
  # `base_url` is deliberately UNSET (base_url is the self-hosted override — setting it
  # would point the SDK away from the cloud). The HONCHO_API_KEY env (dummy `__honcho__`)
  # satisfies the api_key requirement to initialize the client; agent-vault's MITM proxy
  # injects the REAL key on api.honcho.dev (not in NO_PROXY), so the hermes VM never holds it.
  #
  # Seeded as a WRITABLE copy once (tmpfiles `C`, below) rather than a read-only `L+`
  # symlink: the agent/CLI shallow-merge into this file, and an immutable store symlink
  # would make those writes fail AND be re-created on every rebuild, wiping the state.
  # Cadence values are the architecture's starting point (hybrid / depth 1 / context 2 /
  # dialectic 3 / low).
  # TODO(human): the cadence mapping has an unresolved value conflict between the §10
  #   ledger (positional) and the catalog's per-setting recs — confirm the intended
  #   (key → value) mapping, and confirm the full honcho config.json schema (the
  #   verified keys are enabled/recallMode/writeFrequency/sessionStrategy).
  honchoConfig = pkgs.writeText "honcho-config.json" (builtins.toJSON {
    enabled = true;
    environment = "production";
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
    # Bake the `honcho` optional-dependency extra (honcho-ai==2.0.1) into the wheel.
    # Upstream dropped honcho from `[all]` (lazy pip-install at first use) — which fails
    # in this Nix-managed Python with no runtime pip. Baking it here is what makes the
    # remote Honcho memory provider actually load. uv2nix resolves the upstream-pinned ver.
    extraDependencyGroups = [ "honcho" ];
  };

  models = import ./models.nix;

  cfg = config.services.hermes-agent;

  # --- End-of-bootstrap onboarding --------------------------------------------
  # bootstrap.sh auto-launches this over `tailscale ssh -t admin@hermes -- sudo -u hermes -H
  # hermes-onboard` once the VM is reachable. It collects the identity that yclaw's declarative
  # provisioning can't: the user profile (USER.md) and the agent persona (SOUL.md) — written
  # ONLY when absent, so the agent's own later edits are never clobbered — then confirms the
  # Honcho (remote) memory wiring and seeds the Honcho peer identity from SOUL.md. The Honcho
  # provider + remote config are declared in Nix (memory.provider + honchoConfig), so they
  # cannot be flipped to self-hosted here. Runs as the hermes user so files land with the
  # ownership/perms the service expects. Idempotent: re-running only fills what is missing.
  hermesOnboard = pkgs.writeShellApplication {
    name = "hermes-onboard";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export HOME=${cfg.stateDir}
      export HERMES_HOME=${cfg.stateDir}/.hermes
      hermes=${patchedHermesAgent}/bin/hermes
      workspace=${cfg.workingDirectory}
      memdir="$HERMES_HOME/memories"
      usermd="$memdir/USER.md"
      soulmd="$workspace/SOUL.md"

      mkdir -p "$memdir" "$workspace"

      echo "hermes onboarding — seeds your identity, confirms Honcho (remote), seeds the peer identity."
      echo

      echo "── Identity (USER.md) ────────────────────────────────────"
      if [ ! -s "$usermd" ]; then
        printf 'Your name: '
        read -r name
        printf 'A sentence or two about you (the agent remembers this): '
        read -r about
        {
          printf '# User profile\n\n'
          printf -- '- **Name:** %s\n\n' "$name"
          printf '%s\n' "$about"
        } > "$usermd"
        echo "Wrote $usermd"
      else
        echo "USER.md already present ($usermd) — leaving it untouched."
      fi

      echo
      echo "── Agent persona (SOUL.md) ───────────────────────────────"
      if [ ! -s "$soulmd" ]; then
        printf 'Agent persona in one line (blank for a sensible default): '
        read -r persona
        [ -n "$persona" ] || persona="You are a helpful, concise personal assistant."
        printf '%s\n' "$persona" > "$soulmd"
        echo "Wrote $soulmd"
      else
        echo "SOUL.md already present ($soulmd) — leaving it untouched."
      fi

      echo
      echo "── Memory: Honcho (remote cloud) ─────────────────────────"
      echo "Configured declaratively (provider=honcho, environment=production, no base_url);"
      echo "the agent-vault proxy injects the real API key on api.honcho.dev."
      "$hermes" memory status || true

      echo
      echo "── Seeding the Honcho peer identity from SOUL.md ─────────"
      "$hermes" honcho identity "$soulmd" \
        || echo "(peer-identity seeding skipped — non-fatal; rerun once metal/vault is up)"

      echo
      echo "Onboarding complete. Start a new session to activate."
    '';
  };
in
{
  # Evaluate-only manifest sanity: every secret hermes owns must exist in the catalog (the single
  # source of truth scripts/lib/secrets.sh also reads), so an ownership/catalog drift fails
  # `nix flake check` instead of producing an undecryptable bundle at runtime.
  assertions = map (key: {
    assertion = manifest.catalog ? ${key};
    message = "hermes: secret '${key}' is in hosts.hermes.secrets but missing from manifest.catalog";
  }) manifest.hosts.hermes.secrets;

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

    # Put the `hermes` CLI on the system PATH and export HERMES_HOME = ${cfg.stateDir}/.hermes
    # so `tailscale ssh admin@hermes -- hermes …` (e.g. `just smoke`'s `hermes doctor`) and the
    # end-of-bootstrap onboarding act on the SERVICE state, not a private ~/.hermes. Also flips
    # config.yaml to group-writable 0660. The onboarding runs the CLI as the hermes user (sudo),
    # so files land with the ownership the service expects (the honcho plugin writes mode 0600).
    addToSystemPackages = true;

    # Appended into ~/.hermes/.env in order: non-secret first, sops secret, then the rendered
    # proxy env LAST. The module's activation script cat-appends these into a single ~/.hermes/.env
    # at activation time (NOT a systemd EnvironmentFile), and python-dotenv keeps the LAST
    # occurrence of a duplicate key — so agent-vault-proxy.env's HTTPS_PROXY/HTTP_PROXY win. Each
    # entry must be a file that already exists at activation time: node.env and agent-vault-proxy.env
    # are both seeded/rendered under /var/lib/node-config by the seedNodeConfig→renderProxyEnv
    # activation chain (which runs before the hermes-agent setup script — see renderHermesProxyEnv
    # below). environmentFiles is `listOf str`, so coerce the writeText derivation to its
    # store-path string (the other paths are already strings).
    environmentFiles = [
      "${hermesEnvFile}"
      "/var/lib/node-config/node.env"
      config.sops.secrets."hermes/env".path
      "/var/lib/node-config/agent-vault-proxy.env"
    ];

    # Full declarative config.yaml. Nix attrset,
    # deep-merged + rendered to ~/.hermes/config.yaml. No secrets here.
    settings = {
      # ── Model plane (direct to metal — Aperture bypassed to cut ~0.5s TTFB/call) ──
      # The hosted `ai` (Aperture) node sits ~150ms WAN away; routing every model call
      # through it added a measured ~0.5s TTFB per call (paid again on each tool round).
      # We now hit metal's upstreams directly: gpt-5.5 + gemini → cliproxy :8317,
      # Qwen → omlx :8000. Bare `metal` resolves via MagicDNS and is in NO_PROXY, so these
      # stay DIRECT (no agent-vault MITM hop). cliproxy's :8317 is pf-gated to hermes + the host,
      # so hermes reaches it with no bearer ("the tailnet is the auth"); omlx :8000 needs no key either.
      model = {
        provider = "custom";
        default = "gpt-5.5";
        base_url = "http://metal:8317/v1";
      };
      fallback_providers = [
        {
          provider = "custom";
          model = "gemini-3-pro-preview";
          base_url = "http://metal:8317/v1";
        }
        {
          provider = "custom";
          model = models.qwen;
          base_url = "http://metal:8000/v1";
        }
      ];

      # ── Agent behaviour / loop budget ──
      agent = {
        max_turns = 90;
        api_max_retries = 1;
        # "low" (was "medium"): replies are sent only after the FULL reasoning+generation
        # completes (no streaming on the iMessage path), so reasoning effort is the single
        # biggest perceived-latency lever. "low" keeps most answer quality for a chat bot.
        reasoning_effort = "low";
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
        # configured model (http://metal:8317) or STT (metal:8765) provider endpoints, so the
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

      # ── Memory: built-in curated notes (MEMORY.md/USER.md) + Honcho provider ──
      # Built-in memory (memory_enabled/user_profile_enabled → MEMORY.md/USER.md) stays
      # always-on. Honcho is the external memory PROVIDER (v0.16.0: plugins/memory/honcho)
      # and runs ALONGSIDE the built-in notes (additive, not a replacement). `provider =
      # "honcho"` is exactly what `hermes memory setup honcho` writes; declaring it here points
      # the node at Honcho deterministically (deep-merge keeps Nix authoritative on rebuild).
      # Honcho's REMOTE/enabled wiring lives in ~/.honcho/config.json (seeded above, no
      # base_url → cloud) + the HONCHO_API_KEY env (dummy; vault injects the real key).
      memory = {
        provider = "honcho";
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
      # compression → main (= http://metal:8317); vision + web_extract → openai key (via vault).
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
        # hermes-telegram is the standard full messaging bundle (terminal, file, web,
        # vision, image_gen, tts, browser, skills, todo, cronjob, send_message). Deliberately
        # the full bundle: the agent is autonomous by design (delegation.subagent_auto_approve),
        # contained by gVisor + the docker socket proxy — not by toolset narrowing.
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

  # One secret lands in the hermes VM, carried by the encrypted sops "hermes/env" file
  # (appended last into ~/.hermes/.env, so it never hits the world-readable Nix store):
  #   * BLUEBUBBLES_PASSWORD — BlueBubbles is in NO_PROXY, so agent-vault cannot inject it on the
  #     wire; hermes must hold it. Scope the BlueBubbles account to least privilege + rotate on
  #     any hermes compromise.
  # (hermes's former cliproxy bearer HERMES_CLIPROXY_KEY was dropped: metal's :8317 is pf-gated to
  # hermes + the host, so the model plane needs no per-caller key — "the tailnet is the auth".)
  #
  # Derived from the manifest's hosts.hermes.secrets (single source of truth), minus
  # tailscale/authkey — that universal secret is already declared by nixos/common.nix, so we
  # subtract it here rather than relying on attrset merge. Hermes's per-host bundle is encrypted
  # to ONLY hermes's age recipient and contains ONLY these keys (no cross-host secrets).
  sops.secrets = lib.genAttrs (lib.subtractLists [ "tailscale/authkey" ] manifest.hosts.hermes.secrets) (_: { });

  # --- agent-vault MITM CA → OS trust store ------------------------------------
  # Rust/rustls clients (the `gws` Google CLI) IGNORE SSL_CERT_FILE and read only
  # the system store, so the .env CA vars are necessary but NOT sufficient.
  # The deploy flow fetches GET http://metal:14321/v1/mitm/ca.pem into
  # ./nixos/agent-vault-ca.pem (the committed file is the @@AGENT_VAULT_CA_PEM@@ placeholder; a
  # CA public cert is not a secret). Baked into the system trust store so rustls clients — which
  # ignore SSL_CERT_FILE and read only the system store — also trust the metal MITM proxy.
  security.pki.certificateFiles = [ ./agent-vault-ca.pem ];

  # --- agent-vault proxy env (token → HTTPS_PROXY URL) -------------------------
  # The hermes-agent module assembles ~/.hermes/.env by cat-appending each environmentFiles entry
  # at ACTIVATION time (NOT a systemd EnvironmentFile), skipping any path that doesn't yet exist.
  # So the proxy env must be a PERSISTENT file present before that activation step — a systemd
  # oneshot writing /run/... would be invisible to the activation cat (the /run file doesn't exist
  # at activation on a cold boot). We therefore render it in an activation script:
  #   read the per-host proxy TOKEN seedNodeConfig copied to /var/lib/node-config/agent-vault-token
  #   → write http://<token>:hermes@metal:14322 as HTTPS_PROXY/HTTP_PROXY into agent-vault-proxy.env.
  # Mode 600 (the URL embeds the injection-authorizing token — treat it like a secret). Fail-fast:
  # an empty/missing token aborts activation rather than booting hermes with a dead proxy (it would
  # 407 every brokered request). Ordered after seedNodeConfig (which seeds the token) and before the
  # hermes-agent setup script that consumes environmentFiles — setupSecrets already deps on
  # seedNodeConfig, and the hermes-agent module's setup runs stringAfter setupSecrets, so inserting
  # renderHermesProxyEnv into that chain keeps the ordering.
  system.activationScripts.renderHermesProxyEnv = {
    deps = [ "seedNodeConfig" ];
    text = ''
      tok=$(cat /var/lib/node-config/agent-vault-token 2>/dev/null || true)
      [ -n "$tok" ] || { echo "renderHermesProxyEnv: FATAL empty/missing /var/lib/node-config/agent-vault-token — the agent-vault proxy URL cannot be built; every brokered request would 407" >&2; exit 1; }
      install -d -m 700 /var/lib/node-config
      install -m 600 /dev/null /var/lib/node-config/agent-vault-proxy.env
      # Vault hint after the first colon ("hermes"); host metal:14322 is the MITM proxy port.
      printf 'HTTPS_PROXY=http://%s:hermes@metal:14322\nHTTP_PROXY=http://%s:hermes@metal:14322\n' \
        "$tok" "$tok" > /var/lib/node-config/agent-vault-proxy.env
    '';
  };
  # Chain renderHermesProxyEnv between seedNodeConfig and the hermes-agent setup script (which runs
  # stringAfter setupSecrets and cat-appends environmentFiles). setupSecrets already deps on
  # seedNodeConfig; adding renderHermesProxyEnv guarantees the proxy.env exists before it is read.
  system.activationScripts.setupSecrets.deps = [ "renderHermesProxyEnv" ];

  # --- In-VM Docker sandbox (terminal.backend = "docker") — gVisor-confined ----
  # H6 (Phase 5): the agent runs UNTRUSTED input (inbound iMessages, fetched web content) with
  # no human approval gate, so every code-exec container it spawns is a potential escape vector.
  virtualisation.docker = {
    enable = true;
    # gVisor (runsc) as the daemon's DEFAULT runtime: a pure-userspace kernel that intercepts
    # the container's syscalls, so a sandbox escape lands in runsc's emulated kernel, not the
    # VM's. The agent's code-exec tool shells out to the `docker` CLI and passes NO `--runtime`
    # flag (verified in hermes-agent source), so default-runtime = "runsc" sandboxes EVERY agent
    # container transparently — nothing in the agent config selects a runtime. Kata is not viable
    # here (needs nested virt the tart guest lacks); runsc is pure userspace and works on the
    # aarch64-linux guest. pkgs.gvisor provides $out/bin/runsc (confirmed available on aarch64).
    daemon.settings = {
      runtimes.runsc.path = "${pkgs.gvisor}/bin/runsc";
      default-runtime = "runsc";
    };
  };
  # The hermes-agent service runs with a restricted systemd PATH that lacks the docker CLI,
  # so the code-execution tool's `docker` lookup fails ("Docker executable not found in PATH").
  # Put the docker client on the service PATH (verified: without this, execute_code errors).
  systemd.services.hermes-agent.path = [ config.virtualisation.docker.package ];
  # H6: hermes is NO LONGER in the docker group. gVisor (runsc) sandboxes container
  # syscalls, but a bind mount is honoured by runsc's gofer, so a docker-group agent
  # could `docker run -v /:/host` (or --privileged / --runtime=runc) to read the host's
  # sops key + agent-vault token regardless. The fix is to take the raw socket away: a
  # dedicated `hermes-docker-proxy` user owns /run/docker.sock (via the docker group) and
  # exposes a DEFAULT-DENY filtered socket; the agent reaches ONLY that (DOCKER_HOST above).
  # The proxy allowlists exactly the code-exec calls and screens every container-create
  # body — binds must resolve under the agent's stateDir, and privileged / devices /
  # host-namespaces / runtime overrides are refused. tecnativa-style verb-only proxies
  # can't do this (they pass the create body through); see pkgs/hermes-docker-proxy.
  # Rootless docker stays the longer-term construction-level fix (blocked today by the
  # upstream module's isSystemUser hermes with no login session / static uid).
  #
  # NOTE: not yet live-validated — a `docker run -v /:/host` from a real code-exec session
  # must be REFUSED while normal code-exec still works (see docs/SECURITY-HANDOFF.md). If a
  # legitimate mount source lives outside stateDir, widen HERMES_DOCKER_PROXY_BIND_ROOTS.
  users.users.hermes-docker-proxy = {
    isSystemUser = true;
    # Primary group `hermes` so the proxy's listening socket is connectable by the agent;
    # supplementary `docker` to reach the real daemon socket.
    group = "hermes";
    extraGroups = [ "docker" ];
    description = "hermes-docker-proxy — filtered Docker socket for the agent (H6)";
  };

  systemd.services.hermes-docker-proxy = {
    description = "Filtered Docker socket for the hermes agent (H6)";
    after = [ "docker.service" "docker.socket" ];
    requires = [ "docker.socket" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.hermes-docker-proxy}/bin/hermes-docker-proxy";
      User = "hermes-docker-proxy";
      Group = "hermes";
      SupplementaryGroups = [ "docker" ];
      # systemd creates /run/hermes-docker-proxy (owned hermes-docker-proxy:hermes, 0750
      # so the agent's group can traverse); the proxy creates the 0660 socket inside it.
      RuntimeDirectory = "hermes-docker-proxy";
      RuntimeDirectoryMode = "0750";
      Environment = [
        "HERMES_DOCKER_PROXY_LISTEN=/run/hermes-docker-proxy/docker.sock"
        "HERMES_DOCKER_PROXY_UPSTREAM=/run/docker.sock"
        "HERMES_DOCKER_PROXY_BIND_ROOTS=${cfg.stateDir}"
      ];
      Restart = "always";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  # The agent's code-exec breaks if it starts before the filtered socket exists.
  systemd.services.hermes-agent.after = [ "hermes-docker-proxy.service" ];
  systemd.services.hermes-agent.wants = [ "hermes-docker-proxy.service" ];

  # End-of-bootstrap onboarding CLI on the system PATH (merges with the hermes CLI that
  # addToSystemPackages installs). bootstrap.sh launches `sudo -u hermes -H hermes-onboard`.
  environment.systemPackages = [ hermesOnboard ];

  # --- Honcho config provisioning (seed-once WRITABLE copy) --------------------
  # `C` copies the flake-rendered default ONLY when the target is absent, so the node's
  # honcho config (which `hermes memory setup` / the plugin shallow-merge into, and which
  # the end-of-bootstrap onboarding touches) persists across rebuilds. NOT `L+`: a
  # read-only store symlink would block those writes and get re-created on every rebuild,
  # silently reverting the user's honcho setup. Mode 0600 owned by the hermes service user
  # matches what the plugin writes (atomic_json_write mode=0o600).
  systemd.tmpfiles.rules = [
    "d ${cfg.stateDir}/.honcho 0750 ${cfg.user} ${cfg.group} - -"
    "C ${cfg.stateDir}/.honcho/config.json 0600 ${cfg.user} ${cfg.group} - ${honchoConfig}"
  ];

  # --- BlueBubbles readiness gate ----------------------------------------------
  # List-wrapped so a future second ExecStartPre appends cleanly (a bare scalar
  # would merge awkwardly with a later list def).
  systemd.services.hermes-agent.serviceConfig.ExecStartPre = [ waitForBlueBubbles ];

  # --- Graceful-drain headroom on stop -----------------------------------------
  # The agent drains in-flight work on shutdown (drain_timeout ~180s). The module's
  # default TimeoutStopSec (90s) SIGKILLs it mid-drain → dropped/replayed messages and
  # BlueBubbles reconnect storms (effectively infinite latency while it flaps). Give stop
  # enough headroom to finish the drain.
  systemd.services.hermes-agent.serviceConfig.TimeoutStopSec = "210s";
}
