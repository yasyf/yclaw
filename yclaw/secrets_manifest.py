"""Typed, frozen view over ``nixos/secrets-manifest.json`` — which host owns which secret.

Mirrors ``manifest.py``: the path resolves deterministically from the package location
(``<repo root>/nixos/secrets-manifest.json``), required keys crash loudly (a missing key raises
``KeyError``, an unknown catalog kind raises ``SecretsManifestError``), and every shaped value is a
frozen dataclass. The catalog is a tagged union on ``kind`` — classification (shared vs per-host)
is driven by ``kind``, never by a key's name: ``vault/master-password`` is SHARED despite the name.
"""

import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

DEFAULT_SECRETS_MANIFEST_PATH = Path(__file__).resolve().parent.parent / "nixos" / "secrets-manifest.json"


class SecretsManifestError(Exception):
    """The secrets manifest is present but structurally invalid (e.g. an unknown catalog kind)."""


@dataclass(frozen=True, slots=True)
class ScalarSecret:
    var: str


@dataclass(frozen=True, slots=True)
class PerHostSecret:
    var: str


@dataclass(frozen=True, slots=True)
class EnvBlockSecret:
    vars: tuple[str, ...]


type CatalogEntry = ScalarSecret | PerHostSecret | EnvBlockSecret


@dataclass(frozen=True, slots=True)
class HostSecrets:
    name: str
    secrets: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class SecretsManifest:
    hosts: Mapping[str, HostSecrets]
    catalog: Mapping[str, CatalogEntry]

    def owners(self, key: str) -> tuple[str, ...]:
        return tuple(host.name for host in self.hosts.values() if key in host.secrets)


def _parse_catalog(key: str, d: dict[str, Any]) -> CatalogEntry:
    kind = d["kind"]
    if kind == "scalar":
        return ScalarSecret(var=d["var"])
    if kind == "perhost":
        return PerHostSecret(var=d["var"])
    if kind == "envblock":
        return EnvBlockSecret(vars=tuple(d["vars"]))
    raise SecretsManifestError(f"unknown catalog kind for {key!r}: {kind!r}")


def load_secrets_manifest(path: Path | None = None) -> SecretsManifest:
    data = json.loads((path or DEFAULT_SECRETS_MANIFEST_PATH).read_text())
    return SecretsManifest(
        hosts=MappingProxyType(
            {name: HostSecrets(name=name, secrets=tuple(hd["secrets"])) for name, hd in data["hosts"].items()}
        ),
        catalog=MappingProxyType({key: _parse_catalog(key, cd) for key, cd in data["catalog"].items()}),
    )
