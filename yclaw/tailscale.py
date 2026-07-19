"""Tailscale HTTP API: OAuth token exchange, tagged authkey minting, and device listing.

Ports ``_ts_mint_key`` from ``scripts/lib/secrets.sh``. Minted keys are persistent (non-ephemeral),
single-use, pre-authorized, and tagged ``tag:<host>`` — NON-ephemeral is load-bearing for an
always-on server: an ephemeral node is auto-reaped ~30-60min after it disconnects and its
single-use key is already spent, stranding the whole stack, while a persistent tagged node keeps
its registration and reconnects from on-disk tailscaled state with no authkey. ``expirySeconds`` is
the redemption window (24h, so a cold bootstrap whose builds run for hours cannot expire the key
before first boot), not the node lifetime. Error messages never carry a credential.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

import httpx

API = "https://api.tailscale.com/api/v2"
HTTP_TIMEOUT = 30.0


class TailscaleError(Exception):
    """A Tailscale API call failed or returned an unusable payload."""


@dataclass(frozen=True, slots=True)
class Device:
    hostname: str
    name: str
    tags: tuple[str, ...]


@asynccontextmanager
async def _http_client(client: httpx.AsyncClient | None) -> AsyncIterator[httpx.AsyncClient]:
    if client is not None:
        yield client
    else:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as owned:
            yield owned


async def oauth_token(client_id: str, client_secret: str, *, client: httpx.AsyncClient | None = None) -> str:
    try:
        async with _http_client(client) as c:
            resp = await c.post(f"{API}/oauth/token", data={"client_id": client_id, "client_secret": client_secret})
            resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise TailscaleError(f"Tailscale OAuth token exchange failed: {exc}") from exc
    token = resp.json().get("access_token", "")
    if not token:
        raise TailscaleError("Tailscale OAuth token exchange returned no access_token")
    return token


async def mint_authkey(token: str, host: str, *, client: httpx.AsyncClient | None = None) -> str:
    body = {
        "capabilities": {
            "devices": {
                "create": {
                    "reusable": False,
                    "ephemeral": False,
                    "preauthorized": True,
                    "tags": [f"tag:{host}"],
                }
            }
        },
        "expirySeconds": 86400,
        "description": f"yclaw bootstrap {host}",
    }
    try:
        async with _http_client(client) as c:
            resp = await c.post(f"{API}/tailnet/-/keys", json=body, headers={"Authorization": f"Bearer {token}"})
            resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise TailscaleError(f"Tailscale key mint failed for {host}: {exc}") from exc
    key = resp.json().get("key", "")
    if not key.startswith("tskey-"):
        raise TailscaleError(f"Tailscale key mint for {host} did not return a tskey-… key")
    return key


async def list_devices(token: str, *, client: httpx.AsyncClient | None = None) -> tuple[Device, ...]:
    try:
        async with _http_client(client) as c:
            resp = await c.get(f"{API}/tailnet/-/devices", headers={"Authorization": f"Bearer {token}"})
            resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise TailscaleError(f"Tailscale device list failed: {exc}") from exc
    return tuple(
        Device(hostname=d["hostname"], name=d["name"], tags=tuple(d.get("tags", ()))) for d in resp.json()["devices"]
    )
