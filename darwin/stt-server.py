#!/usr/bin/env python3
"""OpenAI-compatible STT server for mlx-audio, used by the metal VM (:8765).

All MLX work runs in ONE dedicated thread (max_workers=1) so the GPU stream stays
valid: mlx-audio's own `mlx_audio.server` multi-threaded adapter crashes
granite-speech with "RuntimeError: There is no Stream(gpu, 1) in current thread"
(MLX streams are per-thread). The single-threaded `mlx_audio.stt.generate` code
path is correct, so this wrapper drives it directly. The model lazy-loads on the
first request and unloads after STT_IDLE_TTL seconds of inactivity to free unified
memory — both load and unload run on the same worker thread that owns the GPU
stream, mirroring omlx's idle-TTL behaviour on :8000.
"""
import concurrent.futures
import gc
import os
import tempfile
import threading
import time

import mlx.core as mx
import uvicorn
from fastapi import FastAPI, Form, UploadFile
from mlx_audio.stt.utils import load_model

MODEL_ID = os.environ.get("STT_MODEL", "ibm-granite/granite-speech-4.1-2b")
PORT = int(os.environ.get("STT_PORT", "8765"))
IDLE_TTL = int(os.environ.get("STT_IDLE_TTL", "1800"))

_pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
_model = None
_last_use = time.monotonic()


def _transcribe(path: str) -> str:
    global _model, _last_use
    if _model is None:
        _model = load_model(MODEL_ID)
    text = _model.generate(path).text
    _last_use = time.monotonic()
    return text


def _unload_if_idle() -> None:
    global _model
    if _model is not None and time.monotonic() - _last_use >= IDLE_TTL:
        _model = None
        gc.collect()
        mx.clear_cache()


def _idle_watchdog() -> None:
    interval = max(30, min(IDLE_TTL, 300))
    while True:
        time.sleep(interval)
        _pool.submit(_unload_if_idle).result()


app = FastAPI()


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "mlx-audio"}]}


@app.post("/v1/audio/transcriptions")
async def transcriptions(file: UploadFile, model: str = Form(default=MODEL_ID)):
    data = await file.read()
    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        f.write(data)
        path = f.name
    try:
        text = _pool.submit(_transcribe, path).result()
    finally:
        os.unlink(path)
    return {"text": text}


if __name__ == "__main__":
    threading.Thread(target=_idle_watchdog, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=PORT)
