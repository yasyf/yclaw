# Hermes Home Server — orchestration entrypoints.
# Recipes stay thin: non-trivial logic lives in scripts/. Host shell is fish,
# so every shebang recipe pins bash explicitly.

# Default: list the available recipes.
default:
    @just --list

# The single entrypoint: the de-Nix'd onboarding wizard. Preflight → collect secrets + mint
# per-host age keys and per-node tailnet keys → packer-build metal+bluebubbles → build hermes
# image → setup.sh → authorize host on metal's pf gate → boot+onboard hermes → download the
# model → print the human gates. Idempotent; re-run after clearing a gate.
bootstrap:
    ./scripts/bootstrap.sh

# Post-bootstrap onboarding TUI: drives the human gates bootstrap stops at (Tailscale SSH check,
# hermes identity, Codex + Gemini cli-proxy logins, agent-vault Google OAuth, Apple-ID/BlueBubbles)
# then validate + smoke. Runs in a zellij session (tmux fallback); idempotent — already-done gates
# are skipped. Mints no secrets. Set YCLAW_ONBOARD_NO_ZELLIJ=1 to run inline without a multiplexer.
onboard:
    ./scripts/onboard.sh

# De-Nix'd host bring-up: Homebrew tart/gum, ~/.yclaw/state, and the com.yclaw.tart-* runners.
setup:
    ./scripts/setup.sh

# Build the hermes NixOS image (systemd-repart) WITHOUT host Nix, in a throwaway linux/arm64 tart
# builder VM (scripts/build-hermes-image.sh). This is the de-Nix'd builder; CI runs the same nix
# build remotely. Output: ./result-hermes/nixos.img.
build-hermes-image:
    ./scripts/build-hermes-image.sh

# Apply one node. hermes→rebuild image + tart disk-replace.
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
      *)
        echo "unknown node: {{node}} (expected hermes)" >&2
        exit 1
        ;;
    esac

# In-place, state-preserving redeploy with ZERO human input: metal darwin-rebuild switch
# (metal-redeploy), hermes nixos-rebuild switch (dry-activate-gated — aborts to the disk-replace
# fallback if a stateful virtiofs mount would stop/restart), bb config reconfigure. The disk-replace
# path (`just deploy hermes` → scripts/deploy-vm.sh) is the fallback for reboot-class changes.
redeploy node="all":
    ./scripts/redeploy.sh {{node}}

# Smoke tests: nix flake check + hermes doctor + a model-plane curl (metal:8317/v1/models with the
# Aperture static bearer). Deeper live-stack checks stay commented scaffolding in the script.
smoke:
    ./scripts/smoke.sh

# Validate the deployed security hardening. Run ON THE HOST with the VMs up, after `just bootstrap`:
# probes the per-VM isolation + audit controls over `tailscale ssh` and reports PASS/FAIL per check.
validate:
    ./scripts/validate-hardening.sh

# Disable Screen Sharing on the bluebubbles guest once iMessage bring-up is done (the post-bring-up
# hardening step). Idempotent, needs no secrets — pipes the setup script's `harden` path over SSH.
bb-harden:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/common.sh
    source scripts/lib/manifest.sh
    source scripts/lib/ssh.sh
    guest_pipe root@bluebubbles scripts/bluebubbles-setup.sh harden

# Tear down every yclaw tart VM (boot out launchd agents first so KeepAlive can't relaunch),
# then remove the runner plists and delete the VMs' tailnet device registrations. Covers metal,
# hermes, bluebubbles, and the retired `vault` VM. Leaves host state/keychain alone — use `nuke`.
destroy:
    ./scripts/destroy.sh

# From-zero acceptance test: destroy then bring the host back up.
rebuild: destroy setup

# Clean slate: destroy every VM (via the `destroy` dependency), then wipe host secret/agent state +
# the generated keychain items so the next `just bootstrap` regenerates everything fresh. PRESERVES
# the operator-supplied Tailscale OAuth client and the model caches (set WIPE_MODELS=1 to drop those).
nuke: destroy
    ./scripts/nuke.sh

# Delete yclaw device registrations from the tailnet (scripts/nuke-tailnet.sh). yclaw nodes are
# PERSISTENT now, so they no longer self-reap on disconnect — teardown/redeploy delete them
# explicitly. Pass a node (metal|hermes|bluebubbles) to delete just that one; no arg deletes all.
# Needs TAILSCALE_API_KEY (the same key in .env); no-op with a message if it's unset.
nuke-tailnet node="all":
    ./scripts/nuke-tailnet.sh {{node}}

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
      --exclude "$HOME/.yclaw/state/mlx-audio"
