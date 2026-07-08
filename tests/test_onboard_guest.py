import shlex

import pytest
from loguru import logger

from yclaw import remote
from yclaw.manifest import load_manifest
from yclaw.onboard import guest
from yclaw.remote import RemoteResult

pytestmark = pytest.mark.anyio


def _expected_prelude(machine_name: str) -> str:
    lines = [f"YCLAW_NODE={machine_name}\n"]
    debloat = load_manifest().debloat.get(machine_name)
    if debloat is not None:
        lines.append(f"YCLAW_DEBLOAT_SYSTEM='{' '.join(debloat.system)}'\n")
        lines.append(f"YCLAW_DEBLOAT_GUI='{' '.join(debloat.gui)}'\n")
    return "".join(lines)


async def test_guest_pipe_assembles_payload_and_command(manifest, monkeypatch, tmp_path):
    script = tmp_path / "setup.sh"
    script.write_bytes(b"#!/bin/bash\necho hello\n")
    seen: dict[str, object] = {}

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        seen.update(machine=machine, command=command, timeout=timeout, capture=capture, input=input)
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    bb = manifest.machines["bluebubbles"]
    env = {"BLUEBUBBLES_PASSWORD": "a b'c", "BB_ALLOWED_HOST_IP": "100.64.0.1"}
    await guest.guest_pipe(bb, str(script), "setup", env=env)

    exports = "".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items())
    expected = (
        guest.WAIT_SH.read_bytes()
        + guest.PF_SH.read_bytes()
        + _expected_prelude("bluebubbles").encode()
        + exports.encode()
        + b"#!/bin/bash\necho hello\n"
    )
    assert seen["input"] == expected
    assert seen["command"] == "/bin/bash -s -- setup"
    assert seen["capture"] is False
    assert seen["timeout"] == guest.GUEST_PIPE_TIMEOUT
    assert seen["machine"] is bb
    # shlex.quote leaves a plain value bare and hard-quotes a space+quote value.
    body = seen["input"].decode()
    assert "export BB_ALLOWED_HOST_IP=100.64.0.1\n" in body
    assert "export BLUEBUBBLES_PASSWORD='a b'\"'\"'c'\n" in body


async def test_guest_pipe_no_args_bare_command(manifest, monkeypatch, tmp_path):
    script = tmp_path / "s.sh"
    script.write_bytes(b"true\n")
    seen: dict[str, object] = {}

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        seen["command"] = command
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    await guest.guest_pipe(manifest.machines["bluebubbles"], str(script))
    assert seen["command"] == "/bin/bash -s --"


async def test_guest_pipe_quotes_multiple_args(manifest, monkeypatch, tmp_path):
    script = tmp_path / "s.sh"
    script.write_bytes(b"true\n")
    seen: dict[str, object] = {}

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        seen["command"] = command
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    await guest.guest_pipe(manifest.machines["bluebubbles"], str(script), "harden", "a b")
    assert seen["command"] == "/bin/bash -s -- harden 'a b'"


async def test_guest_pipe_prelude_includes_debloat_for_bluebubbles(manifest, monkeypatch, tmp_path):
    script = tmp_path / "s.sh"
    script.write_bytes(b"true\n")
    seen: dict[str, object] = {}

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        seen["input"] = input
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    await guest.guest_pipe(manifest.machines["bluebubbles"], str(script))
    body = seen["input"].decode()
    debloat = manifest.debloat["bluebubbles"]
    assert "YCLAW_NODE=bluebubbles\n" in body
    assert f"YCLAW_DEBLOAT_SYSTEM='{' '.join(debloat.system)}'\n" in body
    assert f"YCLAW_DEBLOAT_GUI='{' '.join(debloat.gui)}'\n" in body


async def test_guest_pipe_prelude_omits_debloat_for_node_without_it(manifest, monkeypatch, tmp_path):
    script = tmp_path / "s.sh"
    script.write_bytes(b"true\n")
    seen: dict[str, object] = {}

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        seen["input"] = input
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    await guest.guest_pipe(manifest.machines["hermes"], str(script))
    body = seen["input"].decode()
    assert "YCLAW_NODE=hermes\n" in body
    assert "YCLAW_DEBLOAT_SYSTEM" not in body
    assert "YCLAW_DEBLOAT_GUI" not in body


async def test_guest_pipe_does_not_log_env_values(manifest, monkeypatch, tmp_path):
    script = tmp_path / "s.sh"
    script.write_bytes(b"true\n")

    async def fake(machine, command, *, timeout=30, capture=True, input=None):
        return RemoteResult(0, "", "")

    monkeypatch.setattr(remote, "run", fake)
    secret = "sup3r-s3cr3t-pw"
    logged: list[str] = []
    sink = logger.add(logged.append, level="DEBUG", format="{message}")
    try:
        await guest.guest_pipe(
            manifest.machines["bluebubbles"], str(script), "setup", env={"BLUEBUBBLES_PASSWORD": secret}
        )
    finally:
        logger.remove(sink)
    assert all(secret not in m for m in logged)
