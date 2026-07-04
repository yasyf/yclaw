"""Typed, frozen view over the canonical ``machines.json`` fleet manifest.

``load_manifest`` resolves the manifest deterministically from the package location:
``<package parent>/machines.json`` — the ``yclaw`` package lives at the repo root
(``module-root = ""``), so ``Path(__file__).parent.parent`` is the repo root and the manifest
sits next to the package directory. The path never depends on the current working directory.
Pass an explicit ``path`` to load a manifest from elsewhere (tests, alternate checkouts).

Required keys crash loudly: a missing key raises ``KeyError``, a malformed tagged union raises
``ManifestError``. Keys whose JSON value is ``null`` (``host`` has no ``ssh``/``tart_vm``/…) map
to ``None`` — that is real fleet shape, not a defaulted-away requirement.
"""

import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

DEFAULT_MANIFEST_PATH = Path(__file__).resolve().parent.parent / "machines.json"


class ManifestError(Exception):
    """The manifest is present but structurally invalid (e.g. an unknown tagged-union kind)."""


@dataclass(frozen=True, slots=True)
class LaunchdRef:
    domain: str
    label: str

    @property
    def target(self) -> str:
        return f"{self.domain}/{self.label}"

    @property
    def plist_path(self) -> str:
        return f"/Library/LaunchDaemons/{self.label}.plist"


@dataclass(frozen=True, slots=True)
class HttpHealth:
    url: str


@dataclass(frozen=True, slots=True)
class TcpHealth:
    host: str
    port: int


type HealthCheck = HttpHealth | TcpHealth


@dataclass(frozen=True, slots=True)
class Ssh:
    transport: str
    user: str


@dataclass(frozen=True, slots=True)
class Service:
    name: str
    launchd: LaunchdRef | None
    systemd: str | None
    port: int | None
    serve_port: int | None
    mitm_port: int | None
    oneshot: bool
    start_interval: int | None
    health: HealthCheck | None
    logs: tuple[str, ...]
    password_keychain: str | None
    password_query_param: str | None


@dataclass(frozen=True, slots=True)
class Machine:
    name: str
    os: str
    managed_by: str
    tart_vm: str | None
    tag: str | None
    ssh: Ssh | None
    admin_pass_keychain: str | None
    shares: tuple[str, ...] | None
    services: Mapping[str, Service]


@dataclass(frozen=True, slots=True)
class Keychain:
    login_unlock: str
    agent_vault_master: str
    ts_oauth_client_id: str
    ts_oauth_client_secret: str


@dataclass(frozen=True, slots=True)
class HostPaths:
    state_dir_rel: str
    node_config_dir_rel: str
    state_subdirs_mounts: tuple[str, ...]
    state_subdirs_wipe: tuple[str, ...]
    keychain_generated_services: tuple[str, ...]
    keychain: Keychain


@dataclass(frozen=True, slots=True)
class Debloat:
    system: tuple[str, ...]
    gui: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Manifest:
    machines: Mapping[str, Machine]
    host_paths: HostPaths
    debloat: Mapping[str, Debloat]


def _parse_health(d: dict[str, Any]) -> HealthCheck:
    kind = d["kind"]
    if kind == "http":
        return HttpHealth(url=d["url"])
    if kind == "tcp":
        return TcpHealth(host=d["host"], port=d["port"])
    raise ManifestError(f"unknown health kind: {kind!r}")


def _parse_service(name: str, d: dict[str, Any]) -> Service:
    return Service(
        name=name,
        launchd=LaunchdRef(domain=d["launchd"]["domain"], label=d["launchd"]["label"]) if "launchd" in d else None,
        systemd=d.get("systemd"),
        port=d.get("port"),
        serve_port=d.get("serve_port"),
        mitm_port=d.get("mitm_port"),
        oneshot=bool(d.get("oneshot", False)),
        start_interval=d.get("start_interval"),
        health=_parse_health(d["health"]) if "health" in d else None,
        logs=tuple(d.get("logs", ())),
        password_keychain=d.get("password_keychain"),
        password_query_param=d.get("password_query_param"),
    )


def _parse_machine(name: str, d: dict[str, Any]) -> Machine:
    ssh = d["ssh"]
    shares = d["shares"]
    return Machine(
        name=name,
        os=d["os"],
        managed_by=d["managed_by"],
        tart_vm=d["tart_vm"],
        tag=d["tag"],
        ssh=Ssh(transport=ssh["transport"], user=ssh["user"]) if ssh is not None else None,
        admin_pass_keychain=d["admin_pass_keychain"],
        shares=tuple(shares) if shares is not None else None,
        services=MappingProxyType({n: _parse_service(n, sd) for n, sd in d["services"].items()}),
    )


def _parse_host_paths(d: dict[str, Any]) -> HostPaths:
    kc = d["keychain"]
    return HostPaths(
        state_dir_rel=d["state_dir_rel"],
        node_config_dir_rel=d["node_config_dir_rel"],
        state_subdirs_mounts=tuple(d["state_subdirs_mounts"]),
        state_subdirs_wipe=tuple(d["state_subdirs_wipe"]),
        keychain_generated_services=tuple(d["keychain_generated_services"]),
        keychain=Keychain(
            login_unlock=kc["login_unlock"],
            agent_vault_master=kc["agent_vault_master"],
            ts_oauth_client_id=kc["ts_oauth_client_id"],
            ts_oauth_client_secret=kc["ts_oauth_client_secret"],
        ),
    )


def load_manifest(path: Path | None = None) -> Manifest:
    data = json.loads((path or DEFAULT_MANIFEST_PATH).read_text())
    return Manifest(
        machines=MappingProxyType({n: _parse_machine(n, md) for n, md in data["machines"].items()}),
        host_paths=_parse_host_paths(data["host_paths"]),
        debloat=MappingProxyType(
            {n: Debloat(system=tuple(dd["system"]), gui=tuple(dd["gui"])) for n, dd in data["debloat"].items()}
        ),
    )
