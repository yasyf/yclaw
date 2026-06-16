#!/usr/bin/env python3
"""OpenAI-compatible STT server for mlx-audio, used by the metal VM (:8765).

All MLX work runs in ONE dedicated thread (max_workers=1) so the GPU stream stays
valid: mlx-audio's own `mlx_audio.server` multi-threaded adapter crashes
granite-speech with "RuntimeError: There is no Stream(gpu, 1) in current thread"
(MLX streams are per-thread). The single-threaded `mlx_audio.stt.generate` code
path is correct, so this wrapper drives it directly. The model lazy-loads on the
first request.
"""
import concurrent.futures
import os
import tempfile

import uvicorn
from fastapi import FastAPI, Form, UploadFile
from mlx_audio.stt.utils import load_model

MODEL_ID = os.environ.get("STT_MODEL", "ibm-granite/granite-speech-4.1-2b")
PORT = int(os.environ.get("STT_PORT", "8765"))

_pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
_model = None


def _transcribe(path: str) -> str:
    global _model
    if _model is None:
        _model = load_model(MODEL_ID)
    return _model.generate(path).text


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
    uvicorn.run(app, host="0.0.0.0", port=PORT)
