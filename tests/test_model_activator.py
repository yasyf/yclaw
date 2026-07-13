"""Tests for scripts/host/model-activator.py (loaded via importlib — the path has a dash).

The child-spawn subprocess seam and the upstream httpx transport are mocked; the
routing allowlist, single-flight, admission bounds, streaming, and reaper logic
under test stay real.
"""

import asyncio
import importlib.util
import json
import socket
import time
from dataclasses import dataclass, replace
from pathlib import Path

import httpx
import pytest

MODULE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "host" / "model-activator.py"

spec = importlib.util.spec_from_file_location("model_activator", MODULE_PATH)
ma = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ma)

pytestmark = pytest.mark.anyio

CONFIG = ma.Config(
    host_ip="100.64.0.1",
    port=8000,
    # child_port=0: the lifespan test binds a real loopback listener; an ephemeral port never
    # collides with a live activator's 18000 on the same machine.
    child_port=0,
    rapid_mlx_cmd="rapid-mlx serve test-model --listen-fd {LISTEN_FD}",
    idle_seconds=1800.0,
    child_start_timeout=5.0,
    wake_concurrency=8,
    upstream_timeout=600.0,
    spawn_cooldown=30.0,
)

CHAT_COMPLETION = {"id": "chatcmpl-1", "object": "chat.completion", "choices": []}


class FakeProcess:
    def __init__(self) -> None:
        self.pid = 4242
        self.returncode: int | None = None
        self.signals: list[str] = []
        self._exited = asyncio.Event()

    def terminate(self) -> None:
        self.signals.append("SIGTERM")
        self.returncode = -15
        self._exited.set()

    def kill(self) -> None:
        self.signals.append("SIGKILL")
        self.returncode = -9
        self._exited.set()

    async def wait(self) -> int:
        await self._exited.wait()
        return self.returncode


@dataclass(frozen=True, slots=True)
class Harness:
    activator: object
    spawned: list[FakeProcess]
    upstream_calls: list[str]


def stream_json(status_code: int, payload: dict) -> httpx.Response:
    # A Response built with json=/content= bytes is born stream-consumed, so the
    # activator's aiter_raw passthrough would refuse it; a real socket streams.
    async def body():
        yield json.dumps(payload).encode()

    return httpx.Response(status_code, content=body(), headers={"content-type": "application/json"})


def default_upstream(calls: list[str]):
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/v1/models":
            return stream_json(200, {"object": "list", "data": [{"id": "test-model"}]})
        if request.url.path in ma.WAKE_PATHS:
            return stream_json(200, CHAT_COMPLETION)
        return stream_json(404, {"error": "no such route"})

    return handler


def make_harness(monkeypatch, handler=None, config=CONFIG) -> Harness:
    upstream_calls: list[str] = []
    upstream = httpx.AsyncClient(
        transport=httpx.MockTransport(handler or default_upstream(upstream_calls)),
        base_url="http://127.0.0.1:18000",
    )
    activator = ma.Activator(config, upstream)
    spawned: list[FakeProcess] = []

    async def fake_spawn() -> FakeProcess:
        await asyncio.sleep(0.01)  # let concurrent wakes pile up on the single-flight lock
        process = FakeProcess()
        spawned.append(process)
        return process

    monkeypatch.setattr(activator, "spawn_child", fake_spawn)
    return Harness(activator=activator, spawned=spawned, upstream_calls=upstream_calls)


@pytest.fixture
def harness(monkeypatch) -> Harness:
    return make_harness(monkeypatch)


def app_client(activator) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=activator.app), base_url="http://activator")


async def test_models_probe_with_child_down_answers_locally(harness):
    async with app_client(harness.activator) as client:
        response = await client.get("/v1/models")
    assert response.status_code == 200
    assert response.json() == ma.STATIC_MODELS
    assert harness.spawned == []
    assert harness.upstream_calls == []


async def test_health_probe_with_child_down_answers_locally(harness):
    async with app_client(harness.activator) as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "model": "idle"}
    assert harness.spawned == []
    assert harness.upstream_calls == []


async def test_concurrent_wakes_spawn_exactly_once(harness):
    async with app_client(harness.activator) as client:
        responses = await asyncio.gather(
            *(client.post("/v1/chat/completions", json={"messages": []}) for _ in range(5))
        )
    assert [r.status_code for r in responses] == [200] * 5
    assert [r.json() for r in responses] == [CHAT_COMPLETION] * 5
    assert len(harness.spawned) == 1
    assert harness.activator.inflight == 0
    assert harness.activator.child_up()


async def test_inflight_request_blocks_reaper(harness):
    process = FakeProcess()
    harness.activator.process = process
    harness.activator.inflight = 1
    harness.activator.last_done = time.monotonic() - CONFIG.idle_seconds * 2
    await harness.activator.reap_if_idle()
    assert process.signals == []
    assert harness.activator.process is process


async def test_idle_reaper_sends_sigterm_not_sigkill(harness):
    process = FakeProcess()
    harness.activator.process = process
    harness.activator.inflight = 0
    harness.activator.last_done = time.monotonic() - CONFIG.idle_seconds - 1
    await harness.activator.reap_if_idle()
    assert process.signals == ["SIGTERM"]
    assert harness.activator.process is None


async def test_reaper_skips_before_idle_deadline(harness):
    process = FakeProcess()
    harness.activator.process = process
    harness.activator.inflight = 0
    harness.activator.last_done = time.monotonic()
    await harness.activator.reap_if_idle()
    assert process.signals == []
    assert harness.activator.process is process


async def test_sse_streams_through_before_upstream_eof(monkeypatch):
    gate = asyncio.Event()

    async def sse_body():
        yield b"data: one\n\n"
        await gate.wait()
        yield b"data: two\n\n"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": []})
        return httpx.Response(200, content=sse_body(), headers={"content-type": "text/event-stream"})

    harness = make_harness(monkeypatch, handler=handler)

    received: list[dict] = []
    got_first = asyncio.Event()

    async def send(message) -> None:
        received.append(message)
        if message["type"] == "http.response.body" and b"data: one" in message.get("body", b""):
            got_first.set()

    body_sent = False

    async def receive() -> dict:
        nonlocal body_sent
        if body_sent:
            await asyncio.Event().wait()  # no disconnect while the stream is live
        body_sent = True
        return {"type": "http.request", "body": b"{}", "more_body": False}

    scope = {
        "type": "http",
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/v1/chat/completions",
        "raw_path": b"/v1/chat/completions",
        "root_path": "",
        "query_string": b"",
        "headers": [(b"host", b"activator"), (b"content-type", b"application/json")],
        "server": ("activator", 8000),
        "client": ("127.0.0.1", 55555),
    }
    task = asyncio.create_task(harness.activator.app(scope, receive, send))
    await asyncio.wait_for(got_first.wait(), timeout=5)
    assert not task.done()  # the first chunk arrived while upstream is still mid-stream
    gate.set()
    await asyncio.wait_for(task, timeout=5)
    body = b"".join(m.get("body", b"") for m in received if m["type"] == "http.response.body")
    assert body == b"data: one\n\ndata: two\n\n"
    assert harness.activator.inflight == 0


async def test_shutdown_sigterms_child_and_closes_listener(harness):
    process = FakeProcess()
    async with harness.activator.lifespan(harness.activator.app):
        assert harness.activator.listen_sock is not None
        harness.activator.process = process
    assert process.signals == ["SIGTERM"]
    assert harness.activator.process is None
    assert harness.activator.listen_sock is None


async def test_unlisted_route_is_404_never_proxied(harness):
    harness.activator.process = FakeProcess()  # child UP: management routes still must not proxy
    async with app_client(harness.activator) as client:
        responses = [
            await client.post("/v1/cache/clear"),
            await client.get("/metrics"),
            await client.get("/docs"),
            await client.post("/v1/embeddings", json={"input": "hi"}),
        ]
    assert [r.status_code for r in responses] == [404] * 4
    assert harness.upstream_calls == []
    assert harness.spawned == []


async def test_traversal_shaped_path_is_404_never_proxied(harness):
    harness.activator.process = FakeProcess()
    async with app_client(harness.activator) as client:
        # httpx keeps %2e%2e unnormalized in raw_path, so the app sees /v1/../metrics —
        # the same shape uvicorn would present.
        response = await client.get("/v1/%2e%2e/metrics")
    assert response.status_code == 404
    assert harness.upstream_calls == []


async def test_wake_concurrency_is_bounded(monkeypatch):
    active = 0
    peak = 0
    gate = asyncio.Event()

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal active, peak
        if request.url.path == "/v1/models":
            return stream_json(200, {"object": "list", "data": []})
        active += 1
        peak = max(peak, active)
        await gate.wait()
        active -= 1
        return stream_json(200, CHAT_COMPLETION)

    harness = make_harness(monkeypatch, handler=handler, config=replace(CONFIG, wake_concurrency=2))
    async with app_client(harness.activator) as client:
        posts = [
            asyncio.create_task(client.post("/v1/chat/completions", json={"messages": []})) for _ in range(5)
        ]
        async with asyncio.timeout(5):
            while active < 2:
                await asyncio.sleep(0.01)
        await asyncio.sleep(0.05)  # give any over-admitted request time to reach the handler
        assert peak == 2
        gate.set()
        responses = await asyncio.gather(*posts)
    assert [r.status_code for r in responses] == [200] * 5
    assert peak == 2
    assert harness.activator.inflight == 0


async def test_failed_spawn_cools_down_then_readmits(monkeypatch, harness):
    async def crashing_spawn() -> FakeProcess:
        process = FakeProcess()
        process.returncode = 1
        process._exited.set()
        harness.spawned.append(process)
        return process

    monkeypatch.setattr(harness.activator, "spawn_child", crashing_spawn)
    async with app_client(harness.activator) as client:
        first = await client.post("/v1/chat/completions", json={"messages": []})
        second = await client.post("/v1/chat/completions", json={"messages": []})
        assert first.status_code == 503
        assert "exited rc=1" in first.json()["error"]
        assert second.status_code == 503
        assert "cooling down" in second.json()["error"]
        assert len(harness.spawned) == 1  # the cooldown blocked the respawn
        harness.activator.cooldown_until = 0.0  # cooldown expiry re-admits spawn attempts
        third = await client.post("/v1/chat/completions", json={"messages": []})
        assert third.status_code == 503
        assert len(harness.spawned) == 2
    assert harness.activator.inflight == 0


async def test_spawn_child_hands_pre_bound_listener_fd(monkeypatch):
    upstream = httpx.AsyncClient(
        transport=httpx.MockTransport(default_upstream([])), base_url="http://127.0.0.1:18000"
    )
    activator = ma.Activator(CONFIG, upstream)
    activator.listen_sock = ma.bind_child_socket(0)
    fd = activator.listen_sock.fileno()
    captured: dict = {}

    async def fake_exec(*argv, **kwargs):
        captured["argv"] = argv
        captured["kwargs"] = kwargs
        return FakeProcess()

    monkeypatch.setattr(ma.asyncio, "create_subprocess_exec", fake_exec)
    process = await activator.spawn_child()
    assert isinstance(process, FakeProcess)
    assert captured["argv"] == ("rapid-mlx", "serve", "test-model", "--listen-fd", str(fd))
    assert captured["kwargs"] == {"pass_fds": (fd,)}
    activator.listen_sock.close()
    await upstream.aclose()


async def test_bind_child_socket_is_listening_loopback():
    sock = ma.bind_child_socket(0)
    try:
        host, port = sock.getsockname()
        assert host == "127.0.0.1"
        assert port > 0
        assert sock.type == socket.SOCK_STREAM
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            pass  # connects land in the backlog even with no child accepting
    finally:
        sock.close()


async def test_upstream_client_ignores_proxy_env():
    upstream = ma.build_upstream(CONFIG)
    try:
        assert upstream.trust_env is False
    finally:
        await upstream.aclose()


def test_strip_hop_headers_drops_standard_and_connection_nominated():
    headers = [
        ("Host", "activator"),
        ("Connection", "keep-alive, X-Session-Token"),
        ("Keep-Alive", "timeout=5"),
        ("Proxy-Authenticate", "Basic"),
        ("Proxy-Authorization", "Basic xxx"),
        ("TE", "trailers"),
        ("Trailer", "Expires"),
        ("Transfer-Encoding", "chunked"),
        ("Upgrade", "h2c"),
        ("X-Session-Token", "nominated-away"),
        ("Content-Type", "application/json"),
    ]
    assert ma.strip_hop_headers(headers) == [("Content-Type", "application/json")]


async def test_proxy_strips_hop_headers_both_directions(monkeypatch):
    seen: dict = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return stream_json(200, {"object": "list", "data": []})
        seen["headers"] = request.headers

        async def body():
            yield json.dumps(CHAT_COMPLETION).encode()

        return httpx.Response(
            200,
            content=body(),
            headers=[
                ("content-type", "application/json"),
                ("connection", "x-upstream-hop"),
                ("x-upstream-hop", "leak"),
                ("keep-alive", "timeout=5"),
                ("x-stay", "ok"),
            ],
        )

    harness = make_harness(monkeypatch, handler=handler)
    async with app_client(harness.activator) as client:
        response = await client.post(
            "/v1/chat/completions",
            json={"messages": []},
            headers={
                "connection": "x-client-hop",
                "x-client-hop": "leak",
                "te": "trailers",
                "x-forward-me": "yes",
            },
        )
    assert response.status_code == 200
    assert seen["headers"].get("x-forward-me") == "yes"
    for name in ("x-client-hop", "te"):
        assert name not in seen["headers"]
    # httpx adds its own per-hop connection header; the client's value must not leak through.
    assert seen["headers"].get("connection") != "x-client-hop"
    assert response.headers.get("x-stay") == "ok"
    for name in ("connection", "x-upstream-hop", "keep-alive"):
        assert name not in response.headers
