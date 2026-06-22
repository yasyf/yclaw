# Hermes Home Server — orchestration entrypoints.
# Recipes stay thin: non-trivial logic lives in scripts/. Host shell is fish,
# so every shebang recipe pins bash explicitly.

# Default: list the available recipes.
default:
    @just --list

# De-Nix'd host bring-up: Homebrew tart/gum, ~/.yclaw/state, and the com.yclaw.tart-* runners.
setup:
    ./scripts/setup.sh

# Build the hermes NixOS raw-efi image WITHOUT host Nix, in a linux/arm64 Docker container
# (scripts/build-hermes-image.sh). This is the de-Nix'd builder; CI runs the same nix build
# remotely. Output: ./result-hermes/nixos.img.
build-hermes-image:
    ./scripts/build-hermes-image.sh

# Apply one node. hermes→rebuild image + tart disk-replace; ai→deploy-ai.
# The de-Nix'd host writes its VM runners as `com.yclaw.tart-<node>` (scripts/setup.sh);
# deploy-vm.sh uses the same com.yclaw.tart-* labels.
deploy node:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{node}}" in
      host)
        echo "host is Nix-free — run the onboarding wizard (\`just bootstrap\`) or \`just setup\`; there is no darwin-rebuild host config" >&2
        exit 1
        ;;
      hermes)
        ./scripts/deploy-vm.sh "{{node}}"
        ;;
      ai)
        just deploy-ai
        ;;
      *)
        echo "unknown node: {{node}} (expected hermes|ai)" >&2
        exit 1
        ;;
    esac

# Build the Aperture config and print it for the human to paste into the dashboard.
# The Aperture config-API write verb is unverified — do NOT auto-PUT; a human
# pastes the printed config manually into the Aperture dashboard.
deploy-ai:
    #!/usr/bin/env bash
    set -euo pipefail
    config="$(nix build --no-link --print-out-paths .#packages.aarch64-darwin.aperture-config)"
    cat "$config"
    echo "HUMAN: paste the Aperture config above into the Aperture dashboard (config-API write verb unverified — do not auto-PUT)."

# Smoke tests. Some checks need a live stack and stay commented scaffolding.
smoke:
    #!/usr/bin/env bash
    set -euo pipefail

    # config integrity
    nix flake check

    # model plane + Aperture routing (bare `ai` stays in NO_PROXY, DIRECT)
    curl -sf http://ai/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5.5","messages":[{"role":"user","content":"ping"}]}'

    # per-VM health via tailscale ssh
    for vm in hermes; do
      tailscale ssh "admin@${vm}" -- hermes doctor
    done

    # --- live-stack checks below need a running stack; run by hand once up. ---
    # fallback: disable the gpt-5.5 upstream → confirm hermes hops gemini-3.5 → qwen-local
    # agent-vault: a tool call needing Exa/OpenAI succeeds (bearer injected via http://metal.@@TAILNET_DOMAIN@@:14322) and fails cleanly if the broker is down
    # gmail: `gws` with a dummy token round-trips through the agent-vault proxy (real token never in the hermes VM)
    # bluebubbles: send/receive in a DM AND a group, from an authorized handle (allowlist enforced) via https://bluebubbles.@@TAILNET_DOMAIN@@

# Tear down the tart VMs (boot out launchd agents first so KeepAlive can't relaunch).
destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    # scripts/setup.sh writes the runners as `com.yclaw.tart-<node>` (NOT the old nix-darwin
    # `org.nixos.*` labels). Boot them out so KeepAlive can't relaunch the VM mid-teardown.
    launchctl bootout "gui/$(id -u)/com.yclaw.tart-metal"  || true
    launchctl bootout "gui/$(id -u)/com.yclaw.tart-hermes" || true
    tart stop metal  2>/dev/null || true ; tart delete metal  2>/dev/null || true
    tart stop hermes 2>/dev/null || true ; tart delete hermes 2>/dev/null || true

# From-zero acceptance test: destroy then bring the host back up.
rebuild: destroy setup

# Back up the irreplaceable host state (~/.yclaw/state) via restic. Set YCLAW_RESTIC_REPO
# + RESTIC_PASSWORD first (a B2/S3 URL or a local/NAS path). Skips the large, regenerable caches.
backup:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${YCLAW_RESTIC_REPO:?set YCLAW_RESTIC_REPO (restic repo URL or path)}"
    : "${RESTIC_PASSWORD:?set RESTIC_PASSWORD}"
    command -v restic >/dev/null || brew install restic
    restic -r "$YCLAW_RESTIC_REPO" snapshots >/dev/null 2>&1 || restic -r "$YCLAW_RESTIC_REPO" init
    restic -r "$YCLAW_RESTIC_REPO" backup "$HOME/.yclaw/state" \
      --exclude "$HOME/.yclaw/state/omlx" \
      --exclude "$HOME/.yclaw/state/mlx-audio"
