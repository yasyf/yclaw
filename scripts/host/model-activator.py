#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["starlette>=0.40", "uvicorn>=0.30", "httpx>=0.27"]
# ///
"""Probe-safe idle-unload proxy for rapid-mlx.

Binds HOST_IP:PORT (the tailnet-facing address) and lazily manages a rapid-mlx
child on 127.0.0.1:CHILD_PORT. Probes (/health, /v1/models) are answered
locally while the child is down so they never wake the model; the explicit
wake routes spawn the child under a single-flight lock, then reverse-proxy
with unbuffered streaming. An idle reaper SIGTERMs the child after
IDLE_SECONDS with zero in-flight requests — never SIGKILL first: graceful
shutdown runs rapid-mlx's prefix-cache save and avoids a known 20GB
wired-Metal teardown pathology.
"""

import asyncio
import contextlib
import logging
import os
import shlex
import sys
import time
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

CHILD_HOST = "127.0.0.1"
WAKE_PATHS = ("/v1/chat/completions", "/v1/completions", "/v1/messages")
REAPER_INTERVAL_SECONDS = 30.0
CHILD_STOP_TIMEOUT_SECONDS = 120.0
HEALTH_POLL_INTERVAL_SECONDS = 1.0
HOP_HEADERS = frozenset({"host", "connection", "keep-alive", "transfer-encoding"})

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


@dataclass(frozen=True, slots=True)
class Config:
    host_ip: str
    port: int
    child_port: int
    rapid_mlx_cmd: str
    idle_seconds: float
    child_start_timeout: float

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
        )


class Activator:
    def __init__(self, config: Config, upstream: httpx.AsyncClient) -> None:
        self.config = config
        self.upstream = upstream
        self.process: asyncio.subprocess.Process | None = None
        self.spawn_lock = asyncio.Lock()
        self.inflight = 0
        self.last_done = time.monotonic()
        self.app = Starlette(
            routes=[
                Route("/health", self.probe, methods=["GET"]),
                Route("/v1/models", self.probe, methods=["GET"]),
                *(Route(path, self.wake, methods=["POST"]) for path in WAKE_PATHS),
                Route("/v1/{rest:path}", self.passthrough, methods=["GET", "POST", "PUT", "DELETE", "PATCH"]),
            ],
            lifespan=self.lifespan,
        )

    @contextlib.asynccontextmanager
    async def lifespan(self, app: Starlette) -> AsyncIterator[None]:
        log.info(
            "activator up on %s:%d (child %s:%d, idle %.0fs)",
            self.config.host_ip,
            self.config.port,
            CHILD_HOST,
            self.config.child_port,
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

    async def passthrough(self, request: Request) -> Response:
        if not self.child_up():
            return JSONResponse({"error": "model idle; POST to a wake route to load it"}, status_code=503)
        return await self._proxy(request)

    async def spawn_child(self) -> asyncio.subprocess.Process:
        return await asyncio.create_subprocess_exec(*shlex.split(self.config.rapid_mlx_cmd))

    async def ensure_running(self) -> None:
        async with self.spawn_lock:
            await self._reap_crashed()
            if self.child_up():
                return
            started = time.monotonic()
            self.process = await self.spawn_child()
            log.info("spawned child pid=%s: %s", self.process.pid, self.config.rapid_mlx_cmd)
            try:
                await self._wait_healthy()
            except ChildStartError:
                await self._stop_child_locked()
                raise
            log.info("child healthy after %.1fs", time.monotonic() - started)

    async def _wait_healthy(self) -> None:
        deadline = time.monotonic() + self.config.child_start_timeout
        while time.monotonic() < deadline:
            if self.process.returncode is not None:
                raise ChildExitedDuringStartup(self.process.returncode)
            try:
                response = await self.upstream.get("/v1/models")
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

    async def _proxy(self, request: Request, on_done: Callable[[], None] | None = None) -> Response:
        url = httpx.URL(path=request.url.path, query=request.url.query.encode())
        upstream_request = self.upstream.build_request(
            request.method,
            url,
            headers=[(k, v) for k, v in request.headers.raw if k.decode().lower() not in HOP_HEADERS],
            content=request.stream(),
        )
        upstream_response = await self.upstream.send(upstream_request, stream=True)
        headers = {k: v for k, v in upstream_response.headers.items() if k.lower() not in HOP_HEADERS}
        return StreamingResponse(
            self._relay(upstream_response, on_done),
            status_code=upstream_response.status_code,
            headers=headers,
        )

    async def _relay(
        self, upstream_response: httpx.Response, on_done: Callable[[], None] | None
    ) -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream_response.aiter_raw():
                yield chunk
        finally:
            await upstream_response.aclose()
            if on_done is not None:
                on_done()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    config = Config.from_env()
    upstream = httpx.AsyncClient(
        base_url=f"http://{CHILD_HOST}:{config.child_port}",
        timeout=httpx.Timeout(connect=5.0, read=None, write=None, pool=None),
    )
    activator = Activator(config, upstream)
    uvicorn.run(activator.app, host=config.host_ip, port=config.port, log_level="info")


if __name__ == "__main__":
    main()
