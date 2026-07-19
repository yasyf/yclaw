#!/usr/bin/env bash
# Delete yclaw device registrations from the tailnet via the Tailscale API. With an argument
# (metal|hermes|vault|bluebubbles) it deletes ONLY that node; with no argument (or `all`) it deletes
# every yclaw node — metal, hermes, vault, and bluebubbles. Needs TAILSCALE_API_KEY (from .env);
# no-op with a message if it's unset.
#
# WHY targeted deletes exist: yclaw nodes are PERSISTENT (non-ephemeral) tailnet nodes, so they no
# longer self-reap when they disconnect (scripts/lib/secrets.sh `_ts_mint_key`). Every teardown
# (`just destroy`/`rebuild`/`nuke`) and every disk-replace (scripts/deploy-vm.sh) must therefore delete
# the old device EXPLICITLY, or stale registrations pile up and MagicDNS drifts (`hermes` → `hermes-1`).
# Matches by hostname/name OR by tag, so a pre-migration untagged node and a current tag:<host> node
# are both caught.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=scripts/lib/manifest.sh
. "$REPO/scripts/lib/manifest.sh"

# Tailnet nodes = manifest machines with a non-null tag (the control host has none).
NODES="$(manifest_get '[.machines | to_entries[] | select(.value.tag != null) | .key] | join(" ")')"

filter="${1:-all}"
case " all $NODES " in
  *" $filter "*) ;;
  *) echo "usage: nuke-tailnet.sh [all|$(printf '%s' "$NODES" | tr ' ' '|')]" >&2; exit 1 ;;
esac

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a || true
if [ -z "${TAILSCALE_API_KEY:-}" ]; then
  echo "nuke-tailnet: TAILSCALE_API_KEY unset (check .env) — skipping; delete yclaw devices by hand in the admin console" >&2
  exit 0
fi

if [ "$filter" = all ]; then
  names="$(manifest_get '[.machines | to_entries[] | select(.value.tag != null) | .key]')"
  tags="$(manifest_get '[.machines | to_entries[] | select(.value.tag != null) | .value.tag]')"
else
  names="[\"$filter\"]"
  tags="$(manifest_get "[.machines[\"$filter\"].tag]")"
fi

api="https://api.tailscale.com/api/v2"
devices="$(curl -sf -u "${TAILSCALE_API_KEY}:" "$api/tailnet/-/devices")"
echo "$devices" | jq -r --argjson names "$names" --argjson tags "$tags" '
  .devices[]
  | ((.hostname // "") | ascii_downcase) as $h
  | ((.name // "") | ascii_downcase | split(".")[0]) as $n
  | select(
      ([$h, $n] | any(. as $x | $names | index($x) != null))
      or ((.tags // []) | any(. as $t | $tags | index($t) != null))
    )
  | "\(.id)\t\(.hostname)\t\((.tags // []) | join(","))"
' | while IFS=$'\t' read -r id hostname tags_joined; do
      echo "nuke-tailnet: deleting device $hostname (tags: ${tags_joined:-none})"
      curl -sf -o /dev/null -X DELETE -u "${TAILSCALE_API_KEY}:" "$api/device/$id" || echo "  (delete failed for $id)" >&2
    done
echo "nuke-tailnet: done (filter: $filter)."
