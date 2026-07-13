#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["starlette>=0.40", "uvicorn>=0.30", "httpx>=0.27"]
# ///
"""Probe-safe idle-unload proxy for rapid-mlx.

Binds HOST_IP:PORT (the tailnet-facing address) and lazily manages a rapid-mlx
child on a listener socket the activator itself binds to 127.0.0.1:CHILD_PORT
and hands down at spawn (rapid-mlx --listen-fd), so no other local process can
squat the child address between restarts. Only an explicit route allowlist is
served: probes (/health, /v1/models) are answered locally while the child is
down so they never wake the model; the wake routes spawn the child under a
single-flight lock, then reverse-proxy with unbuffered streaming, bounded by
WAKE_CONCURRENCY and UPSTREAM_TIMEOUT. Every other path is a local 404 — never
proxied. A failed spawn refuses wakes for SPAWN_COOLDOWN seconds instead of
respawn-thrashing. An idle reaper SIGTERMs the child after IDLE_SECONDS with
zero in-flight requests — never SIGKILL first: graceful shutdown runs
rapid-mlx's prefix-cache save and avoids a known 20GB wired-Metal teardown
pathology.
"""

import asyncio
import contextlib
import logging
import os
import shlex
import socket
import sys
import time
from collections.abc import AsyncIterator, Callable, Iterable
from dataclasses import dataclass

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

CHILD_HOST = "127.0.0.1"
CHILD_LISTEN_BACKLOG = 128
WAKE_PATHS = ("/v1/chat/completions", "/v1/completions", "/v1/messages")
REAPER_INTERVAL_SECONDS = 30.0
CHILD_STOP_TIMEOUT_SECONDS = 120.0
HEALTH_POLL_INTERVAL_SECONDS = 1.0
HEALTH_ATTEMPT_TIMEOUT_SECONDS = 2.0
HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
    }
)

# Captured live from rapid-mlx 0.10.9 on metal:8000 (2026-07-13) so probes see
# the real response shape while the child is down.
STATIC_MODELS = {
    "object": "list",
    "data": [
        {
            "id": "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit",
            "object": "model",
            "created": 1783929192,
            "owned_by": "rapid-mlx",
            "recommended_sampling": None,
            "is_hybrid": True,
            "is_moe": True,
            "tool_call_parser": "qwen3_coder_xml",
            "reasoning_parser": "qwen3",
            "modality": "text",
            "context_window": 262144,
            "capabilities": ["text", "tools"],
            "audio_lanes": None,
        }
    ],
}

log = logging.getLogger("model-activator")


class ChildStartError(Exception):
    """The rapid-mlx child failed to become healthy after a spawn."""


class ChildStartTimeout(ChildStartError):
    def __init__(self, timeout: float) -> None:
        super().__init__(f"child not healthy after {timeout:.0f}s")
        self.timeout = timeout


class ChildExitedDuringStartup(ChildStartError):
    def __init__(self, returncode: int) -> None:
        super().__init__(f"child exited rc={returncode} during startup")
        self.returncode = returncode


class ChildStartCooldown(ChildStartError):
    def __init__(self, remaining: float) -> None:
        super().__init__(f"spawn cooling down for another {remaining:.0f}s after a failed start")
        self.remaining = remaining


def strip_hop_headers(headers: Iterable[tuple[str, str]]) -> list[tuple[str, str]]:
    pairs = list(headers)
    drop = set(HOP_HEADERS)
    for name, value in pairs:
        if name.lower() == "connection":
            drop.update(token.strip().lower() for token in value.split(",") if token.strip())
    return [(name, value) for name, value in pairs if name.lower() not in drop]


def bind_child_socket(port: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((CHILD_HOST, port))
    sock.listen(CHILD_LISTEN_BACKLOG)
    return sock


@dataclass(frozen=True, slots=True)
class Config:
    host_ip: str
    port: int
    child_port: int
    rapid_mlx_cmd: str
    idle_seconds: float
    child_start_timeout: float
    wake_concurrency: int
    upstream_timeout: float
    spawn_cooldown: float

    @classmethod
    def from_env(cls) -> "Config":
        env = os.environ
        return cls(
            host_ip=env["HOST_IP"],
            port=int(env["PORT"]),
            child_port=int(env.get("CHILD_PORT", "18000")),
            rapid_mlx_cmd=env["RAPID_MLX_CMD"],
            idle_seconds=float(env.get("IDLE_SECONDS", "1800")),
            child_start_timeout=float(env.get("CHILD_START_TIMEOUT", "150")),
            wake_concurrency=int(env.get("WAKE_CONCURRENCY", "8")),
            upstream_timeout=float(env.get("UPSTREAM_TIMEOUT", "600")),
            spawn_cooldown=float(env.get("SPAWN_COOLDOWN", "30")),
        )


class Activator:
    def __init__(self, config: Config, upstream: httpx.AsyncClient) -> None:
        self.config = config
        self.upstream = upstream
        self.process: asyncio.subprocess.Process | None = None
        self.listen_sock: socket.socket | None = None
        self.spawn_lock = asyncio.Lock()
        self.wake_slots = asyncio.Semaphore(config.wake_concurrency)
        self.inflight = 0
        self.last_done = time.monotonic()
        self.cooldown_until = 0.0
        self.app = Starlette(
            routes=[
                Route("/health", self.probe, methods=["GET"]),
                Route("/v1/models", self.probe, methods=["GET"]),
                *(Route(path, self.wake, methods=["POST"]) for path in WAKE_PATHS),
            ],
            lifespan=self.lifespan,
        )

    @contextlib.asynccontextmanager
    async def lifespan(self, app: Starlette) -> AsyncIterator[None]:
        self.listen_sock = bind_child_socket(self.config.child_port)
        log.info(
            "activator up on %s:%d (child listener %s:%d fd=%d, idle %.0fs)",
            self.config.host_ip,
            self.config.port,
            CHILD_HOST,
            self.config.child_port,
            self.listen_sock.fileno(),
            self.config.idle_seconds,
        )
        reaper = asyncio.create_task(self.reaper_loop())
        try:
            yield
        finally:
            reaper.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await reaper
            async with self.spawn_lock:
                await self._stop_child_locked()
            self.listen_sock.close()
            self.listen_sock = None
            await self.upstream.aclose()
            log.info("activator exiting")

    def child_up(self) -> bool:
        return self.process is not None and self.process.returncode is None

    async def probe(self, request: Request) -> Response:
        if self.child_up():
            return await self._proxy(request)
        if request.url.path == "/v1/models":
            return JSONResponse(STATIC_MODELS)
        return JSONResponse({"status": "ok", "model": "idle"})

    async def wake(self, request: Request) -> Response:
        await self.wake_slots.acquire()
        self.inflight += 1
        try:
            await self.ensure_running()
            return await self._proxy(request, on_done=self._request_done)
        except ChildStartError as exc:
            self._request_done()
            log.error("wake failed: %s", exc)
            return JSONResponse({"error": str(exc)}, status_code=503)
        except BaseException:
            self._request_done()
            raise

    async def spawn_child(self) -> asyncio.subprocess.Process:
        fd = self.listen_sock.fileno()
        argv = shlex.split(self.config.rapid_mlx_cmd.replace("{LISTEN_FD}", str(fd)))
        return await asyncio.create_subprocess_exec(*argv, pass_fds=(fd,))

    async def ensure_running(self) -> None:
        async with self.spawn_lock:
            await self._reap_crashed()
            if self.child_up():
                return
            cooldown_left = self.cooldown_until - time.monotonic()
            if cooldown_left > 0:
                raise ChildStartCooldown(cooldown_left)
            started = time.monotonic()
            self.process = await self.spawn_child()
            log.info("spawned child pid=%s: %s", self.process.pid, self.config.rapid_mlx_cmd)
            try:
                await self._wait_healthy()
            except ChildStartError:
                self.cooldown_until = time.monotonic() + self.config.spawn_cooldown
                await self._stop_child_locked()
                raise
            log.info("child healthy after %.1fs", time.monotonic() - started)

    async def _wait_healthy(self) -> None:
        deadline = time.monotonic() + self.config.child_start_timeout
        while time.monotonic() < deadline:
            if self.process.returncode is not None:
                raise ChildExitedDuringStartup(self.process.returncode)
            try:
                # Connects land in the activator-held listener backlog until the child accepts,
                # so each attempt needs its own read timeout — the GET only succeeds once the
                # child actually serves.
                response = await self.upstream.get("/v1/models", timeout=HEALTH_ATTEMPT_TIMEOUT_SECONDS)
            except httpx.TransportError:
                pass
            else:
                if response.status_code == 200:
                    return
            await asyncio.sleep(HEALTH_POLL_INTERVAL_SECONDS)
        raise ChildStartTimeout(self.config.child_start_timeout)

    async def reaper_loop(self) -> None:
        while True:
            await asyncio.sleep(REAPER_INTERVAL_SECONDS)
            await self.reap_if_idle()

    async def reap_if_idle(self) -> None:
        async with self.spawn_lock:
            await self._reap_crashed()
            if not self.child_up() or self.inflight > 0:
                return
            idle = time.monotonic() - self.last_done
            if idle < self.config.idle_seconds:
                return
            log.info("child idle %.0fs (limit %.0fs); unloading", idle, self.config.idle_seconds)
            await self._stop_child_locked()

    async def _reap_crashed(self) -> None:
        if self.process is not None and self.process.returncode is not None:
            returncode = await self.process.wait()
            log.warning("child pid=%s exited rc=%s; reaped", self.process.pid, returncode)
            self.process = None

    async def _stop_child_locked(self) -> None:
        if self.process is None:
            return
        process = self.process
        if process.returncode is None:
            log.info("stopping child pid=%s (SIGTERM)", process.pid)
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), CHILD_STOP_TIMEOUT_SECONDS)
        except TimeoutError:
            log.error(
                "child pid=%s ignored SIGTERM for %.0fs; SIGKILL as last resort",
                process.pid,
                CHILD_STOP_TIMEOUT_SECONDS,
            )
            process.kill()
            await process.wait()
        log.info("child pid=%s exited rc=%s", process.pid, process.returncode)
        self.process = None

    def _request_done(self) -> None:
        self.inflight -= 1
        self.last_done = time.monotonic()
        self.wake_slots.release()

    async def _proxy(self, request: Request, on_done: Callable[[], None] | None = None) -> Response:
        deadline = time.monotonic() + self.config.upstream_timeout
        url = httpx.URL(path=request.url.path, query=request.url.query.encode())
        upstream_request = self.upstream.build_request(
            request.method,
            url,
            headers=strip_hop_headers((k.decode("latin-1"), v.decode("latin-1")) for k, v in request.headers.raw),
            content=request.stream(),
        )
        try:
            upstream_response = await asyncio.wait_for(
                self.upstream.send(upstream_request, stream=True), deadline - time.monotonic()
            )
        except TimeoutError:
            log.error("upstream gave no response within %.0fs; dropped", self.config.upstream_timeout)
            if on_done is not None:
                on_done()
            return JSONResponse({"error": "upstream timeout"}, status_code=504)
        headers = dict(strip_hop_headers(upstream_response.headers.items()))
        return StreamingResponse(
            self._relay(upstream_response, on_done, deadline),
            status_code=upstream_response.status_code,
            headers=headers,
        )

    async def _relay(
        self, upstream_response: httpx.Response, on_done: Callable[[], None] | None, deadline: float
    ) -> AsyncIterator[bytes]:
        try:
            chunks = upstream_response.aiter_raw()
            while True:
                try:
                    chunk = await asyncio.wait_for(anext(chunks), deadline - time.monotonic())
                except StopAsyncIteration:
                    break
                except TimeoutError:
                    log.error("upstream stream exceeded %.0fs; truncating", self.config.upstream_timeout)
                    break
                yield chunk
        finally:
            try:
                await upstream_response.aclose()
            finally:
                if on_done is not None:
                    on_done()


def build_upstream(config: Config) -> httpx.AsyncClient:
    # trust_env=False: ambient HTTP_PROXY/ALL_PROXY must never re-route loopback prompt traffic.
    return httpx.AsyncClient(
        base_url=f"http://{CHILD_HOST}:{config.child_port}",
        timeout=httpx.Timeout(connect=5.0, read=None, write=None, pool=None),
        trust_env=False,
    )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    config = Config.from_env()
    activator = Activator(config, build_upstream(config))
    # access_log=False: probes hit every few seconds and request lines can leak prompt metadata.
    uvicorn.run(activator.app, host=config.host_ip, port=config.port, log_level="info", access_log=False)


if __name__ == "__main__":
    main()
