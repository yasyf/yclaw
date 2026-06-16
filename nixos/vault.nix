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
    description = "Seed agent-vault service rules + static credentials";
    after = [ "agent-vault.service" ];
    requires = [ "agent-vault.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.agent-vault ];
    environment.HOME = vaultHome;
    serviceConfig = {
      Type = "oneshot";
      User = vaultUser;
      Group = vaultUser;
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      # Replace-all the service rules for the `hermes` vault.
      agent-vault vault service set --vault ${vaultName} -f ${servicesYaml}

      # Static API keys (OPENAI/EXA/HONCHO/GITHUB) as KEY=VALUE lines from sops.
      agent-vault credential set --vault ${vaultName} \
        $(cat ${config.sops.secrets."vault/static-keys".path})

      # HUMAN: Google is an OAuth credential, NOT `credential set`. Connect it ONCE:
      #   POST ${vaultAddr}/v1/credentials/oauth/connect
      #     {vault: "${vaultName}", key: "GOOGLE_OAUTH_TOKEN",
      #      authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
      #      token_url: "https://oauth2.googleapis.com/token",
      #      client_id/client_secret from sops vault/google-oauth, scopes: "<gws scopes>"}
      #   then open the returned authorization_url in a browser to consent.
      # The Google client's Authorized redirect URI must EXACTLY equal
      #   ${vaultAddr}/v1/oauth/callback
      # TODO(human): decide browser-consent vs. headless token-upload
      #   (POST ${vaultAddr}/v1/credentials/oauth/tokens) for the Google credential.
    '';
  };

  # CA exposure: hermes fetches the MITM root CA from this VM over the API port,
  #   GET ${vaultAddr}/v1/mitm/ca.pem   (no auth; 404 until the proxy is listening)
  # and installs it into its OS trust store via security.pki.certificateFiles.
  # Cross-ref: hermes.nix step 4 (CA install + HTTPS_PROXY wiring).
}
