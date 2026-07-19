"""Behavioural tests for the teardown scripts: run them against stubbed boundaries
(launchctl / tart / container / sudo / curl) and assert what they actually tear down,
so the manifest-derived node sets are exercised rather than a literal loop header matched.
curl is always stubbed, so nuke-tailnet can never reach the real Tailscale API."""

import subprocess
from dataclasses import dataclass
from pathlib import Path

SCRIPTS = Path(__file__).parent.parent / "scripts"

# GET /devices returns this; every yclaw node plus a bystander that must never be touched.
DEVICES_JSON = """{"devices":[
  {"id":"DEV-metal","hostname":"metal","name":"metal.example.ts.net","tags":["tag:metal"]},
  {"id":"DEV-hermes","hostname":"hermes","name":"hermes.example.ts.net","tags":["tag:hermes"]},
  {"id":"DEV-vault","hostname":"vault","name":"vault.example.ts.net","tags":["tag:vault"]},
  {"id":"DEV-bb","hostname":"bluebubbles","name":"bluebubbles.example.ts.net","tags":["tag:bluebubbles"]},
  {"id":"DEV-laptop","hostname":"laptop","name":"laptop.example.ts.net","tags":[]}
]}"""

CURL_STUB = """#!/bin/bash
# GET /devices -> the fixture; -X DELETE -> log the target URL. Never hits the network.
url=""; delete=0
for a in "$@"; do
  case "$a" in DELETE) delete=1 ;; https://*) url="$a" ;; esac
done
if [ "$delete" = 1 ]; then printf '%s\\n' "$url" >> "$CAP/deletes"; else printf '%s' "$DEVICES_JSON"; fi
"""


@dataclass(frozen=True, slots=True)
class Sandbox:
    cap: Path
    env: dict[str, str]

    def cap_lines(self, name: str) -> list[str]:
        f = self.cap / name
        return f.read_text().splitlines() if f.exists() else []


def make_sandbox(tmp_path: Path) -> Sandbox:
    bindir, cap, home = (tmp_path / d for d in ("bin", "cap", "home"))
    for d in (bindir, cap, home):
        d.mkdir()
    (home / "Library" / "LaunchAgents").mkdir(parents=True)

    stubs = {
        # bootout logs its target; print always "absent" so bootout_drain returns instantly.
        "launchctl": (
            '#!/bin/bash\ncase "$1" in bootout) printf "%s\\n" "$2" >> "$CAP/bootout" ;; print) exit 1 ;; esac\n'
        ),
        "tart": '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CAP/tart"\n',
        "container": '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CAP/container"\n',
        "sudo": '#!/bin/bash\nexec "$@"\n',
        "curl": CURL_STUB,
    }
    for name, body in stubs.items():
        stub = bindir / name
        stub.write_text(body)
        stub.chmod(0o755)

    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "HOME": str(home),
        "CAP": str(cap),
        "CONTAINER_BIN": str(bindir / "container"),
        "DEVICES_JSON": DEVICES_JSON,
        # A dummy key so nuke-tailnet reaches its (stubbed) API path instead of the unset short-circuit.
        "TAILSCALE_API_KEY": "dummy-not-real",
    }
    return Sandbox(cap=cap, env=env)


def run(script: str, sandbox: Sandbox, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(SCRIPTS / script), *args],
        env=sandbox.env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_destroy_treats_vault_as_container_not_tart_vm(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    proc = run("destroy.sh", sandbox)
    assert proc.returncode == 0, proc.stderr

    container = "\n".join(sandbox.cap_lines("container"))
    tart = "\n".join(sandbox.cap_lines("tart"))
    bootout = sandbox.cap_lines("bootout")

    # vault + hermes are containers: each is force-removed via the container CLI, and NEVER via tart.
    assert "rm -f vault" in container
    assert "rm -f hermes" in container
    assert "vault" not in tart
    assert "hermes" not in tart

    # tart VMs are metal + bluebubbles (tart_vm != null): they get tart stop/delete, not container rm.
    assert "delete metal" in tart and "delete bluebubbles" in tart
    assert "rm -f metal" not in container and "rm -f bluebubbles" not in container

    # The vault container supervisor is drained (its LaunchAgent booted out) before removal.
    assert any("com.yclaw.container-vault" in line for line in bootout)
    assert any("com.yclaw.container-hermes" in line for line in bootout)
    assert any("com.yclaw.tart-metal" in line for line in bootout)


def test_destroy_derives_node_sets_from_manifest(tmp_path: Path) -> None:
    script = (SCRIPTS / "destroy.sh").read_text()
    # Sets come from machines.json via the manifest lib, not a hardcoded literal loop.
    assert "select(.value.tart_vm != null)" in script
    assert 'select(.value.managed_by == "container")' in script
    assert "for node in hermes vault" not in script
    assert "for vm in metal hermes bluebubbles" not in script


def test_nuke_tailnet_deletes_vault_by_name_and_tag(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    proc = run("nuke-tailnet.sh", sandbox, "vault")
    assert proc.returncode == 0, proc.stderr

    deletes = "\n".join(sandbox.cap_lines("deletes"))
    # vault resolves to its device (matched by hostname AND tag:vault) and only that one is deleted.
    assert "DEV-vault" in deletes
    for other in ("DEV-metal", "DEV-hermes", "DEV-bb", "DEV-laptop"):
        assert other not in deletes


def test_nuke_tailnet_all_includes_vault(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    proc = run("nuke-tailnet.sh", sandbox, "all")
    assert proc.returncode == 0, proc.stderr

    deletes = "\n".join(sandbox.cap_lines("deletes"))
    for node in ("DEV-metal", "DEV-hermes", "DEV-vault", "DEV-bb"):
        assert node in deletes
    assert "DEV-laptop" not in deletes  # a non-fleet device is never touched


def test_nuke_tailnet_filter_set_is_manifest_derived(tmp_path: Path) -> None:
    sandbox = make_sandbox(tmp_path)
    # vault is an accepted filter (derived from the manifest's tagged machines)...
    assert run("nuke-tailnet.sh", sandbox, "vault").returncode == 0
    # ...and an unknown node is rejected by the derived-set validation.
    assert run("nuke-tailnet.sh", sandbox, "bogus").returncode == 1
