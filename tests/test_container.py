import subprocess

import anyio
import pytest

from yclaw import container
from yclaw.container import ContainerResult, ContainerTimeout

pytestmark = pytest.mark.anyio


def _completed(argv, returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(argv, returncode, stdout=stdout, stderr=stderr)


async def test_exec_run_builds_container_exec_argv(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"hi\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = await container.exec_run("hermes", "echo hi")
    assert seen == [["/opt/homebrew/bin/container", "exec", "hermes", "sh", "-c", "echo hi"]]
    assert result == ContainerResult(0, "hi\n", "")


async def test_exec_run_drops_uid_via_setpriv_keeping_group_zero(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv, 0, b"uid=1000(hermes)\n", b"")

    monkeypatch.setattr(anyio, "run_process", fake)
    await container.exec_run("hermes", "id", uid=1000)
    assert seen == [
        [
            "/opt/homebrew/bin/container",
            "exec",
            "hermes",
            "sh",
            "-c",
            "setpriv --reuid=1000 --regid=1000 --groups=1000,0 --no-new-privs -- sh -c id",
        ]
    ]


async def test_exec_run_uid_single_quotes_the_inner_command(monkeypatch):
    seen = []

    async def fake(argv, **kwargs):
        seen.append(argv)
        return _completed(argv)

    monkeypatch.setattr(anyio, "run_process", fake)
    await container.exec_run("hermes", "echo a && echo b", uid=1000)
    assert seen[0][-1] == (
        "setpriv --reuid=1000 --regid=1000 --groups=1000,0 --no-new-privs -- sh -c 'echo a && echo b'"
    )


async def test_exec_run_preserves_real_exit_code_and_streams(monkeypatch):
    # container exec propagates the inner exit code (unlike Tailscale-intercepted ssh, always 0).
    async def fake(argv, **kwargs):
        return _completed(argv, 7, b"out\n", b"err\n")

    monkeypatch.setattr(anyio, "run_process", fake)
    result = await container.exec_run("hermes", "false")
    assert result == ContainerResult(7, "out\n", "err\n")


async def test_exec_run_timeout_raises_container_timeout(monkeypatch):
    async def slow(argv, **kwargs):
        await anyio.sleep(5)
        return _completed(argv)

    monkeypatch.setattr(anyio, "run_process", slow)
    with pytest.raises(ContainerTimeout) as excinfo:
        await container.exec_run("hermes", "sleep 100", timeout=0.05)
    assert excinfo.value.name == "hermes"
    assert excinfo.value.command == "sleep 100"
    assert excinfo.value.timeout == 0.05
