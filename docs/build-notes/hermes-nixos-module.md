# Hermes Agent NixOS Module — Authoritative Build Spec

Extracted from the upstream `hermes-agent` flake (reference snapshot at
`/tmp/hermes-agent-ref`, git rev pinned in `flake.lock`). This is the single
source of truth for wiring the gateway into the Hermes Home Server NixOS config.
All file:line citations below refer to the reference repo.

> **Mode scope.** The module supports two modes: native systemd (`container.enable = false`,
> default) and OCI container (`container.enable = true`). For Hermes Home Server we run the
> **native systemd** path. Container facts are noted only where they change the contract.

---

## 1. Flake output + how a consumer imports it

### What the flake exports

- **NixOS module:** `flake.nixosModules.default`
  (`nix/nixosModules.nix:27` → `flake.nixosModules.default = { config, lib, pkgs, ... }: ...`).
  There is exactly **one** module attribute and it is `default`. There is no
  `nixosModules.hermes-agent`.
- **Package (default):** `packages.<system>.default` (`nix/packages.nix:17`),
  the `hermes-agent` derivation. Also `packages.<system>.{messaging,full,tui,web,desktop,fix-lockfiles}`.
- **Overlay:** `flake.overlays.default` (`nix/overlays.nix:4`) exposes
  `pkgs.hermes-agent` for external configs.
- **Supported systems** (`flake.nix:31-35`): `x86_64-linux`, `aarch64-linux`,
  `aarch64-darwin`. **`aarch64-linux` IS supported.** (No `x86_64-darwin`.)

The module's package default resolves via
`inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.default`
(`nix/nixosModules.nix:35`), so the module pulls the package from the *flake's own*
`self.packages`, **not** from the overlay. See §6 for the pinning implication.

### Consumer flake — exact import shape

```nix
{
  inputs.hermes-agent.url = "github:NousResearch/hermes-agent"; # repo homepage: nix/hermes-agent.nix:245
  # NOTE: pin to a rev; the flake follows its own nixpkgs (nixos-unstable). See §6.

  outputs = { self, nixpkgs, hermes-agent, ... }: {
    nixosConfigurations.hermes = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux"; # or x86_64-linux
      modules = [
        hermes-agent.nixosModules.default   # <-- the module
        ./hermes-host.nix
      ];
    };
  };
}
```

Then the service is configured under `services.hermes-agent.*` (§2).

---

## 2. Option namespace — `services.hermes-agent.*`

Defined at `nix/nixosModules.nix:211` (`options.services.hermes-agent = with lib; { ... }`).
`cfg = config.services.hermes-agent` (`nix/nixosModules.nix:30`). Full list, with type and default:

| Option | Type | Default | Source |
|---|---|---|---|
| `enable` | bool (`mkEnableOption`) | `false` | `:212` |
| `package` | package | `hermes-agent` (self.packages.<system>.default) | `:215-219` |
| `user` | str | `"hermes"` | `:222-226` |
| `group` | str | `"hermes"` | `:228-232` |
| `createUser` | bool | `true` | `:234-238` |
| `stateDir` | str | `"/var/lib/hermes"` | `:241-245` |
| `workingDirectory` | str | `"${cfg.stateDir}/workspace"` | `:247-252` |
| `configFile` | nullOr path | `null` | `:255-262` |
| `settings` | **deepConfigType** (attrset, deep-merged) | `{ }` | `:264-279` |
| `environmentFiles` | listOf str | `[ ]` | `:282-290` |
| `environment` | attrsOf str | `{ }` | `:292-299` |
| `authFile` | nullOr path | `null` | `:301-308` |
| `authFileForceOverwrite` | bool | `false` | `:310-314` |
| `documents` | attrsOf (either str path) | `{ }` | `:317-330` |
| `mcpServers` | attrsOf submodule (see below) | `{ }` | `:333-458` |
| `extraArgs` | listOf str | `[ ]` | `:461-465` |
| `extraPackages` | listOf package | `[ ]` | `:467-479` |
| `extraPlugins` | listOf package | `[ ]` | `:481-500` |
| `extraPythonPackages` | listOf package | `[ ]` | `:502-525` |
| `extraDependencyGroups` | listOf str | `[ ]` | `:527-540` |
| `restart` | str | `"always"` | `:542-546` |
| `restartSec` | int | `5` | `:548-552` |
| `addToSystemPackages` | bool | `false` | `:554-562` |
| `container.enable` | bool (`mkEnableOption`) | `false` | `:566` |
| `container.backend` | enum [docker podman] | `"docker"` | `:568-572` |
| `container.extraVolumes` | listOf str | `[ ]` | `:574-579` |
| `container.extraOptions` | listOf str | `[ ]` | `:581-585` |
| `container.image` | str | `"ubuntu:24.04"` | `:587-591` |
| `container.hostUsers` | listOf str | `[ ]` | `:593-601` |

### `settings` — declarative config.yaml (CRITICAL)

`settings` has the custom merge type **`deepConfigType`** (`nix/nixosModules.nix:38-43`):

```nix
deepConfigType = lib.types.mkOptionType {
  name = "hermes-config-attrs";
  check = builtins.isAttrs;
  merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (d: d.value) defs);
};
```

It accepts a **Nix attrset**, deep-merged across module definitions via
`lib.recursiveUpdate`. It is serialized to JSON (YAML is a JSON superset) at
`nix/nixosModules.nix:46-47`:

```nix
configJson = builtins.toJSON cfg.settings;
generatedConfigFile = pkgs.writeText "hermes-config.yaml" configJson;
```

Example (`:271-278`):

```nix
services.hermes-agent.settings = {
  model = "anthropic/claude-sonnet-4";
  terminal.backend = "local";
  compression = { enabled = true; threshold = 0.85; };
  toolsets = [ "all" ];
};
```

`configFile` (a path to an existing config.yaml) **takes precedence** over
`settings` when non-null (`configFile = if cfg.configFile != null then cfg.configFile else generatedConfigFile;`,
`:48`). With `configFile` set, the activation script *installs/overwrites* rather
than merges (`:755-761`).

### `mcpServers` submodule fields

Per-server submodule (`:334-435`): `command` (nullOr str), `args` (listOf str),
`env` (attrsOf str), `url` (nullOr str), `headers` (attrsOf str),
`auth` (nullOr enum ["oauth"]), `enabled` (bool, default `true`),
`timeout` (nullOr int), `connect_timeout` (nullOr int),
`tools.{include,exclude}` (listOf str), and a `sampling` submodule
(`enabled`/`model`/`max_tokens_cap`/`timeout`/`max_rpm`/`max_tool_rounds`/`allowed_models`/`log_level`).
These are folded into `settings.mcp_servers` by the `mkIf (cfg.mcpServers != {})`
block (`:608-637`), so they merge through the same config.yaml pipeline.

---

## 3. Managed mode — how `hermes config set` becomes inert

Two independent signals make the install "managed by NixOS"
(`hermes_cli/config.py:330-337`, `get_managed_system()` at `:315-327`):

1. **Env var `HERMES_MANAGED`** — set to `"true"` in the systemd service
   environment (`nix/nixosModules.nix:885`: `HERMES_MANAGED = "true";`). Values
   `("true","1","yes")` → reported as `"NixOS"` (`config.py:306,317-322`).
2. **Marker file `${stateDir}/.hermes/.managed`** — `touch`ed by the activation
   script (`nix/nixosModules.nix:764-766`, mode `0644`). This makes *interactive*
   shells (which don't inherit the service env) also detect managed mode.

When managed, mutation commands raise. `format_managed_message()`
(`config.py:510-522`) emits, for `config set`/`config edit`:

```
Cannot <action>: this Hermes installation is managed by NixOS (HERMES_MANAGED=true).
Edit services.hermes-agent.settings in your configuration.nix and run:
  sudo nixos-rebuild switch
```

The build-time `managed-guard` check (`nix/checks.nix:255-274`) asserts that
`hermes config set` and `hermes config edit` are both blocked when
`HERMES_MANAGED=true`. (`managed_error("... managed by NixOS")` is also called
for `gateway install`/`uninstall` at `gateway.py:6491,6585`.)

### How config.yaml is rendered (the configMergeScript mechanism)

- **Where it runs:** the NixOS **activation script** `hermes-agent-setup`
  (`nix/nixosModules.nix:727`), NOT a systemd `preStart`. It runs `stringAfter`
  the `users` activation (and `setupSecrets` if present).
- **The script** (`nix/configMergeScript.nix`) is a `pkgs.writeScript` Python
  program using `pyyaml`. Invocation (`nix/nixosModules.nix:758`):
  `${configMergeScript} ${generatedConfigFile} ${stateDir}/.hermes/config.yaml`.
- **Merge semantics:** deep recursive merge where **Nix keys win**, user-added
  keys (skills, streaming, etc.) are **preserved** (`configMergeScript.nix:21-30`):

  ```python
  def deep_merge(base, override):   # base = existing user config, override = nix
      result = dict(base)
      for k, v in override.items():
          if k in result and isinstance(result[k], dict) and isinstance(v, dict):
              result[k] = deep_merge(result[k], v)
          else:
              result[k] = v          # nix scalar/list replaces user value
      return result
  merged = deep_merge(existing, nix)
  yaml.dump(merged, f, default_flow_style=False, sort_keys=False)
  ```

  Note: **lists are replaced, not concatenated** (the `else` branch). MCP
  same-name servers: Nix wins (verified `nix/checks.nix` Scenario E).
- **Output path + perms:** `${stateDir}/.hermes/config.yaml`, owned `user:group`,
  mode `configYamlMode` = `0660` when `addToSystemPackages`, else `0640`
  (`nix/nixosModules.nix:56,759-760`).
- **Idempotent:** merging twice yields identical output (checks.nix Scenario G).

`HERMES_HOME` is `${stateDir}/.hermes` (service env `:884`; system-wide via
`environment.variables.HERMES_HOME` when `addToSystemPackages`, `:657`).

---

## 4. Secrets / environment → the gateway service

The service does **NOT** use a systemd `EnvironmentFile`. Instead, the activation
script writes a single `${stateDir}/.hermes/.env`, and Hermes loads it at Python
startup via `load_hermes_dotenv()` (`hermes_cli/env_loader.py:212`, called at
import in `hermes_cli/main.py:504`, `run_agent.py:114`). Comment confirming this
design: `nix/nixosModules.nix:894-896`.

Two options feed `.env` (`:832-847`):

- **`environmentFiles`** (listOf str) — paths to **secret** env files (API keys,
  tokens). Their contents are **appended** into `.env` at activation
  (`:841-846`). **This is the sops/agenix hook**: point it at a decrypted secret
  path. The module docstring's canonical example (`:23`):

  ```nix
  services.hermes-agent.environmentFiles = [ config.sops.secrets."hermes/env".path ];
  ```

  Activation runs `stringAfter` `setupSecrets` when present (`:727`), so
  sops-nix/agenix secrets are decrypted before `.env` is assembled.
- **`environment`** (attrsOf str) — **non-secret** vars, rendered as `K=V` lines
  (`envFileContent`, `:59-61`) and written first. Docstring warns: do NOT put
  secrets here.

`.env` is written `install -m 0640` owned `user:group` (`:837`). Load precedence:
`~/.hermes/.env` overrides shell-exported values (`env_loader.py:237-238`,
`override=True`).

`authFile` / `authFileForceOverwrite` seed `${stateDir}/.hermes/auth.json`
(OAuth creds) at mode `0600` (`:822-829`); without force-overwrite, existing
auth.json is preserved.

---

## 5. Systemd unit (native mode)

Unit: **`systemd.services.hermes-agent`** (`nix/nixosModules.nix:876`, native;
`:937` is the container variant — same unit name, different body). Native mode
body (`:875-928`):

- `description = "Hermes Agent Gateway"`
- `wantedBy = [ "multi-user.target" ]`
- `after = [ "network-online.target" ]`, `wants = [ "network-online.target" ]`
- **Service environment** (`:882-887`):
  `HOME = ${stateDir}`, `HERMES_HOME = ${stateDir}/.hermes`,
  `HERMES_MANAGED = "true"`, `MESSAGING_CWD = ${workingDirectory}`
- `serviceConfig`:
  - `User = cfg.user` (default `hermes`), `Group = cfg.group` (default `hermes`)
  - `WorkingDirectory = cfg.workingDirectory`
  - **`ExecStart`** (`:898-901`):
    `"${effectivePackage}/bin/hermes" "gateway"` ++ `cfg.extraArgs`.
    → i.e. `<store>/bin/hermes gateway` (no `run` subcommand). Bare `gateway`
    **defaults to `run`** in the CLI (`hermes_cli/gateway.py:6473-6481`:
    *"Default to run if no subcommand"* → `run_gateway(...)`). There is no implicit
    `--replace` in native mode (container mode uses `gateway run --replace`, `:986`).
  - **`Restart = cfg.restart`** (default `"always"`), `RestartSec = cfg.restartSec` (default `5`)
  - `UMask = "0007"` (group-writable shared state)
  - Hardening: `NoNewPrivileges = true`, `ProtectSystem = "strict"`,
    `ProtectHome = false`, `PrivateTmp = true`,
    `ReadWritePaths = [ cfg.stateDir cfg.workingDirectory ]`
  - **No `Type =` is set** in native mode (defaults to `simple`). (Container mode
    explicitly sets `Type = "simple"`, `:1001`.)
- `path = [ effectivePackage pkgs.bash pkgs.coreutils pkgs.git ] ++ cfg.extraPackages`
  (`:921-926`)

`effectivePackage` (`:31-34`): `cfg.package` unless `extraPythonPackages` or
`extraDependencyGroups` are non-empty, in which case
`cfg.package.override { inherit extraPythonPackages extraDependencyGroups; }`.

Wrapped binaries (`nix/hermes-agent.nix:189-193`): `hermes`, `hermes-agent`,
`hermes-acp`. `mainProgram = "hermes"` (`:247`).

tmpfiles dirs created at mode `2770` (setgid, group-writable):
`${stateDir}`, `.hermes`, `.hermes/{cron,sessions,logs,memories,plugins}`,
`${workingDirectory}`; `${stateDir}/home` at `0750` (`:712-722`).

---

## 6. Package pinning / nixpkgs / system support / overlay

- **Build system:** package is built with **uv2nix** (`nix/python.nix:13`,
  `nix/hermes-agent.nix:40`), Python **3.12** (`python312`, `python.nix:2`),
  Node **22** (`nodejs_22`, `hermes-agent.nix:39`). Sealed venv via
  `pythonSet.mkVirtualEnv "hermes-agent-env"` with dependency-groups `["all"]`
  plus any `extraDependencyGroups` (`python.nix:99-101`, `hermes-agent.nix:42`).
- **nixpkgs:** the flake follows `github:NixOS/nixpkgs/nixos-unstable`
  (`flake.nix:5`); locked rev `6201e203d09599479a3b3450ed24fa81537ebc4e`
  (`flake.lock`). All flake inputs (`pyproject-nix`, `uv2nix`,
  `pyproject-build-systems`, `npm-lockfile-fix`) `follows = "nixpkgs"`.
- **How the module resolves the package:** the module reads
  `inputs.self.packages.${system}.default` (`nixosModules.nix:35`) — i.e. **the
  hermes flake's own pinned nixpkgs**, not the consumer's. To change nixpkgs you
  must override the *hermes* flake input, or set `services.hermes-agent.package`
  explicitly. The overlay (`pkgs.hermes-agent`) uses the *consumer's* `pkgs`
  but is **not** what the module's default uses — they can diverge.
- **Pinning recommendation:** pin the `hermes-agent` flake input by rev in the
  consumer flake; bump deliberately. `package.override` is the supported override
  surface for `extraPythonPackages` / `extraDependencyGroups`.
- **System support:** `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`
  (`flake.nix:31-35`). **aarch64-linux works** for the package and module.
  Caveats from `nix/checks.nix`: build-time *checks* are Linux-only
  (`checks.nix:6` — onnxruntime lacks aarch64-darwin wheels). The `matrix`
  dependency group is Linux-only (`packages.nix:46`); on aarch64-darwin several
  packages (numpy/pyarrow/av/onnxruntime/faster-whisper) are swapped for nixpkgs
  prebuilts (`python.nix:53-86`).
- **Overlay requirement:** none for the module itself (the module imports its own
  package). The overlay is only needed if a consumer wants `pkgs.hermes-agent`
  directly. Container mode additionally needs `virtualisation.docker.enable`
  (set `mkDefault` by the module when backend is docker, `:935`).

---

## 7. ExecStartPre / poll-before-start hook (BlueBubbles race-fix)

**There is NO built-in "wait/poll before start" mechanism in the module.** The
native unit defines no `ExecStartPre` and no `preStart` (only the *container*
mode has a `preStart`, `:945-990`, which is container-creation logic, not a
readiness gate). Confirmed by reading the entire native `serviceConfig`
(`nix/nixosModules.nix:889-919`).

**Where to inject the BlueBubbles readiness wait** (options, in order of
cleanliness):

1. **`systemd.services.hermes-agent.serviceConfig.ExecStartPre`** — add it in the
   *consumer's* host module (NixOS merges `serviceConfig` attrs). Point it at a
   small wrapper script that polls the BlueBubbles endpoint until reachable, then
   exits 0. This is the recommended seam; the module never sets `ExecStartPre`,
   so there is no conflict.
2. **`systemd.services.hermes-agent.preStart`** — also mergeable from the consumer
   module; runs before `ExecStart`. Equivalent effect for native mode.
3. **`serviceConfig.ExecStart` override** — replace with a wrapper that waits then
   exec's `${pkg}/bin/hermes gateway`. Heavier; loses the module's default and the
   `extraArgs` plumbing. Prefer option 1.

> TODO(human): confirm the exact BlueBubbles readiness probe (URL/port/health
> path) the wrapper should poll. The module source does not reference
> BlueBubbles; that wiring is owned by the Home Server config, not this module.

---

## Quick-reference paths

- Module: `nix/nixosModules.nix` (option block `:211`, native unit `:875`,
  activation `:727`).
- Merge script: `nix/configMergeScript.nix`.
- Package: `nix/hermes-agent.nix`; venv builder `nix/python.nix`; overlay
  `nix/overlays.nix`; flake outputs `nix/packages.nix`; checks `nix/checks.nix`.
- Managed-mode Python: `hermes_cli/config.py:306-337,510-536`;
  env loader `hermes_cli/env_loader.py:212-247`;
  gateway default-subcommand `hermes_cli/gateway.py:6470-6482`.
- Runtime paths: `HERMES_HOME=${stateDir}/.hermes`, config
  `${HERMES_HOME}/config.yaml`, env `${HERMES_HOME}/.env`, auth
  `${HERMES_HOME}/auth.json`, marker `${HERMES_HOME}/.managed`.
