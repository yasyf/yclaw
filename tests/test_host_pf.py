"""Integration tests for scripts/host/host-pf.sh: render the template the way setup.sh does,
then run a full tick against stubbed tailscale/ifconfig/pfctl binaries and a sandboxed
PF_ANCHOR_DIR/PF_CONF (the /etc paths are pf.sh's mock boundary)."""

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent / "scripts"

STOCK_SR = (
    'scrub-anchor "com.apple/*" all fragment reassemble\n'
    'anchor "com.apple/*" all\n'
    'dummynet-anchor "com.apple/*" all\n'
    'anchor "vnc" all'
)
SCRUB_ONLY_SR = 'scrub-anchor "com.apple/*" all fragment reassemble'
CONDITIONAL_SR = (
    'scrub-anchor "com.apple/*" all fragment reassemble\n'
    'anchor "com.apple/*" inet all'
)

TAILSCALE_STUB = """#!/bin/bash
case "$1" in
  status) printf '{"BackendState": "Running"}\\n' ;;
  ip)
    case "$3" in
      metal)       if [ "$2" = -4 ]; then echo 100.100.0.1; else echo fd7a:115c:a1e0::1; fi ;;
      hermes)      if [ "$2" = -4 ]; then echo 100.100.0.2; else echo fd7a:115c:a1e0::2; fi ;;
      bluebubbles) if [ "$2" = -4 ]; then echo 100.100.0.3; else echo fd7a:115c:a1e0::3; fi ;;
    esac ;;
esac
"""

IFCONFIG_STUB = """#!/bin/bash
printf 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\\n'
printf '\\tinet 127.0.0.1 netmask 0xff000000\\n'
printf 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\\n'
printf '\\tinet 192.0.2.24 netmask 0xffffff00 broadcast 192.0.2.255\\n'
printf 'utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\\n'
printf '\\tinet 100.100.0.99 --> 100.100.0.99 netmask 0xffffffff\\n'
printf 'bridge101: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\\n'
printf '\\tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255\\n'
"""

PFCTL_STUB = """#!/bin/bash
case "$1" in
  -a)
    flat="$(printf '%s' "$2" | tr '/' '.')"
    case "$3" in
      -f) cat "$4" > "$PFCTL_CAP/loaded.$flat"; printf '%s\\n' "$2" >> "$PFCTL_CAP/load-calls" ;;
      -sr) if [ -f "$PFCTL_CAP/loaded.$flat" ]; then cat "$PFCTL_CAP/loaded.$flat"; fi ;;
    esac ;;
  -sr) printf '%s\\n' "$PFCTL_SR" ;;
  -s) printf 'Status: %s for 0 days 00:00:01           Debug: Urgent\\n' "$PFCTL_STATUS" ;;
  -e) : > "$PFCTL_CAP/enabled" ;;
  -E) printf 'E\\n' >> "$PFCTL_CAP/E-calls" ;;
  -k) shift; printf '%s\\n' "$*" >> "$PFCTL_CAP/kills" ;;
esac
"""


@dataclass(frozen=True, slots=True)
class HostPfSandbox:
    lib: Path
    cap: Path
    pfconf: Path
    env: dict[str, str]


def make_sandbox(tmp_path: Path, sr: str = STOCK_SR, status: str = "Enabled") -> HostPfSandbox:
    lib, bindir, cap, anchors = (tmp_path / d for d in ("lib", "bin", "cap", "anchors"))
    for d in (lib, bindir, cap, anchors):
        d.mkdir()
    pfconf = tmp_path / "pf.conf"
    pfconf.write_text("")

    shutil.copy(SCRIPTS / "lib" / "wait.sh", lib / "wait.sh")
    shutil.copy(SCRIPTS / "lib" / "pf.sh", lib / "pf.sh")

    template = (SCRIPTS / "host" / "host-pf.sh").read_text()
    pinned_path = "export PATH=/usr/sbin:/sbin:/usr/bin:/bin"
    assert pinned_path in template
    rendered = (
        template.replace(pinned_path, f"export PATH={bindir}:/usr/sbin:/sbin:/usr/bin:/bin")
        .replace("@@TAILSCALE@@", str(bindir / "tailscale"))
        .replace("@@PF_PORTS@@", "{ 8000, 8765 }")
    )
    (lib / "host-pf.sh").write_text(rendered)
    (lib / "host-pf.sh").chmod(0o755)

    for name, body in (("tailscale", TAILSCALE_STUB), ("ifconfig", IFCONFIG_STUB), ("pfctl", PFCTL_STUB)):
        stub = bindir / name
        stub.write_text(body)
        stub.chmod(0o755)

    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "TMPDIR": str(tmp_path),
        "PF_ANCHOR_DIR": str(anchors),
        "PF_CONF": str(pfconf),
        "PFCTL_CAP": str(cap),
        "PFCTL_SR": sr,
        "PFCTL_STATUS": status,
    }
    return HostPfSandbox(lib=lib, cap=cap, pfconf=pfconf, env=env)


def tick(sandbox: HostPfSandbox) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(sandbox.lib / "host-pf.sh"), "1"],
        env=sandbox.env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_tick_renders_the_to_self_lockdown_under_000(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    proc = tick(sandbox)
    assert proc.returncode == 0, proc.stderr

    loaded = (sandbox.cap / "loaded.com.apple.000.yclaw.host").read_text()
    assert "block drop in quick on bridge101 from 192.168.64.0/24 to self" in loaded
    assert "block drop in quick on bridge101 inet6 from any to self" in loaded
    assert "pass out quick on bridge101 to 192.168.64.0/24 keep state" in loaded
    assert "pass in quick on bridge101 proto udp from 192.168.64.0/24 to 192.168.64.1 port { 53, 67, 68 }" in loaded
    assert "pass in quick on bridge101 proto tcp from 192.168.64.0/24 to 192.168.64.1 port 53" in loaded
    assert "pass in quick proto tcp from { 100.100.0.1, fd7a:115c:a1e0::1 } to any port { 8000, 8765 }" in loaded
    assert "block drop in quick on bridge101 from 192.168.64.0/24 to 192.168.64.1" not in loaded

    assert (sandbox.cap / "load-calls").read_text() == "com.apple/000.yclaw.host\n"
    assert 'load anchor "com.apple/000.yclaw.host" from' in sandbox.pfconf.read_text()
    assert (sandbox.lib / "host-pf.last-ok").read_text().strip().isdigit()
    assert not (sandbox.cap / "E-calls").exists()  # the tick never stacks -E refcount tokens
    assert not (sandbox.cap / "enabled").exists()  # pf already Enabled -> no pfctl -e


@pytest.mark.parametrize(
    "sr",
    [
        pytest.param(SCRUB_ONLY_SR, id="scrub-anchor-only"),
        pytest.param(CONDITIONAL_SR, id="conditional-filter-call"),
    ],
)
def test_wildcard_check_rejects_non_unconditional_rulesets(tmp_path: Path, sr: str) -> None:
    sandbox = make_sandbox(tmp_path, sr=sr)
    proc = tick(sandbox)
    assert proc.returncode == 1
    assert "wildcard" in proc.stderr
    assert not (sandbox.lib / "host-pf.last-ok").exists()
    assert not (sandbox.cap / "kills").exists()


def test_state_kill_runs_once_per_ruleset_change(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    first = tick(sandbox)
    assert first.returncode == 0, first.stderr
    kills = (sandbox.cap / "kills").read_text().splitlines()
    assert kills == [
        "100.100.0.1",
        "fd7a:115c:a1e0::1",
        "100.100.0.2",
        "fd7a:115c:a1e0::2",
        "100.100.0.3",
        "fd7a:115c:a1e0::3",
        "192.168.64.0/24 -k 127.0.0.1",
        "192.168.64.0/24 -k 192.0.2.24",
        "192.168.64.0/24 -k 100.100.0.99",
        "192.168.64.0/24 -k 192.168.64.1",
    ]

    (sandbox.cap / "kills").unlink()
    second = tick(sandbox)
    assert second.returncode == 0, second.stderr
    assert not (sandbox.cap / "kills").exists()


def test_enable_fires_only_when_pf_is_disabled(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path, status="Disabled")
    proc = tick(sandbox)
    assert proc.returncode == 0, proc.stderr
    assert (sandbox.cap / "enabled").exists()
    assert not (sandbox.cap / "E-calls").exists()
