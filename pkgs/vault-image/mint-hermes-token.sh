#!/bin/bash
# Port of metal's `metal-mint-hermes-token` (darwin/metal.nix): bootstrap runs this over
# `tailscale ssh root@vault -- /mint-hermes-token.sh`; `--token-only` prints ONLY the token.
set -euo pipefail

# exec/ssh sessions do not carry the image config.Env; the master session lives under
# AGENT_VAULT_HOME (registered by the entrypoint's provision loop).
export PATH=/bin
export AGENT_VAULT_HOME=/var/lib/vault/agent-vault
exec agent-vault agent rotate hermes --token-only
