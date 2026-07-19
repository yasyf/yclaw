import json

import httpx
import pytest

from yclaw import tailscale
from yclaw.tailscale import Device, TailscaleError

pytestmark = pytest.mark.anyio


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_oauth_token_returns_access_token():
    def handler(request):
        assert request.url.path.endswith("/oauth/token")
        return httpx.Response(200, json={"access_token": "tok-abc"})

    async with _client(handler) as client:
        assert await tailscale.oauth_token("cid", "csec", client=client) == "tok-abc"


async def test_oauth_token_without_access_token_raises():
    async with _client(lambda request: httpx.Response(200, json={})) as client:
        with pytest.raises(TailscaleError, match="no access_token"):
            await tailscale.oauth_token("cid", "csec", client=client)


async def test_mint_authkey_sends_persistent_single_use_tagged_body():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        seen["auth"] = request.headers["Authorization"]
        return httpx.Response(200, json={"key": "tskey-xyz"})

    async with _client(handler) as client:
        key = await tailscale.mint_authkey("tok", "metal", client=client)

    assert key == "tskey-xyz"
    assert seen["auth"] == "Bearer tok"
    create = seen["body"]["capabilities"]["devices"]["create"]
    assert create == {"reusable": False, "ephemeral": False, "preauthorized": True, "tags": ["tag:metal"]}
    assert seen["body"]["expirySeconds"] == 86400  # 24h redemption window, not node lifetime


async def test_mint_authkey_rejects_non_tskey_response():
    async with _client(lambda request: httpx.Response(200, json={"key": "nope"})) as client:
        with pytest.raises(TailscaleError, match="tskey"):
            await tailscale.mint_authkey("tok", "metal", client=client)


async def test_list_devices_parses_hostname_name_and_tags():
    def handler(request):
        return httpx.Response(
            200,
            json={
                "devices": [
                    {"hostname": "metal", "name": "metal.tail.ts.net", "tags": ["tag:metal"]},
                    {"hostname": "bb", "name": "bb.tail.ts.net"},
                ]
            },
        )

    async with _client(handler) as client:
        devices = await tailscale.list_devices("tok", client=client)

    assert devices == (
        Device("metal", "metal.tail.ts.net", ("tag:metal",)),
        Device("bb", "bb.tail.ts.net", ()),
    )


async def test_http_failure_is_wrapped_in_tailscale_error():
    async with _client(lambda request: httpx.Response(500)) as client:
        with pytest.raises(TailscaleError, match="device list failed"):
            await tailscale.list_devices("tok", client=client)
