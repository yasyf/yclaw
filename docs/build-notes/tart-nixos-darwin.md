# Build Notes: tart + NixOS + nix-darwin

> Authoritative extraction for the Hermes home server. A later agent must be able to author
> Nix / `just` / shell from this file **without re-reading sources**. Every option name, path,
> port, env var, and shell block below is concrete. Genuinely-unverifiable items are flagged
> `TODO(human):` or `BLOCKER:` rather than invented.
>
> **Host facts (verified on this machine, 2026-06-15):** `tart` is at `/opt/homebrew/bin/tart`,
> version **2.32.1**. `nix` is **NOT installed** on the host. tart subcommands available:
> `create clone run set get list login logout ip exec pull push import export prune rename
> stop delete suspend`. (`tart --help` on this host.)

---

## 0. The two hard facts that shape everything

1. **tart has no "boot a prebuilt Linux disk" flag.** `tart create` only accepts
   `--from-ipsw <path>` (macOS) or `--linux` (empty Linux scaffold). There is **no
   `--from-disk` / `--from-raw`**. Verified: `tart create --help` →
   `USAGE: tart create <name> [--from-ipsw <path>] [--linux] [--disk-size <disk-size>] [--disk-format <disk-format>]`.
   So a NixOS image reaches tart by **overwriting the VM's `disk.img`** after
   `tart create --linux`, OR by ISO-installing.

2. **tart Linux VMs boot via Apple's `VZEFIBootLoader`** (Apple Virtualization framework's
   generic UEFI), with an EFI variable store stored in the VM's `nvram.bin`. There is **no
   custom kernel/initrd config in tart** — the firmware reads the GPT disk's EFI System
   Partition. A `nixos-generators` **`raw-efi`** image is exactly a GPT disk with an ESP, so it
   is the format to target. (Apple VZ EFI loader: tart `--serial` is documented as "Useful for
   debugging Linux Kernel"; `tart create --linux` then ISO-install is the documented Linux path,
   per <https://tart.run/quick-start/>.)

   **`BLOCKER:` (must verify on-device before trusting the build):** It is **not yet verified**
   that tart's freshly-created EFI nvram will auto-boot a `raw-efi` ESP that has no explicit
   `BootOrder`/`Boot0000` NVRAM entry. The reliable fallback is the UEFI **removable-media path**
   `\EFI\BOOT\BOOTAA64.EFI`. systemd-boot installs this fallback only when
   `boot.loader.efi.canTouchEfiVariables = false` and the generic/removable install is used; GRUB
   with `efiInstallAsRemovable = true` installs `BOOTAA64.EFI` unconditionally. **Pick the
   bootloader config in §1.3 that guarantees `BOOTAA64.EFI` exists**, then confirm tart boots it.
   If direct disk-replace fails to boot, fall back to **ISO-install** (§1.5).

---

## 1. Building a tart-bootable NixOS image (hermes, vault, ai — all `aarch64-linux`)

### 1.1 nixos-generators as a flake input

`nixos-generators` is the image builder. (Note: as of NixOS 25.05 it is upstreamed into nixpkgs
as `nixos-rebuild build-image` / `config.system.build.images.<format>`, but the standalone
`nixosGenerate` helper still works and is the simplest flake plumbing. README:
<https://github.com/nix-community/nixos-generators>.)

```nix
# flake.nix (inputs)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";   # see §2
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

### 1.2 The `packages.<system>.<name>` image output

The format that produces a UEFI-bootable raw GPT disk is **`raw-efi`** ("raw image with efi
support", confirmed in the nixos-generators formats table; the `qcow-efi` sibling is "qcow2 image
with efi support"). For aarch64 you **must** target `system = "aarch64-linux"`.

```nix
# flake.nix (outputs) — produces .#packages.aarch64-linux.hermes-image, etc.
packages.aarch64-linux = {
  hermes-image = inputs.nixos-generators.nixosGenerate {
    system = "aarch64-linux";
    format = "raw-efi";
    modules = [ ./nixos/hermes.nix ./nixos/common-vm.nix ];
  };
  vault-image = inputs.nixos-generators.nixosGenerate {
    system = "aarch64-linux";
    format = "raw-efi";
    modules = [ ./nixos/vault.nix ./nixos/common-vm.nix ];
  };
  ai-image = inputs.nixos-generators.nixosGenerate {
    system = "aarch64-linux";
    format = "raw-efi";
    modules = [ ./nixos/ai.nix ./nixos/common-vm.nix ];
  };
};
```

Build (on a Linux/aarch64 builder or a remote builder — the host has **no nix**, so this runs on
a linux-builder or a CI/remote box, see `BLOCKER` below):

```bash
nix build .#packages.aarch64-linux.hermes-image
# legacy CLI: nix run github:nix-community/nixos-generators -- -f raw-efi --system aarch64-linux --flake .#hermes
```

Output is a store path; the raw disk image is at `result/nixos.img` (nixos-generators `raw`/`raw-efi`
emits `nixos.img` under the result dir). **Modern equivalent (no nixos-generators):**
`config.system.build.images.raw-efi` on the nixosConfiguration, built via
`nixos-rebuild build-image --image-variant raw-efi --flake .#hermes`.

`BLOCKER:` The host (Apple Silicon macOS) has **no nix and cannot build `aarch64-linux`
natively from Darwin without a Linux builder.** Decide the build host: (a) a nix-darwin
`nix.linux-builder` VM (qemu, aarch64-linux), (b) the `hermes`/`vault` tart VM itself running
`nixos-rebuild switch` after first boot, or (c) a remote aarch64-linux builder. `TODO(human):`
confirm which builder the `just` `build` recipe uses — the architecture doc allows either
"`nixos-generators` image" or "`nixos-rebuild switch` against the running VM."

### 1.3 Bootloader config the image MUST set (so tart can boot it)

In `nixos/common-vm.nix`, force the removable-media fallback so Apple VZ EFI finds
`\EFI\BOOT\BOOTAA64.EFI` regardless of NVRAM boot entries:

```nix
{ ... }: {
  # Guarantee \EFI\BOOT\BOOTAA64.EFI exists on the ESP (tart's nvram has no Boot#### entry).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;   # forces generic/removable install
  # If systemd-boot's fallback proves insufficient under tart, switch to GRUB:
  #   boot.loader.systemd-boot.enable = false;
  #   boot.loader.grub.enable = true;
  #   boot.loader.grub.efiSupport = true;
  #   boot.loader.grub.efiInstallAsRemovable = true;   # writes BOOTAA64.EFI unconditionally
  #   boot.loader.grub.device = "nodev";

  boot.kernelParams = [ "console=hvc0" ];   # Apple VZ serial console; matches `tart run --serial`
}
```

`TODO(human):` verify whether `console=hvc0` (Apple VZ virtio console) or `console=ttyS0`/`tty0`
is what tart 2.32.1 exposes; the a-h Apple-Virtualization gist appended `console=hvc0` to kernel
params for an Apple VZ NixOS boot (<https://gist.github.com/a-h/4e7cd15a4bd33b6c007dc41cb84892b8>),
so `hvc0` is the best first guess.

### 1.4 The disk-replace boot path (primary plan)

tart Linux VM on-disk layout, under `~/.tart/vms/<name>/`:
- `config.json` — VM config (Codable `VMConfig`; for Linux: `os: "linux"`, `arch: "arm64"`).
- `disk.img` — the VM's root disk.
- `nvram.bin` — EFI variable store. **Note: unlike macOS, a Linux tart VM's boot does NOT depend
  on a cryptographically-bound `hardwareModel`+`ecid` triple — that triple is macOS-only.** A
  Linux VM has no `hardwareModel`/`ecid`; do not copy macOS boot blobs into a Linux VM.

```bash
# Build the EFI/nvram scaffolding, then overwrite its disk with the NixOS image.
tart create --linux hermes --disk-size 64        # disk-size in GB; mints config.json + nvram.bin + empty disk.img
IMG="$(nix build --no-link --print-out-paths .#packages.aarch64-linux.hermes-image)/nixos.img"
# raw-efi is already a raw GPT image; copy with APFS clonefile, then resize the VM disk if larger.
cp -c "$IMG" ~/.tart/vms/hermes/disk.img        # cp -c = APFS clonefile (instant, COW)
tart set hermes --disk-size 64                   # grow the disk record if the image is smaller
tart run hermes --no-graphics --net-bridged=en0 --serial   # --serial to watch the kernel boot
```

`TODO(human):` confirm the raw-efi image filename inside the build result (`nixos.img` vs
`nixos.qcow2` vs a `disk.raw`). nixos-generators `raw`/`raw-efi` historically emit `nixos.img`;
verify by `ls -l result/`. If it emits a qcow2 by mistake, convert:
`qemu-img convert -f qcow2 -O raw nixos.qcow2 disk.img`.

`TODO(human):` confirm tart accepts a disk.img whose size differs from the `tart create`
`--disk-size`. If tart validates the size, match `--disk-size` to the image's virtual size, or
`truncate -s 64G ~/.tart/vms/hermes/disk.img` after copy and let NixOS grow the FS on first boot
(`fileSystems."/".autoResize = true;` + `boot.growPartition = true;` in `common-vm.nix`).

### 1.5 Fallback: ISO-install (only if disk-replace won't boot)

If the prebuilt-disk path fails the `BLOCKER` boot check, fall back to the documented tart Linux
flow (<https://tart.run/quick-start/>): boot a NixOS minimal aarch64 installer ISO, then
`nixos-rebuild switch --flake .#hermes` inside the VM.

```bash
tart create --linux hermes --disk-size 64
tart run hermes --disk nixos-minimal-aarch64.iso:ro   # attach installer ISO read-only
# inside the VM: partition, mount, nixos-install --flake .#hermes ; reboot ; remove --disk
```

This is **not** the preferred path (it has an interactive install step that breaks pure
reproducibility); prefer §1.4 and only fall back here if EFI boot of the raw image fails.

---

## 2. nix-darwin host (tart, Tailscale OSS, MLX servers, CLIProxyAPI, pf anchor)

nix-darwin manual: <https://nix-darwin.github.io/nix-darwin/manual/>. Flake input is
`nix-darwin/nix-darwin` (see §1.1). The host config is a `darwinConfigurations.<host>`:

```nix
# flake.nix (outputs)
darwinConfigurations."hermes-host" = inputs.nix-darwin.lib.darwinSystem {
  system = "aarch64-darwin";
  modules = [ ./darwin/host.nix ];
};
```

Apply with `darwin-rebuild switch --flake .#hermes-host`.

### 2.1 Homebrew casks/formulae (tart + Tailscale OSS)

nix-darwin's built-in `homebrew` module (Homebrew Bundle wrapper) declares casks/brews
declaratively. `homebrew.enable` manages "installing/updating/upgrading Homebrew taps, formulae,
casks…". Use **`brews`** for the OSS Tailscale CLI (`tailscale` formula gives `tailscale` +
`tailscaled`, which supports `tailscale ssh` — the App Store build does not) and **`casks`** for
`tart`.

```nix
# darwin/host.nix
{
  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";       # "none"|"check"|"uninstall"|"zap"; keep untracked pkgs
      autoUpdate = false;     # idempotent darwin-rebuild switch
    };
    taps  = [ "cirruslabs/cli" ];
    casks = [ "tart" ];                 # /opt/homebrew/bin/tart
    brews = [ "tailscale" ];            # OSS build: tailscale + tailscaled (supports `tailscale ssh`)
  };
}
```

`TODO(human):` confirm whether `tart` is a Homebrew **cask** (`cirruslabs/cli/tart` is published
as a cask in the `cirruslabs/cli` tap) — the host already has it at `/opt/homebrew/bin/tart`.
Adjust `taps`/`casks` to match the actual formula/cask coordinates.

The OSS Tailscale daemon still needs the one-time imperative install (it is not a launchd unit
nix-darwin manages). Codify the `openclaw.md` symlink + install in an activation script (§2.3):
`tailscaled` lands in `/opt/homebrew/bin/` but `tailscaled install-system-daemon` expects
`/usr/local/bin/tailscaled`.

### 2.2 launchd daemons/agents (MLX servers + CLIProxyAPI)

nix-darwin exposes `launchd.daemons.<name>` (system, root) and `launchd.user.agents.<name>`
(per-user). Each has `.serviceConfig` mapping to launchd plist keys: `ProgramArguments`,
`RunAtLoad`, `KeepAlive`, `StandardOutPath`, `StandardErrorPath`. The three host services from the
architecture doc (§3): `mlx_lm.server :8080`, `parakeet-server :8765`, `CLIProxyAPI :8317`.

```nix
# darwin/host.nix
{
  launchd.user.agents.mlx-qwen = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/bin/mlx_lm.server"          # full path — launchd does NOT expand ~ or use PATH
        "--model" "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit"
        "--host" "0.0.0.0" "--port" "8080"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/Users/yasyf/Library/Logs/mlx/qwen.log";
      StandardErrorPath = "/Users/yasyf/Library/Logs/mlx/qwen.error.log";
    };
  };

  launchd.user.agents.parakeet-stt = {
    serviceConfig = {
      ProgramArguments = [ "/opt/homebrew/bin/parakeet-server" "--port" "8765" ];
      RunAtLoad = true; KeepAlive = true;
      StandardOutPath = "/Users/yasyf/Library/Logs/parakeet/stt.log";
      StandardErrorPath = "/Users/yasyf/Library/Logs/parakeet/stt.error.log";
    };
  };

  launchd.user.agents.cliproxyapi = {
    serviceConfig = {
      ProgramArguments = [ "/opt/homebrew/bin/cli-proxy-api" "--port" "8317" ];  # OAuth->static-key proxy
      RunAtLoad = true; KeepAlive = true;
      StandardOutPath = "/Users/yasyf/Library/Logs/cliproxyapi/proxy.log";
      StandardErrorPath = "/Users/yasyf/Library/Logs/cliproxyapi/proxy.error.log";
    };
  };
}
```

`TODO(human):` confirm exact binary names/paths for `parakeet-server` and `cli-proxy-api` (the
architecture doc invokes `parakeet-server`, `mlx_lm.server`, and `cli-proxy-api --codex-login` /
`--gemini-login`; CLIProxyAPI's actual port/flags must match its CLI). MLX/parakeet/CLIProxyAPI
are likely **not** Nix-packaged — they may need Homebrew/`pip`/`uv` installs declared alongside.

`TODO(human):` decide daemon vs agent. The `openclaw.md` tart plists were **LaunchAgents**
(`~/Library/LaunchAgents`, `gui/$(id -u)` domain). MLX needs the GPU + the logged-in GUI session,
so **user agents** are correct; `launchd.daemons` (system domain) would lack GUI/Metal access.

The **tart VM launchd units** stay imperative-style but can be nix-darwin `launchd.user.agents`
too. Verbatim shape from `openclaw.md` (full paths, no `~`):

```nix
launchd.user.agents."tart-hermes" = {
  serviceConfig = {
    ProgramArguments = [
      "/opt/homebrew/bin/tart" "run" "hermes"
      "--no-graphics" "--net-bridged=en0" "--suspendable"
    ];
    RunAtLoad = true; KeepAlive = true;
    StandardOutPath = "/Users/yasyf/Library/Logs/Tart/hermes.log";
    StandardErrorPath = "/Users/yasyf/Library/Logs/Tart/hermes.error.log";
  };
};
```

### 2.3 Activation script to install the pf anchor (and Tailscale daemon)

nix-darwin runs imperative steps via `system.activationScripts.postActivation.text` (runs as root
during `darwin-rebuild switch`, after the main activation). Drop the **idempotent** pf-anchor
install (the `openclaw.md` `grep -q` guard) here:

```nix
# darwin/host.nix
{
  system.activationScripts.postActivation.text = ''
    # pf VNC anchor — idempotent (only appends to pf.conf once)
    PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
    mkdir -p /etc/pf.anchors
    cat > "$PF_ANCHOR_FILE" <<'EOF'
    table <vnc_allowed> { 100.64.0.0/10, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 }
    pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
    block in quick proto { tcp udp } from any to any port 5900:5902
    EOF
    if ! grep -q 'anchor "vnc"' /etc/pf.conf; then
      cat >> /etc/pf.conf <<CONF

    anchor "vnc"
    load anchor "vnc" from "/etc/pf.anchors/vnc"
    CONF
    fi
    pfctl -f /etc/pf.conf
  '';
}
```

`TODO(human):` `system.activationScripts` exact attribute path — the moved nix-darwin manual page
did not quote it verbatim. nix-darwin historically exposes `system.activationScripts.postActivation.text`
(and `.preActivation`, `.extraActivation`); confirm against the current manual before relying on it.

---

## 3. Tailscale on NixOS (each Linux VM joins as its own tailnet node)

NixOS service: **`services.tailscale`**. Each Linux VM (hermes, vault, ai) runs its own
`tailscaled`, so MagicDNS resolves per-node names (`hermes`, `vault`, `ai`). Because the VMs use
**bridged networking** (`tart --net-bridged`), each gets its own LAN IP and is a first-class
tailnet node — required so hermes can resolve `ai` (Aperture) and `vault` (the proxy).

```nix
# nixos/common-vm.nix
{ ... }: {
  services.tailscale = {
    enable = true;
    authKeyFile = "/run/secrets/tailscale-authkey";   # injected by sops-nix/agenix; NOT in the Nix store
    useRoutingFeatures = "client";                      # honor --accept-routes
    extraUpFlags = [ "--ssh" "--accept-dns" "--accept-routes" ];  # `tailscale up` flags; matches openclaw.md
  };
  # MagicDNS resolution
  networking.nameservers = [ "100.100.100.100" ];   # only if not relying on --accept-dns + resolved
}
```

Key option names (NixOS `services.tailscale`):
- `services.tailscale.enable` (bool) — installs `tailscale`/`tailscaled` + the systemd unit.
- `services.tailscale.authKeyFile` (path) — file with the auth key for **unattended** `tailscale up`
  at first boot. The `bootstrap` `just` recipe prompts for the key and writes it via sops-nix; the
  key is never committed (architecture §9).
- `services.tailscale.extraUpFlags` (list) — appended to `tailscale up`. Set
  `[ "--ssh" "--accept-dns" "--accept-routes" ]` to mirror the `openclaw.md`
  `tailscale set --ssh --accept-dns --accept-routes` posture.
- `services.tailscale.useRoutingFeatures` = `"client"` — needed for `--accept-routes` to take effect.

`TODO(human):` verify on nixos-25.05 whether the flag option is `extraUpFlags` (current) vs the
older `extraUpArgs`; the prompt named `extraUpArgs` but recent NixOS uses `extraUpFlags`. Confirm
against `man configuration.nix` / the module source on the pinned channel.

Per-node MagicDNS names this unlocks (architecture doc): `hermes.<tailnet>.ts.net`,
`vault.<tailnet>.ts.net`, `bluebubbles.<tailnet>.ts.net`, and the bare `ai` node. hermes addresses
`http://ai/v1` (Aperture) and `http://vault.<tailnet>.ts.net:14322` (agent-vault proxy) by these
names — both require the VM to be its own tailnet node, hence per-VM `tailscaled`.

---

## 4. openclaw.md prior art — codify VERBATIM (do NOT "fix")

These are working shell blocks from `/Users/yasyf/Documents/Blog/drafts/openclaw.md`. Reproduce
them as-is in `scripts/`. Do not "improve" the idempotency guards or the race-fix.

### 4.1 The `cp -c` boot-blob triple (macOS VM migration only — bluebubbles VM)

> **Applies only to the macOS `bluebubbles` VM.** Linux tart VMs have no `hardwareModel`/`ecid`
> (§1.4). The triple is `hardwareModel` + `ecid` + `nvram.bin`, cryptographically bound — copy with
> APFS clonefile (`cp -c`), never regenerate. lume→tart config translation (verbatim shape from
> openclaw.md lines 70-99):

```json
// lume: ~/.lume/<name>/config.json          // tart: ~/.tart/vms/<name>/config.json
// "os": "macOS"            -> "os": "darwin"
// "display": "1024x768"    -> "display": { "width": 1024, "height": 768 }
// "machineIdentifier"      -> "ecid"
// hardwareModel: copied verbatim (base64)
```

The migration `cp -c`s the bound triple verbatim:

```bash
# hardwareModel + ecid live in config.json (base64, copied verbatim during the translation);
# nvram.bin is clonefile-copied:
cp -c ~/.lume/<name>/nvram.bin ~/.tart/vms/<name>/nvram.bin
# NEVER regenerate hardwareModel / ecid / nvram.bin — the guest won't boot if any one changes.
```

### 4.2 pf VNC anchor with idempotent guard (verbatim, openclaw.md L172-206)

```bash
#!/bin/bash
set -euo pipefail

# Enable Screen Sharing
sudo launchctl enable system/com.apple.screensharing
sudo launchctl bootstrap system \
  /System/Library/LaunchDaemons/com.apple.screensharing.plist

# pf anchor: allow VNC only from Tailscale + private networks
PF_ANCHOR_FILE="/etc/pf.anchors/vnc"
sudo mkdir -p /etc/pf.anchors

sudo tee "$PF_ANCHOR_FILE" > /dev/null <<'EOF'
table <vnc_allowed> { \
  100.64.0.0/10, \
  192.168.0.0/16, \
  10.0.0.0/8, \
  172.16.0.0/12 \
}
pass in quick proto { tcp udp } from <vnc_allowed> to any port 5900:5902
block in quick proto { tcp udp } from any to any port 5900:5902
EOF

# Wire the anchor into pf.conf if not already present
if ! grep -q 'anchor "vnc"' /etc/pf.conf; then
  sudo bash -c 'cat >> /etc/pf.conf <<CONF

anchor "vnc"
load anchor "vnc" from "/etc/pf.anchors/vnc"
CONF'
fi

sudo pfctl -f /etc/pf.conf
```

The idempotent guard is `grep -q 'anchor "vnc"' /etc/pf.conf` — only appends the `anchor`/`load
anchor` lines once. Ports `5900:5902` from CGNAT `100.64.0.0/10` + RFC1918, block everything else.

### 4.3 Gateway race-fix poll-before-start wrapper (verbatim shape, openclaw.md L268-279)

Both VMs boot together; an early gateway start before BlueBubbles is ready silently leaves the
channel uninitialized. The wrapper **polls BlueBubbles `/api/v1/server/info` before starting**.
Adapted to hermes (`exec hermes gateway run`, the architecture's command):

```bash
#!/bin/bash
# /usr/local/bin/hermes-gateway-start.sh
until curl -sf --max-time 5 \
  "https://bluebubbles.<tailnet>.ts.net/api/v1/server/info" \
  >/dev/null 2>&1; do
  sleep 5
done
exec hermes gateway run
```

The systemd unit on the hermes VM (NixOS) points its `ExecStart` at this wrapper, not at
`hermes gateway run` directly. (openclaw.md used a launchd plist `ProgramArguments` → wrapper; on
NixOS it is `systemd.services.hermes-gateway.serviceConfig.ExecStart` with `Restart=always`.)

### 4.4 launchd full-path rules (verbatim gotchas, openclaw.md L134-138)

- **`launchctl load` is deprecated.** Use `launchctl bootstrap gui/$(id -u) <plist>` to load,
  `launchctl bootout gui/$(id -u)/<label>` to unload.
- **launchd does NOT expand `~`.** A plist with `--dir=~/.openclaw` silently fails — use the full
  path (`/Users/yasyf/.openclaw`). All `ProgramArguments` entries are absolute (`/opt/homebrew/bin/tart`,
  not `tart`).
- **`tart ip` does not work with bridged networking** — with `--net-bridged` the VM gets a LAN IP
  from the router, not tart's NAT; find it via `arp -a` matching the MAC, or (preferred) put
  Tailscale on the VM and use the MagicDNS name.

Verbatim tart launchd plist (openclaw.md L104-131), full paths, `--dir` absolute:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.tart.hermes</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/tart</string>
    <string>run</string>
    <string>hermes</string>
    <string>--no-graphics</string>
    <string>--net-bridged=en0</string>
    <string>--suspendable</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/yasyf/Library/Logs/Tart/hermes.log</string>
  <key>StandardErrorPath</key><string>/Users/yasyf/Library/Logs/Tart/hermes.error.log</string>
</dict>
</plist>
```

`TODO(human):` the bridged interface name — `openclaw.md` used `en12`; this host may differ. Run
`tart run … --net-bridged=list` to enumerate available bridged interfaces, then pin the right one
(e.g. `en0`).

---

## 5. Destroy / rebuild with tart (the `just destroy` & `just bootstrap` acceptance test)

tart subcommands for the teardown/rebuild loop (verified `tart --help`, v2.32.1):

| Action | Command | Notes |
|---|---|---|
| Stop a running VM | `tart stop <name>` | graceful; `KeepAlive` plist must be booted out first or it restarts |
| Delete a VM | `tart delete <name>` | removes `~/.tart/vms/<name>/` entirely |
| Recreate Linux scaffold | `tart create --linux <name> --disk-size 64` | then disk-replace per §1.4 |
| Clone (fast COW restore) | `tart clone <src> <new>` | APFS clonefile; instant, near-zero space |
| List | `tart list` | enumerate local VMs |
| Suspend | `tart suspend <name>` | needs the VM run with `--suspendable` |
| Prune | `tart prune` | reclaim OCI/IPSW caches or local VMs |

**`just destroy` (teardown):**
```bash
# boot out the launchd agents first so KeepAlive doesn't relaunch, then stop + delete
launchctl bootout gui/$(id -u)/com.local.tart.hermes  || true
launchctl bootout gui/$(id -u)/com.local.tart.vault   || true
tart stop hermes 2>/dev/null || true ; tart delete hermes 2>/dev/null || true
tart stop vault  2>/dev/null || true ; tart delete vault  2>/dev/null || true
```

**`just bootstrap` (rebuild from zero):**
```bash
darwin-rebuild switch --flake .#hermes-host          # host: tart, tailscale, MLX/CLIProxyAPI agents, pf anchor
nix build .#packages.aarch64-linux.hermes-image      # build the NixOS raw-efi image (on the chosen builder)
tart create --linux hermes --disk-size 64
cp -c "$(nix build --no-link --print-out-paths .#packages.aarch64-linux.hermes-image)/nixos.img" \
      ~/.tart/vms/hermes/disk.img
# (repeat for vault, ai); load launchd agents:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.tart.hermes.plist
```

**`tart clone` as the snapshot/restore primitive:** push a known-good built image to an OCI
registry (`tart push`) and `tart clone ghcr.io/...:tag <name>` to restore, OR keep a local
golden VM and `tart clone golden-hermes hermes` for instant COW rebuilds. The architecture's
"destroy-and-rebuild from zero" gate (§13) runs the full `just destroy` → `just bootstrap` → smoke
loop; tart `clone`/`delete`/`create` are the VM-level verbs that loop drives.

`TODO(human):` confirm whether the acceptance test rebuilds from the **flake image** every time
(slow, fully pure — preferred) or from a **pushed OCI golden image** via `tart clone` (fast, less
pure). The architecture doc's "destroy-and-rebuild is the acceptance test" implies from-flake; the
OCI path is the fast iteration loop, not the gate.

---

## Quick reference: ports, paths, env

| Thing | Value |
|---|---|
| tart binary | `/opt/homebrew/bin/tart` (v2.32.1) |
| tart VM dir | `~/.tart/vms/<name>/{config.json,disk.img,nvram.bin}` |
| MLX Qwen server | host `:8080` (`mlx_lm.server --host 0.0.0.0 --port 8080`) |
| Parakeet STT | host `:8765` (OpenAI `/v1/audio`-compatible) |
| CLIProxyAPI | host `:8317` (OAuth→static-key) |
| agent-vault proxy | `http://vault.<tailnet>.ts.net:14322` (`HTTPS_PROXY`/`HTTP_PROXY`) |
| Aperture gateway | `http://ai/v1` (in `NO_PROXY`, stays DIRECT) |
| BlueBubbles REST | `:1234` on the bluebubbles VM; `tailscale serve --bg --https=443 1234` |
| nixos-generators format | `raw-efi` (UEFI-bootable raw GPT disk) |
| system | `aarch64-linux` (VMs), `aarch64-darwin` (host) |
