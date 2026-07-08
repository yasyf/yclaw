import json
import socket
import urllib.parse

import anyio
import httpx
import pytest

from yclaw import keychain
from yclaw.onboard import google_oauth
from yclaw.onboard.google_oauth import (
    CodeExchangeError,
    ConsentTimeout,
    GoogleOAuthConfig,
    MissingRefreshTokenError,
    OAuthResult,
    VaultAuthError,
    VaultStatusError,
    VaultUploadError,
)

pytestmark = pytest.mark.anyio

MASTER = "master-pw"
CODE = "AUTHCODE-XYZ"
CLIENT_ID = "CID.apps.googleusercontent.com"
CLIENT_SECRET = "CLIENTSECRET-XYZ"
ACCESS = "ACCESS-XYZ"
REFRESH = "REFRESH-XYZ"
BEARER = "BEARER-XYZ"
SECRETS = (CLIENT_SECRET, ACCESS, REFRESH, CODE, MASTER, BEARER)


def _free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


async def _get(url: str, *, deadline: float = 3.0) -> httpx.Response:
    with anyio.fail_after(deadline):
        while True:
            try:
                async with httpx.AsyncClient(timeout=2.0) as client:
                    return await client.get(url)
            except httpx.ConnectError:
                await anyio.sleep(0.02)


@pytest.fixture
def config(tmp_path):
    secret = tmp_path / "client_secret.json"
    secret.write_text(json.dumps({"installed": {"client_id": CLIENT_ID, "client_secret": CLIENT_SECRET}}))
    return GoogleOAuthConfig(
        vault_url="http://vault.local:14321",
        owner="admin@metal.local",
        vault_name=google_oauth.VAULT_NAME,
        key=google_oauth.TOKEN_KEY,
        scopes=google_oauth.SCOPES,
        listen_port=8723,
        auth_url=google_oauth.AUTH_URL,
        token_url=google_oauth.TOKEN_URL,
        client_secret_path=secret,
        master_service="yclaw-agent-vault-master",
    )


def _vault_handler(
    *,
    login_status=200,
    exchange_status=200,
    upload_status=200,
    status_status=200,
    refresh_token=REFRESH,
    connected=True,
    seen=None,
):
    def handler(request):
        if seen is not None:
            seen.append(request)
        path = request.url.path
        if path == "/v1/auth/login":
            if login_status != 200:
                return httpx.Response(login_status)
            assert json.loads(request.content) == {
                "email": "admin@metal.local",
                "password": MASTER,
                "device_label": "google-oauth",
            }
            return httpx.Response(200, json={"token": BEARER})
        if request.url.host == "oauth2.googleapis.com":
            if exchange_status != 200:
                return httpx.Response(exchange_status, json={"error": "invalid_grant"})
            form = dict(urllib.parse.parse_qsl(request.content.decode()))
            assert form == {
                "code": CODE,
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "redirect_uri": "http://localhost:8723",
                "grant_type": "authorization_code",
            }
            body = {"access_token": ACCESS}
            if refresh_token is not None:
                body["refresh_token"] = refresh_token
            return httpx.Response(200, json=body)
        if path == "/v1/credentials/oauth/tokens":
            assert request.headers["Authorization"] == f"Bearer {BEARER}"
            if upload_status != 200:
                return httpx.Response(upload_status)
            assert json.loads(request.content) == {
                "vault": "hermes",
                "key": "GOOGLE_OAUTH_TOKEN",
                "access_token": ACCESS,
                "refresh_token": REFRESH,
                "token_url": google_oauth.TOKEN_URL,
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "token_auth_method": "client_secret_post",
            }
            return httpx.Response(200, json={"ok": True})
        if path == "/v1/credentials/oauth/status":
            assert request.headers["Authorization"] == f"Bearer {BEARER}"
            if status_status != 200:
                return httpx.Response(status_status)
            assert request.url.params["vault"] == "hermes"
            assert request.url.params["key"] == "GOOGLE_OAUTH_TOKEN"
            return httpx.Response(200, json={"connected": connected})
        raise AssertionError(f"unexpected request: {request.url}")

    return handler


@pytest.fixture
def stub_seams(config, monkeypatch):
    monkeypatch.setattr(google_oauth.keychain, "read", _fake_keychain_read)

    async def fake_capture(port, *, ceiling, expected_state):
        assert port == config.listen_port
        assert expected_state  # a per-run state nonce is threaded from connect()
        return CODE

    monkeypatch.setattr(google_oauth, "_capture_code", fake_capture)


def _fake_keychain_read(service: str) -> str:
    assert service == "yclaw-agent-vault-master"
    return MASTER


async def _connect(config, handler, **kwargs):
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        return await google_oauth.connect(
            config,
            open_browser=kwargs.pop("open_browser", lambda url: None),
            on_status=kwargs.pop("on_status", lambda url: None),
            client=client,
            **kwargs,
        )


# --- loopback listener (real local connection) --------------------------------------------------


STATE = "STATE-TOKEN-XYZ"


async def test_capture_code_returns_the_redirect_code():
    port = _free_port()
    captured: dict[str, str] = {}

    async with anyio.create_task_group() as tg:

        async def run():
            captured["code"] = await google_oauth._capture_code(port, ceiling=5, expected_state=STATE)

        tg.start_soon(run)
        response = await _get(f"http://127.0.0.1:{port}/?code={CODE}&state={STATE}&scope=openid")
        assert response.status_code == 200
        assert "close this tab" in response.text.lower()

    assert captured["code"] == CODE


async def test_capture_code_ignores_mismatched_state_then_captures():
    port = _free_port()
    captured: dict[str, str] = {}

    async with anyio.create_task_group() as tg:

        async def run():
            captured["code"] = await google_oauth._capture_code(port, ceiling=5, expected_state=STATE)

        tg.start_soon(run)
        # A forged code carrying the wrong state is treated like a no-code request: waiting page.
        forged = await _get(f"http://127.0.0.1:{port}/?code=FORGED&state=WRONG")
        assert "waiting" in forged.text.lower()
        final = await _get(f"http://127.0.0.1:{port}/?code=SECOND&state={STATE}")
        assert final.status_code == 200

    assert captured["code"] == "SECOND"


async def test_capture_code_times_out_without_a_code():
    port = _free_port()
    with pytest.raises(ConsentTimeout) as excinfo:
        await google_oauth._capture_code(port, ceiling=0.2, expected_state=STATE)
    assert excinfo.value.port == port
    assert excinfo.value.ceiling == 0.2


# --- connect: happy path ------------------------------------------------------------------------


async def test_connect_drives_login_exchange_upload_status(config, stub_seams):
    seen: list[httpx.Request] = []
    events: list[tuple[str, str]] = []
    result = await _connect(
        config,
        _vault_handler(seen=seen),
        on_status=lambda url: events.append(("status", url)),
        open_browser=lambda url: events.append(("open", url)),
    )

    assert result == OAuthResult(connected=True, detail="connected")
    paths = [f"{r.url.host}{r.url.path}" for r in seen]
    assert paths == [
        "vault.local/v1/auth/login",
        "oauth2.googleapis.com/token",
        "vault.local/v1/credentials/oauth/tokens",
        "vault.local/v1/credentials/oauth/status",
    ]
    assert [kind for kind, _ in events] == ["status", "open"]
    consent = events[0][1]
    assert events[1][1] == consent
    params = urllib.parse.parse_qs(urllib.parse.urlparse(consent).query)
    assert params["access_type"] == ["offline"]
    assert params["prompt"] == ["consent"]
    assert params["response_type"] == ["code"]
    assert params["redirect_uri"] == ["http://localhost:8723"]
    assert params["client_id"] == [CLIENT_ID]
    assert params["scope"] == [" ".join(google_oauth.SCOPES)]
    assert params["state"][0]  # a non-empty per-run CSRF nonce is present


async def test_connect_completes_when_browser_open_raises(config, stub_seams):
    echoed: list[str] = []

    def open_browser(url):
        raise RuntimeError("open failed")

    result = await _connect(
        config,
        _vault_handler(),
        on_status=echoed.append,
        open_browser=open_browser,
    )
    assert result.connected is True
    assert len(echoed) == 1
    assert echoed[0].startswith(google_oauth.AUTH_URL)


async def test_connect_never_surfaces_secrets(config, stub_seams):
    exposed: list[str] = []
    await _connect(config, _vault_handler(), on_status=exposed.append, open_browser=exposed.append)
    joined = "\n".join(exposed)
    for secret in SECRETS:
        assert secret not in joined


# --- connect: failure modes ---------------------------------------------------------------------


async def test_connect_missing_refresh_token_raises(config, stub_seams):
    with pytest.raises(MissingRefreshTokenError):
        await _connect(config, _vault_handler(refresh_token=None))


async def test_connect_exchange_rejection_raises(config, stub_seams):
    with pytest.raises(CodeExchangeError) as excinfo:
        await _connect(config, _vault_handler(exchange_status=400))
    assert excinfo.value.status_code == 400
    assert excinfo.value.reason == "invalid_grant"


async def test_connect_upload_failure_raises(config, stub_seams):
    with pytest.raises(VaultUploadError) as excinfo:
        await _connect(config, _vault_handler(upload_status=502))
    assert excinfo.value.status_code == 502
    assert excinfo.value.vault_url == "http://vault.local:14321"


async def test_connect_vault_login_failure_raises(config, stub_seams):
    with pytest.raises(VaultAuthError) as excinfo:
        await _connect(config, _vault_handler(login_status=401))
    assert excinfo.value.status_code == 401


async def test_connect_status_query_failure_raises(config, stub_seams):
    with pytest.raises(VaultStatusError) as excinfo:
        await _connect(config, _vault_handler(status_status=503))
    assert excinfo.value.status_code == 503


# --- status (detection) -------------------------------------------------------------------------


@pytest.mark.parametrize("connected", [True, False], ids=["connected", "not-connected"])
async def test_status_reports_vault_state(config, monkeypatch, connected):
    monkeypatch.setattr(google_oauth.keychain, "read", _fake_keychain_read)
    async with httpx.AsyncClient(transport=httpx.MockTransport(_vault_handler(connected=connected))) as client:
        result = await google_oauth.status(config, client=client)
    assert result == OAuthResult(connected=connected, detail="connected" if connected else "not connected")


async def test_status_propagates_keychain_error(config, monkeypatch):
    def boom(service):
        raise keychain.KeychainError("no keychain")

    monkeypatch.setattr(google_oauth.keychain, "read", boom)
    with pytest.raises(keychain.KeychainError):
        await google_oauth.status(config)


# --- config + client-secret parsing -------------------------------------------------------------


def test_config_for_machine_derives_facts_from_manifest(manifest):
    cfg = google_oauth.config_for_machine(manifest.machines["metal"])
    assert cfg.vault_url == "http://metal:14321"
    assert cfg.owner == "admin@metal.local"
    assert cfg.master_service == "yclaw-agent-vault-master"
    assert cfg.listen_port == 8723
    assert cfg.vault_name == "hermes"
    assert cfg.key == "GOOGLE_OAUTH_TOKEN"
    assert cfg.token_url == "https://oauth2.googleapis.com/token"
    assert cfg.scopes == google_oauth.SCOPES


@pytest.mark.parametrize("section", ["installed", "web"], ids=["installed-client", "web-client"])
def test_read_client_secret_accepts_installed_or_web(tmp_path, section):
    path = tmp_path / "cs.json"
    path.write_text(json.dumps({section: {"client_id": "the-id", "client_secret": "the-secret"}}))
    secret = google_oauth._read_client_secret(path)
    assert secret.client_id == "the-id"
    assert secret.client_secret == "the-secret"


@pytest.mark.parametrize(
    ("request_line", "expected"),
    [
        ("GET /?code=abc123&state=S&scope=openid HTTP/1.1", "abc123"),
        ("GET /?code=abc123&state=WRONG HTTP/1.1", None),
        ("GET /?code=abc123 HTTP/1.1", None),
        ("GET /?error=access_denied&state=S HTTP/1.1", None),
        ("GET /favicon.ico HTTP/1.1", None),
        ("", None),
    ],
    ids=["code", "wrong-state", "no-state", "denied", "no-query", "empty"],
)
def test_code_from_request_line(request_line, expected):
    assert google_oauth._code_from_request_line(request_line, "S") == expected
