#!/usr/bin/env bash
# scripts/deploy-vm.sh — retired redirect stub. hermes runs as an Apple `container`, not a tart VM;
# this points operators at the container image-rebuild and reload flows (see the die below).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$repo_root/scripts/lib/common.sh"

node="${1:-}"
case "$node" in
  hermes) ;;
  *)
    echo "usage: deploy-vm.sh <hermes>" >&2
    exit 1
    ;;
esac

die "deploy-vm.sh is retired: hermes runs as an Apple \`container\`, not a tart VM. For an image rebuild run scripts/build-hermes-image.sh then \`container image load\`; to reload the running container run ./scripts/redeploy.sh hermes."
