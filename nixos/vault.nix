# The `vault` VM: Infisical agent-vault, the single credential broker.
# Runs the agent-vault Go binary as a foreground systemd service (API :14321,
# transparent MITM proxy :14322), holds the static API keys + Google OAuth tokens,
# and mints its own CA so it can TLS-MITM-inject credentials into hermes egress.
#
# Adds to nixos/common.nix (boot, tailscale, sops base, admin user, nix flakes).
# Sources: docs/build-notes/agent-vault.md §§1-5; docs/hermes-home-server.md §5-6.
{
  config,
  pkgs,
  ...
}:
let
  vaultUser = "agent-vault";
  vaultHome = "/var/lib/agent-vault";
  # The broker's logical vault NAME (agent-vault.md: the `vault:` key is "hermes").
  # Distinct from this NixOS host (hostName "vault") — hence not just `vault`.
  vaultName = "hermes";
  servicesYaml = ./vault-services.yaml;
  # External base URL: added as a leaf-cert SAN AND used as the OAuth redirect base
  # (redirect URI is fixed at <addr>/v1/oauth/callback). Must be the VM's reachable
  # tailnet URL so Google's non-localhost callback resolves.
  vaultAddr = "http://vault.@@TAILNET_DOMAIN@@:14321";
in
{
  networking.hostName = "vault";

  sops.secrets = {
    "vault/master-password" = { };
    "vault/static-keys" = { };
    "vault/google-oauth" = { };
  };

  users.users.${vaultUser} = {
    isSystemUser = true;
    group = vaultUser;
    home = vaultHome;
    createHome = true;
  };
  users.groups.${vaultUser} = { };

  systemd.services.agent-vault = {
    description = "Infisical agent-vault credential broker";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      HOME = vaultHome;
      # OAuth redirect base + leaf-cert SAN.
      AGENT_VAULT_ADDR = vaultAddr;
      # TODO(human): default-deny blocks RFC-1918/loopback/link-local upstreams. If
      # any upstream or the agent network is private, set the allowlist (comma CIDRs)
      # and/or flip ALLOW_PRIVATE_RANGES; IMDS is always blocked regardless.
      AGENT_VAULT_NETWORK_ALLOWLIST = "";
      AGENT_VAULT_ALLOW_PRIVATE_RANGES = "false";
    };
    serviceConfig = {
      User = vaultUser;
      Group = vaultUser;
      WorkingDirectory = vaultHome;
      # Foreground (no -d) so systemd supervises; master password supplied via the
      # env file (AGENT_VAULT_MASTER_PASSWORD), unset by the process after first read.
      EnvironmentFile = config.sops.secrets."vault/master-password".path;
      ExecStart = "${pkgs.agent-vault}/bin/agent-vault server --host 0.0.0.0 --port 14321 --mitm-port 14322";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Post-start provisioning: push service rules, then seed static credentials from
  # the sops file. Ordered After= the server; the server must be up + an authenticated
  # owner session to accept writes.
  #
  # TODO(human): non-interactive owner bootstrap — the first registered user becomes
  # owner; there is no documented server flag to seed owner email/password. Determine
  # how this oneshot authenticates to push credentials/services (verify cmd/register.go
  # / cmd/owner_vault.go for a non-interactive path) before this step can run unattended.
  systemd.services.agent-vault-provision = {
    description = "Register owner + push service rules + static credentials";
    after = [ "agent-vault.service" ];
    requires = [ "agent-vault.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.agent-vault
      pkgs.curl
      pkgs.gnugrep
      pkgs.coreutils
    ];
    environment = {
      HOME = vaultHome;
      AGENT_VAULT_ADDR = "http://127.0.0.1:14321";
    };
    serviceConfig = {
      Type = "oneshot";
      # Runs as root so it reads the root-owned sops secrets (master-password env + static-keys)
      # directly; it only talks to the local API and reads files — the server stays ${vaultUser}.
      EnvironmentFile = config.sops.secrets."vault/master-password".path;
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ADDR=http://127.0.0.1:14321
      owner=admin@hermes.local

      # Wait for the server to accept connections.
      for _ in $(seq 1 120); do curl -fsS "$ADDR/health" >/dev/null 2>&1 && break; sleep 1; done

      # First boot: register the owner non-interactively (the first user auto-activates and
      # auto-logs in, persisting the CLI session under $HOME/.agent-vault). Idempotent — skipped
      # once a user exists; falls back to a non-interactive login if the session is missing.
      if curl -fsS "$ADDR/v1/status" | grep -q '"needs_first_user":true'; then
        printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
          | agent-vault auth register --address "$ADDR" --email "$owner" --password-stdin
      elif [ ! -s "$HOME/.agent-vault/session.json" ]; then
        printf '%s' "$AGENT_VAULT_MASTER_PASSWORD" \
          | agent-vault auth login --address "$ADDR" --email "$owner" --password-stdin
      fi

      # Ensure the target vault exists (registration only grants a "default" vault). Idempotent.
      agent-vault vault create ${vaultName} 2>/dev/null || true

      # Replace-all the service rules, then (re)set the static API keys from sops (KEY=VALUE lines).
      agent-vault vault service set --vault ${vaultName} --file ${servicesYaml}
      agent-vault vault credential set --vault ${vaultName} \
        $(cat ${config.sops.secrets."vault/static-keys".path})

      # Google is an OAuth credential (key GOOGLE_OAUTH_TOKEN), connected out of band via the
      # headless token upload POST ${vaultAddr}/v1/credentials/oauth/tokens — see DEPLOYMENT docs.
    '';
  };

  # CA exposure: hermes fetches the MITM root CA from this VM over the API port,
  #   GET ${vaultAddr}/v1/mitm/ca.pem   (no auth; 404 until the proxy is listening)
  # and installs it into its OS trust store via security.pki.certificateFiles.
  # Cross-ref: hermes.nix step 4 (CA install + HTTPS_PROXY wiring).
}
