{
  description = "Hermes Home Server — reproducible always-on hermes-agent on Apple Silicon (NixOS VMs + nix-darwin host)";

  inputs = {
    # Consumer channel for the VMs + host. hermes-agent keeps its OWN nixpkgs (it builds
    # its package via uv2nix against nixos-unstable) — do NOT make it follow ours.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Used ONLY for the Go toolchain of the two Go services: agent-vault needs Go 1.25
    # and CLIProxyAPI needs Go 1.26, but 25.05 ships no go_1_26. The OS stays on 25.05.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-darwin = {
      # Release branch matched to nixpkgs-25.05 (master tracks unstable and trips the
      # nixpkgs-version assertion against our stable channel).
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The hermes gateway, its NixOS module, and the declarative config.yaml renderer.
    # Tracks the default branch — the EXACT rev is pinned in flake.lock, so the build stays
    # reproducible and bumps are deliberate: the weekly `.github/workflows/bump-upstream.yml`
    # job runs `nix flake update hermes-agent` and opens a PR. The `--replace-fail` patch
    # anchors in nixos/hermes.nix make a bump FAIL LOUD at build time if upstream moved the
    # patched lines — the intended signal for a human to re-roll the patch before merging.
    # Brings its own nixpkgs closure for the package (see docs/build-notes/hermes-nixos-module.md).
    hermes-agent.url = "github:NousResearch/hermes-agent";

    # Build-from-source inputs for the two Go services (no upstream Nix packaging).
    agent-vault-src = {
      url = "github:Infisical/agent-vault/30ff25ce8f3c8cfd855e4e2d3e7713bb0b007eed";
      flake = false;
    };
    cliproxyapi-src = {
      url = "github:router-for-me/CLIProxyAPI/bbef8da454c88ad09d6e589f7ddce5ed2eeddb51";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nix-darwin,
      nixos-generators,
      sops-nix,
      hermes-agent,
      ...
    }:
    let
      linuxSystem = "aarch64-linux";
      darwinSystem = "aarch64-darwin";

      # Same-system unstable pkgs, used ONLY for the Go toolchain (25.05 lacks go_1_26).
      mkUnstable =
        system:
        import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };

      # Adds the two locally-built Go services to pkgs. Parameterized by the matching
      # unstable pkgs so buildGoModule uses a new-enough Go (1.26 for CLIProxyAPI).
      mkOverlay = unstable: final: _prev: {
        agent-vault = final.callPackage ./pkgs/agent-vault.nix {
          src = inputs.agent-vault-src;
          buildGoModule = unstable.buildGoModule;
        };
        cli-proxy-api = final.callPackage ./pkgs/cli-proxy-api.nix {
          src = inputs.cliproxyapi-src;
          buildGoModule = unstable.buildGoModule;
        };
      };
      overlayLinux = mkOverlay (mkUnstable linuxSystem);
      overlayDarwin = mkOverlay (mkUnstable darwinSystem);

      mkPkgs =
        system: overlay:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
          config.allowUnfree = true;
        };
      pkgsLinux = mkPkgs linuxSystem overlayLinux;
      pkgsDarwin = mkPkgs darwinSystem overlayDarwin;

      # Make the right-platform overlay available inside each NixOS/darwin config.
      overlayModuleLinux = {
        nixpkgs.overlays = [ overlayLinux ];
        nixpkgs.config.allowUnfree = true;
      };
      overlayModuleDarwin = {
        nixpkgs.overlays = [ overlayDarwin ];
        nixpkgs.config.allowUnfree = true;
      };

      # One module list per VM, reused for BOTH the toplevel nixosConfiguration (for
      # `nixos-rebuild`) AND the raw-efi image (for `tart`), so the two never drift.
      hermesModules = [
        overlayModuleLinux
        hermes-agent.nixosModules.default
        sops-nix.nixosModules.sops
        ./nixos/common.nix
        ./nixos/hermes.nix
      ];

      mkImage =
        modules:
        nixos-generators.nixosGenerate {
          system = linuxSystem;
          format = "raw-efi";
          specialArgs = { inherit inputs; };
          inherit modules;
        };
    in
    {
      overlays.default = overlayLinux;

      # --- Linux VMs (NixOS) -----------------------------------------------------
      nixosConfigurations = {
        hermes = nixpkgs.lib.nixosSystem {
          system = linuxSystem;
          specialArgs = { inherit inputs; };
          modules = hermesModules;
        };
      };

      # --- Apple-Silicon host (nix-darwin) ---------------------------------------
      # Apply with `darwin-rebuild switch --flake .#host`. hostName is set inside
      # darwin/host.nix (@@HOST_NAME@@), so the attr name stays static.
      darwinConfigurations.host = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        specialArgs = { inherit inputs; };
        modules = [
          overlayModuleDarwin
          ./darwin/host.nix
        ];
      };

      # The metal macOS guest VM. Applies IN-GUEST with `darwin-rebuild switch --flake .#metal`.
      # The SIP-on, max-locked credential/AI vault node — runs ONLY omlx, mlx-audio STT,
      # CLIProxyAPI, and agent-vault; sops-nix provides the credential decryption. It runs NO
      # iMessage: that lives on the separate bluebubbles VM, its own SIP-off tailnet node.
      # See darwin/metal.nix.
      darwinConfigurations.metal = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        specialArgs = { inherit inputs; };
        modules = [
          overlayModuleDarwin
          sops-nix.darwinModules.sops
          ./darwin/metal.nix
        ];
      };

      # --- Buildable artifacts ---------------------------------------------------
      packages.${linuxSystem} = {
        agent-vault = pkgsLinux.agent-vault;
        # Aperture is a hosted Tailscale service, not a VM: ai.nix renders the providers
        # JSON we paste into the Aperture dashboard. See nixos/ai.nix.
        aperture-config = pkgsLinux.callPackage ./nixos/ai.nix { };
        hermes-image = mkImage hermesModules;
      };

      packages.${darwinSystem} = {
        cli-proxy-api = pkgsDarwin.cli-proxy-api;
        aperture-config = pkgsDarwin.callPackage ./nixos/ai.nix { };
      };

      formatter.${linuxSystem} = pkgsLinux.nixfmt-rfc-style;
      formatter.${darwinSystem} = pkgsDarwin.nixfmt-rfc-style;
    };
}
