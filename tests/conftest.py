from pathlib import Path

import pytest

from yclaw.manifest import load_manifest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(scope="session")
def manifest():
    return load_manifest()


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES
