import click
import pytest

from yclaw.dispatch import resolve_machine, resolve_service, run
from yclaw.manifest import load_manifest
from yclaw.output import EXIT_CHECK_WALL, EXIT_TIMEOUT
from yclaw.remote import CheckWallError, RemoteTimeout


def test_resolve_machine_ok():
    assert resolve_machine(load_manifest(), "metal").name == "metal"


def test_resolve_machine_unknown_raises_bad_parameter():
    with pytest.raises(click.BadParameter, match="unknown machine"):
        resolve_machine(load_manifest(), "nope")


def test_resolve_machine_host_is_rejected():
    with pytest.raises(click.BadParameter, match="not a tailnet node"):
        resolve_machine(load_manifest(), "host")


def test_resolve_service_unknown_raises_bad_parameter():
    metal = resolve_machine(load_manifest(), "metal")
    with pytest.raises(click.BadParameter, match="unknown service"):
        resolve_service(metal, "nope")


def test_run_returns_value():
    async def compute():
        return 7

    assert run(compute) == 7


def test_run_maps_check_wall_to_exit_4():
    async def boom():
        raise CheckWallError("https://login.tailscale.com/a/abc123")

    with pytest.raises(SystemExit) as excinfo:
        run(boom)
    assert excinfo.value.code == EXIT_CHECK_WALL


def test_run_maps_timeout_to_exit_5():
    async def boom():
        raise RemoteTimeout("sleep 1", 0.5)

    with pytest.raises(SystemExit) as excinfo:
        run(boom)
    assert excinfo.value.code == EXIT_TIMEOUT
