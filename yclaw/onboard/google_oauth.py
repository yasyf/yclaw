"""Connect a Google Workspace OAuth credential to the agent-vault ``hermes`` vault, headlessly.

Absorbs the retired ``scripts/connect-google-oauth.py``: the vault master password is read ONCE
from the dedicated yclaw keychain (``keychain.read``, which raises when absent and never creates),
the local ``gws`` desktop OAuth client's ``client_secret.json`` supplies the client id/secret, an
anyio loopback listener captures the ``?code=`` the browser redirect delivers, the code is exchanged
for access+refresh tokens (``access_type=offline`` + ``prompt=consent`` so a refresh token is
issued), the tokens are uploaded to the vault, and the vault OAuth status is re-checked.

Secrets never leave this module in the clear: the master password and client secret ride request
bodies, tokens and the captured code are never logged or echoed, and only the consent URL (safe,
PKCE-free but public) reaches ``on_status``/``open_browser``.
"""

import json
import secrets
import urllib.parse
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path

import anyio
import httpx
from anyio.abc import SocketStream

from .. import keychain
from ..manifest import Machine, load_manifest

LISTEN_PORT = 8723
VAULT_NAME = "hermes"
TOKEN_KEY = "GOOGLE_OAUTH_TOKEN"
VAULT_OWNER_ACCOUNT = "admin"
DEVICE_LABEL = "google-oauth"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
HTTP_TIMEOUT = 30.0
DEFAULT_CONSENT_CEILING = 600.0
DEFAULT_CLIENT_SECRET = Path.home() / ".config" / "gws" / "client_secret.json"
SCOPES = (
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/presentations",
    "https://www.googleapis.com/auth/tasks",
)
_SUCCESS_HTML = (
    "<!doctype html><meta charset=utf-8><title>Connected</title>"
    "<body style='font-family:system-ui;padding:2rem'>"
    "<h2>Google connected to the vault.</h2><p>You can close this tab.</p></body>"
)
_WAITING_HTML = (
    "<!doctype html><meta charset=utf-8><title>Waiting</title>"
    "<body style='font-family:system-ui;padding:2rem'>"
    "<p>Waiting for the OAuth code…</p></body>"
)
_REQUEST_LINE_LIMIT = 8192


class GoogleOAuthError(Exception):
    """Base class for Google OAuth connect failures."""


class ConsentTimeout(GoogleOAuthError):
    """The loopback listener never captured a code before the ceiling."""

    def __init__(self, port: int, ceiling: float) -> None:
        super().__init__(
            f"no OAuth code received on 127.0.0.1:{port} within {ceiling:.0f}s — "
            "re-run and approve the consent URL in a browser on this Mac"
        )
        self.port = port
        self.ceiling = ceiling


class CodeExchangeError(GoogleOAuthError):
    """Google rejected the authorization code at the token endpoint."""

    def __init__(self, status_code: int, reason: str) -> None:
        detail = f": {reason}" if reason else ""
        super().__init__(
            f"Google rejected the authorization code (HTTP {status_code}{detail}) — re-run to get a fresh code"
        )
        self.status_code = status_code
        self.reason = reason


class MissingRefreshTokenError(GoogleOAuthError):
    """The token exchange succeeded but returned no refresh_token."""

    def __init__(self) -> None:
        super().__init__(
            "Google returned no refresh_token (needs prompt=consent + access_type=offline) — "
            "revoke this app under myaccount.google.com/permissions, then re-run"
        )


class VaultAuthError(GoogleOAuthError):
    """The vault login rejected the master password."""

    def __init__(self, vault_url: str, status_code: int) -> None:
        super().__init__(
            f"vault login at {vault_url} failed (HTTP {status_code}) — "
            "the master password may be stale; re-run 'just bootstrap'"
        )
        self.vault_url = vault_url
        self.status_code = status_code


class VaultUploadError(GoogleOAuthError):
    """The vault rejected the OAuth token upload."""

    def __init__(self, vault_url: str, status_code: int) -> None:
        super().__init__(f"vault token upload to {vault_url} failed (HTTP {status_code}) — re-run this gate")
        self.vault_url = vault_url
        self.status_code = status_code


class VaultStatusError(GoogleOAuthError):
    """The vault OAuth status query failed."""

    def __init__(self, vault_url: str, status_code: int) -> None:
        super().__init__(f"vault OAuth status query at {vault_url} failed (HTTP {status_code})")
        self.vault_url = vault_url
        self.status_code = status_code


@dataclass(frozen=True, slots=True)
class GoogleOAuthConfig:
    vault_url: str
    owner: str
    vault_name: str
    key: str
    scopes: tuple[str, ...]
    listen_port: int
    auth_url: str
    token_url: str
    client_secret_path: Path
    master_service: str


@dataclass(frozen=True, slots=True)
class OAuthResult:
    connected: bool
    detail: str


@dataclass(frozen=True, slots=True)
class _ClientSecret:
    client_id: str
    client_secret: str


@dataclass(frozen=True, slots=True)
class _Tokens:
    access: str
    refresh: str


def config_for_machine(
    machine: Machine,
    *,
    client_secret_path: Path = DEFAULT_CLIENT_SECRET,
    listen_port: int = LISTEN_PORT,
) -> GoogleOAuthConfig:
    vault = machine.services["agent-vault"]
    keychain_services = load_manifest().host_paths.keychain
    return GoogleOAuthConfig(
        vault_url=f"http://{machine.name}:{vault.port}",
        owner=f"{VAULT_OWNER_ACCOUNT}@{machine.name}.local",
        vault_name=VAULT_NAME,
        key=TOKEN_KEY,
        scopes=SCOPES,
        listen_port=listen_port,
        auth_url=AUTH_URL,
        token_url=TOKEN_URL,
        client_secret_path=client_secret_path,
        master_service=keychain_services.agent_vault_master,
    )


@asynccontextmanager
async def _client(client: httpx.AsyncClient | None) -> AsyncIterator[httpx.AsyncClient]:
    if client is not None:
        yield client
    else:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as owned:
            yield owned


def _read_client_secret(path: Path) -> _ClientSecret:
    document = json.loads(path.read_text())
    section = document.get("installed") or document.get("web")
    return _ClientSecret(client_id=section["client_id"], client_secret=section["client_secret"])


def _redirect_uri(config: GoogleOAuthConfig) -> str:
    return f"http://localhost:{config.listen_port}"


def _consent_url(config: GoogleOAuthConfig, client_id: str, state: str) -> str:
    query = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": _redirect_uri(config),
            "response_type": "code",
            "scope": " ".join(config.scopes),
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        }
    )
    return f"{config.auth_url}?{query}"


def _http_response(body: str) -> bytes:
    payload = body.encode()
    head = (
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/html; charset=utf-8\r\n"
        f"Content-Length: {len(payload)}\r\n"
        "Connection: close\r\n\r\n"
    )
    return head.encode() + payload


def _code_from_request_line(request_line: str, expected_state: str) -> str | None:
    parts = request_line.split(" ")
    if len(parts) < 2:
        return None
    params = urllib.parse.parse_qs(urllib.parse.urlparse(parts[1]).query)
    # A missing or mismatched state means this is not our run's redirect — treat it as no code.
    if params.get("state", [None])[0] != expected_state:
        return None
    return params.get("code", [None])[0]


async def _read_request_line(stream: SocketStream) -> str:
    buffer = b""
    while b"\r\n" not in buffer and len(buffer) < _REQUEST_LINE_LIMIT:
        buffer += await stream.receive()
    return buffer.split(b"\r\n", 1)[0].decode("latin-1")


async def _capture_code(port: int, *, ceiling: float, expected_state: str) -> str:
    holder: dict[str, str] = {}
    listener = await anyio.create_tcp_listener(local_host="127.0.0.1", local_port=port)
    async with listener:
        with anyio.move_on_after(ceiling):
            async with anyio.create_task_group() as task_group:

                async def handle(stream: SocketStream) -> None:
                    async with stream:
                        try:
                            request_line = await _read_request_line(stream)
                        except (anyio.EndOfStream, anyio.BrokenResourceError, OSError):
                            return
                        code = _code_from_request_line(request_line, expected_state)
                        try:
                            await stream.send(_http_response(_SUCCESS_HTML if code else _WAITING_HTML))
                        except (anyio.BrokenResourceError, OSError):
                            pass
                    if code is not None and "code" not in holder:
                        holder["code"] = code
                        task_group.cancel_scope.cancel()

                task_group.start_soon(listener.serve, handle)
    code = holder.get("code")
    if code is None:
        raise ConsentTimeout(port, ceiling)
    return code


async def _vault_login(client: httpx.AsyncClient, config: GoogleOAuthConfig, password: str) -> str:
    response = await client.post(
        f"{config.vault_url}/v1/auth/login",
        json={"email": config.owner, "password": password, "device_label": DEVICE_LABEL},
    )
    if not response.is_success:
        raise VaultAuthError(config.vault_url, response.status_code)
    return response.json()["token"]


async def _exchange_code(
    client: httpx.AsyncClient, config: GoogleOAuthConfig, secret: _ClientSecret, code: str
) -> _Tokens:
    response = await client.post(
        config.token_url,
        data={
            "code": code,
            "client_id": secret.client_id,
            "client_secret": secret.client_secret,
            "redirect_uri": _redirect_uri(config),
            "grant_type": "authorization_code",
        },
    )
    if not response.is_success:
        raise CodeExchangeError(response.status_code, _error_reason(response))
    tokens = response.json()
    refresh = tokens.get("refresh_token")
    if not refresh:
        raise MissingRefreshTokenError()
    return _Tokens(access=tokens["access_token"], refresh=refresh)


def _error_reason(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except json.JSONDecodeError:
        return ""
    return str(payload.get("error", "")) if isinstance(payload, dict) else ""


async def _upload_tokens(
    client: httpx.AsyncClient, config: GoogleOAuthConfig, token: str, secret: _ClientSecret, tokens: _Tokens
) -> None:
    response = await client.post(
        f"{config.vault_url}/v1/credentials/oauth/tokens",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "vault": config.vault_name,
            "key": config.key,
            "access_token": tokens.access,
            "refresh_token": tokens.refresh,
            "token_url": config.token_url,
            "client_id": secret.client_id,
            "client_secret": secret.client_secret,
            "token_auth_method": "client_secret_post",
        },
    )
    if not response.is_success:
        raise VaultUploadError(config.vault_url, response.status_code)


async def _oauth_status(client: httpx.AsyncClient, config: GoogleOAuthConfig, token: str) -> OAuthResult:
    response = await client.get(
        f"{config.vault_url}/v1/credentials/oauth/status",
        params={"vault": config.vault_name, "key": config.key},
        headers={"Authorization": f"Bearer {token}"},
    )
    if not response.is_success:
        raise VaultStatusError(config.vault_url, response.status_code)
    connected = bool(response.json().get("connected"))
    return OAuthResult(connected=connected, detail="connected" if connected else "not connected")


async def status(config: GoogleOAuthConfig, *, client: httpx.AsyncClient | None = None) -> OAuthResult:
    password = keychain.read(config.master_service)
    async with _client(client) as active:
        token = await _vault_login(active, config, password)
        return await _oauth_status(active, config, token)


async def connect(
    config: GoogleOAuthConfig,
    *,
    open_browser: Callable[[str], None],
    on_status: Callable[[str], None],
    client: httpx.AsyncClient | None = None,
    ceiling: float = DEFAULT_CONSENT_CEILING,
) -> OAuthResult:
    password = keychain.read(config.master_service)
    secret = _read_client_secret(config.client_secret_path)
    state = secrets.token_urlsafe(32)
    async with _client(client) as active:
        token = await _vault_login(active, config, password)
        consent_url = _consent_url(config, secret.client_id, state)
        on_status(consent_url)
        try:
            # Best-effort auto-open (mirrors the retired script's `open "$url" || true`): the URL is
            # already echoed, so the user opens it by hand if the launch fails — never abort the gate.
            open_browser(consent_url)
        except Exception:
            pass
        code = await _capture_code(config.listen_port, ceiling=ceiling, expected_state=state)
        tokens = await _exchange_code(active, config, secret, code)
        await _upload_tokens(active, config, token, secret, tokens)
        return await _oauth_status(active, config, token)
