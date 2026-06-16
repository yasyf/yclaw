# Hermes Home Server — orchestration entrypoints.
# Recipes stay thin: non-trivial logic lives in scripts/. Host shell is fish,
# so every shebang recipe pins bash explicitly.

# Default: list the available recipes.
default:
    @just --list

# Destroy-and-rebuild acceptance entrypoint (prompts → applies flake → builds images → smoke).
bootstrap:
    ./scripts/bootstrap.sh

# Build the NixOS raw-efi disk images for the Linux VMs.
# The host has no nix and cannot build aarch64-linux from Darwin natively; this
# runs on an aarch64-linux builder (nix.linux-builder VM, remote builder, or the
# VM itself). See docs/build-notes/tart-nixos-darwin.md §1.2.
# TODO(human): pin which aarch64-linux builder the build runs on.
build-images:
    nix build .#packages.aarch64-linux.hermes-image
    nix build .#packages.aarch64-linux.vault-image

# Apply one node. host→darwin-rebuild; hermes/vault→rebuild image + tart disk-replace; ai→deploy-ai.
deploy node:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{node}}" in
      host)
        darwin-rebuild switch --flake .#host
        ;;
      hermes|vault)
        ./scripts/deploy-vm.sh "{{node}}"
        ;;
      ai)
        just deploy-ai
        ;;
      *)
        echo "unknown node: {{node}} (expected host|hermes|vault|ai)" >&2
        exit 1
        ;;
    esac

# Build the Aperture config and print it for the human to paste into the dashboard.
# The Aperture config-API write verb is unverified — do NOT auto-PUT; a human
# pastes this into the Aperture dashboard. See docs/IMPLEMENTATION-HANDOFF.md §3.
deploy-ai:
    #!/usr/bin/env bash
    set -euo pipefail
    config="$(nix build --no-link --print-out-paths .#packages.aarch64-darwin.aperture-config)"
    cat "$config"
    echo "HUMAN: paste the Aperture config above into the Aperture dashboard (config-API write verb unverified — do not auto-PUT)."

# Smoke tests — handoff §7. Some checks need a live stack and stay commented scaffolding.
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
    for vm in hermes vault; do
      tailscale ssh "admin@${vm}" -- hermes doctor
    done

    # --- live-stack checks below need a running stack; run by hand once up. ---
    # fallback: disable the gpt-5.5 upstream → confirm hermes hops gemini-3.5 → qwen-local
    # vault: a tool call needing Exa/OpenAI succeeds (bearer injected via http://vault.@@TAILNET_DOMAIN@@:14322) and fails cleanly if vault is down
    # gmail: `gws` with a dummy token round-trips through the vault proxy (real token never in the hermes VM)
    # bluebubbles: send/receive in a DM AND a group, from an authorized handle (allowlist enforced) via https://bluebubbles.@@TAILNET_DOMAIN@@

# Tear down the tart VMs (boot out launchd agents first so KeepAlive can't relaunch).
# See docs/build-notes/tart-nixos-darwin.md §5.
destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    # nix-darwin labels user agents `org.nixos.<name>` (darwin/host.nix defines
    # launchd.user.agents.tart-hermes / tart-vault). Boot them out so KeepAlive
    # can't relaunch the VM mid-teardown.
    launchctl bootout "gui/$(id -u)/org.nixos.tart-hermes" || true
    launchctl bootout "gui/$(id -u)/org.nixos.tart-vault"  || true
    tart stop hermes 2>/dev/null || true ; tart delete hermes 2>/dev/null || true
    tart stop vault  2>/dev/null || true ; tart delete vault  2>/dev/null || true

# From-zero acceptance test: destroy then bootstrap.
rebuild: destroy bootstrap
