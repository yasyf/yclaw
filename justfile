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

# In-place, state-preserving redeploy with ZERO human input: metal darwin-rebuild switch
# (metal-redeploy), hermes nixos-rebuild switch (dry-activate-gated — aborts to the disk-replace
# fallback if a stateful virtiofs mount would stop/restart), bb config reconfigure. The disk-replace
# path (`just deploy hermes` → scripts/deploy-vm.sh) is the fallback for reboot-class changes.
redeploy node="all":
    ./scripts/redeploy.sh {{node}}

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

# Validate the deployed security hardening. Run ON THE HOST with the VMs up, after `just bootstrap`:
# probes the per-VM isolation + audit controls over `tailscale ssh` and reports PASS/FAIL per check.
validate:
    ./scripts/validate-hardening.sh

# Disable Screen Sharing on the bluebubbles guest once iMessage bring-up is done (the post-bring-up
# hardening step). Idempotent, needs no secrets — pipes the setup script's `harden` path over SSH.
bb-harden:
    tailscale ssh root@bluebubbles -- bash -s harden < scripts/bluebubbles-setup.sh

# Tear down every yclaw tart VM (boot out launchd agents first so KeepAlive can't relaunch),
# then remove the runner plists. Covers metal, hermes, bluebubbles, and the retired `vault`
# VM whose disk lingers at ~/.tart/vms/vault. Leaves host state/keychain alone — use `nuke`.
destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    # scripts/setup.sh writes the runners as `com.yclaw.tart-<node>` (NOT the old nix-darwin
    # `org.nixos.*` labels). Boot them out so KeepAlive can't relaunch the VM mid-teardown.
    for node in metal hermes bluebubbles; do
      launchctl bootout "gui/$(id -u)/com.yclaw.tart-${node}" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/com.yclaw.tart-${node}.plist"
    done
    # `vault` was retired into metal but its disk persists; delete it too.
    for vm in metal hermes bluebubbles vault; do
      tart stop "$vm" 2>/dev/null || true
      tart delete "$vm" 2>/dev/null || true
    done

# From-zero acceptance test: destroy then bring the host back up.
rebuild: destroy setup

# Clean slate: destroy every VM, then wipe host secret/agent state + the generated keychain
# items so the next `just bootstrap` regenerates everything fresh. PRESERVES the operator-supplied
# Tailscale OAuth client (yclaw-ts-oauth-client-{id,secret}) and the large, content-addressed
# model caches (set WIPE_MODELS=1 to drop those too). After this, mint lingering tailnet device
# entries with `just nuke-tailnet`.
nuke: destroy
    #!/usr/bin/env bash
    set -euo pipefail
    state="$HOME/.yclaw/state"
    # Secret + agent state under ~/.yclaw/state (keep model weight caches by default). The hermes
    # agent writes some skill files read-only (mode 444 inside 555 dirs), so make each tree
    # writable before removing it — otherwise rm cannot unlink them and aborts under `set -e`.
    for d in age vm-secrets hosts agent-vault cli-proxy-api hermes bluebubbles aperture-backup mlx-audio; do
      [ -e "$state/$d" ] && chmod -R u+w "$state/$d" 2>/dev/null || true
      rm -rf "$state/$d"
    done
    rm -f "$state"/secrets.sops.yaml* "$state/values.env"
    if [ "${WIPE_MODELS:-0}" = "1" ]; then
      rm -rf "$state/hf" "$state/omlx" "$HOME/.cache/huggingface/hub"
      echo "nuke: dropped model caches (WIPE_MODELS=1) — redeploy will re-download ~20 GB"
    else
      echo "nuke: preserved model caches ($state/{hf,omlx}, ~/.cache/huggingface/hub); set WIPE_MODELS=1 to drop them"
    fi
    # The hermes node-config share source, so a fresh hermes can't re-seed stale secrets.
    rm -rf "$HOME/.config/yclaw/vm-secrets"
    # Gitignored repo build cruft.
    rm -rf secrets/runtime .build
    # Keychain: delete only the GENERATED items; keep the OAuth client + keychain unlock password.
    kc="$HOME/Library/Keychains/yclaw.keychain-db"
    if [ -f "$kc" ]; then
      for svc in yclaw-agent-vault-master yclaw-metal-admin-pass yclaw-bluebubbles-admin-pass yclaw-bluebubbles-server-pass; do
        security delete-generic-password -s "$svc" "$kc" >/dev/null 2>&1 || true
      done
      echo "nuke: cleared generated keychain passwords; preserved yclaw-ts-oauth-client-{id,secret}"
    fi
    echo "nuke: clean slate. Next: just nuke-tailnet (optional), then just bootstrap."

# Delete lingering yclaw device registrations from the tailnet (ephemeral metal/hermes keys
# auto-reap; the manually-joined bluebubbles node is the one that lingers). Needs TAILSCALE_API_KEY
# (the same key in .env). No-op with a message if it's unset.
nuke-tailnet:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f .env ] && set -a && . ./.env && set +a || true
    if [ -z "${TAILSCALE_API_KEY:-}" ]; then
      echo "nuke-tailnet: TAILSCALE_API_KEY unset (check .env) — skipping; delete yclaw devices by hand in the admin console" >&2
      exit 0
    fi
    api="https://api.tailscale.com/api/v2"
    devices="$(curl -sf -u "${TAILSCALE_API_KEY}:" "$api/tailnet/-/devices")"
    # Match by hostname AND by tag — old pre-migration nodes joined untagged, new ones carry tag:<host>.
    echo "$devices" | jq -r '
      .devices[]
      | ((.hostname // "") | ascii_downcase) as $h
      | ((.name // "") | ascii_downcase | split(".")[0]) as $n
      | select(
          ([$h, $n] | any(. == "hermes" or . == "metal" or . == "bluebubbles" or . == "vault"))
          or ((.tags // []) | any(. == "tag:hermes" or . == "tag:metal" or . == "tag:bluebubbles"))
        )
      | "\(.id)\t\(.hostname)\t\((.tags // []) | join(","))"
    ' | while IFS=$'\t' read -r id hostname tags; do
          echo "nuke-tailnet: deleting device $hostname (tags: ${tags:-none})"
          curl -sf -o /dev/null -X DELETE -u "${TAILSCALE_API_KEY}:" "$api/device/$id" || echo "  (delete failed for $id)" >&2
        done
    echo "nuke-tailnet: done."

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
