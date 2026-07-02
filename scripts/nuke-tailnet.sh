#!/usr/bin/env bash
# Delete yclaw device registrations from the tailnet via the Tailscale API. With an argument
# (metal|hermes|bluebubbles) it deletes ONLY that node; with no argument (or `all`) it deletes every
# yclaw node — metal, hermes, bluebubbles, and the retired `vault`. Needs TAILSCALE_API_KEY (from .env);
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

filter="${1:-all}"
case "$filter" in
  all|metal|hermes|bluebubbles) ;;
  *) echo "usage: nuke-tailnet.sh [all|metal|hermes|bluebubbles]" >&2; exit 1 ;;
esac

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a || true
if [ -z "${TAILSCALE_API_KEY:-}" ]; then
  echo "nuke-tailnet: TAILSCALE_API_KEY unset (check .env) — skipping; delete yclaw devices by hand in the admin console" >&2
  exit 0
fi

if [ "$filter" = all ]; then
  names='["hermes","metal","bluebubbles","vault"]'
  tags='["tag:hermes","tag:metal","tag:bluebubbles"]'
else
  names="[\"$filter\"]"
  tags="[\"tag:$filter\"]"
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
