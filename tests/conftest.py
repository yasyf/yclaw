from pathlib import Path

import pytest

from yclaw.manifest import _parse_machine, load_manifest

FIXTURES = Path(__file__).parent / "fixtures"

# A container-native node as machines.json would carry it once hermes migrates off the tart VM:
# os=linux, managed_by=container, null ssh/tart_vm/shares, one container_proc service.
CONTAINER_NODE = {
    "os": "linux",
    "managed_by": "container",
    "tart_vm": None,
    "container": "hermes",
    "tag": "tag:hermes",
    "ssh": None,
    "admin_pass_keychain": None,
    "shares": None,
    "services": {"hermes-agent": {"container_proc": "hermes gateway run"}},
}


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(scope="session")
def manifest():
    return load_manifest()


@pytest.fixture
def container_machine():
    return _parse_machine("hermes", CONTAINER_NODE)


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES
