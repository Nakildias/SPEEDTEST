"""Speedtest-style HTTP server: time-bounded streaming download/upload endpoints."""

from __future__ import annotations

import asyncio
import time
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response, StreamingResponse
from starlette.requests import ClientDisconnect

BASE_DIR = Path(__file__).resolve().parent
INDEX_PATH = BASE_DIR / "index.html"

# Single reused slab — avoid per-chunk allocations for throughput.
CHUNK_SIZE = 4 * 1024 * 1024
_DOWNLOAD_SLAB = bytes(CHUNK_SIZE)
STREAM_CAP_S = 12.0

app = FastAPI()
# Same as many self-hosted speedtests: allow browsers that hit the API from another origin/port.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
def index() -> FileResponse:
    return FileResponse(INDEX_PATH, media_type="text/html")


@app.get("/api/latency")
def latency() -> Response:
    return Response(content=b"ok", media_type="application/octet-stream")


@app.get("/api/client-ip")
def client_ip(request: Request) -> dict[str, str]:
    """Public IP as seen by this server (first X-Forwarded-For hop when behind a proxy)."""
    xf = request.headers.get("x-forwarded-for")
    if xf:
        ip = xf.split(",")[0].strip()
    else:
        ip = request.client.host if request.client else ""
    return {"ip": ip or "—"}


@app.get("/api/download")
async def download(request: Request) -> StreamingResponse:
    """
    Cooperate with the event loop so a tab refresh / disconnect is noticed quickly.
    A tight loop that only yields multi‑MiB slabs can otherwise keep the worker busy
    and make the whole process feel hung until sockets drain.
    """

    async def body():
        deadline = time.monotonic() + STREAM_CAP_S
        slab = _DOWNLOAD_SLAB
        while time.monotonic() < deadline:
            if await request.is_disconnected():
                break
            yield slab
            await asyncio.sleep(0)

    return StreamingResponse(
        body(),
        media_type="application/octet-stream",
    )


@app.post("/api/upload")
async def upload(request: Request) -> dict[str, int]:
    total = 0
    deadline = time.monotonic() + STREAM_CAP_S
    # Do not call request.is_disconnected() here: it shares self._receive with
    # request.stream() and can steal/corrupt body messages so uploads fail or truncate.
    try:
        async for chunk in request.stream():
            total += len(chunk)
            if time.monotonic() >= deadline:
                break
    except ClientDisconnect:
        # Tab refresh / navigation — return what we counted; no stack trace.
        pass
    return {"bytes": total}
