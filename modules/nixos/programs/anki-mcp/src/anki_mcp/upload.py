"""Device image upload through an MCP Apps widget (#1414).

The widget (ui://anki/upload-image) runs in the host's sandboxed iframe. Right before an upload it gets a
one-time ticket from the app-only tool anki_upload_ticket over the authenticated MCP connection, then posts
the file to POST /upload?ticket=... . UploadGate serves that path outside OAuth: it consumes the ticket
before reading the body, checks the format by content, names the file like Anki's editor names pasted
images (paste-<SHA-1>.<ext>) and stores it through OperationService, the journaled path of anki_store_media.
Nothing here fetches a URL (#1306): the user's browser sends the bytes.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import re
import secrets
import struct
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

from starlette.datastructures import UploadFile
from starlette.requests import Request

from .helper import HelperBusy, HelperRejected, HelperUnavailable

log = logging.getLogger("anki_mcp.upload")

UPLOAD_PATH = "/upload"
WIDGET_URI = "ui://anki/upload-image"
WIDGET_MIME = "text/html;profile=mcp-app"
TICKET_TOOL = "anki_upload_ticket"
FORMATS = ("jpeg", "png", "gif", "webp")
EXTENSIONS = {"jpeg": "jpg", "png": "png", "gif": "gif", "webp": "webp"}
RESIZE_LONG_EDGE = 3072  # the widget re-encodes only files over the media limit, to this long edge
JPEG_QUALITY = 0.9
MAX_OUTSTANDING_TICKETS = 256
HEIF_HINT = "HEIC/HEIF is not supported; convert the image to JPEG"
_TEMPLATE = Path(__file__).with_name("upload_widget.html")
_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
# No cookies or credentials: the ticket is the only authority, so any widget origin may send it.
_CORS = [(b"access-control-allow-origin", b"*"), (b"access-control-allow-methods", b"POST, OPTIONS"),
         (b"access-control-allow-headers", b"Content-Type"), (b"access-control-max-age", b"600")]
_TICKET_QUERY = re.compile(r"([?&]ticket=)[^&\s]*")


class UnsupportedImage(ValueError):
    def __init__(self, hint: str | None = None) -> None:
        super().__init__("unsupported-image-format")
        self.hint = hint


def _jpeg_size(data: bytes) -> tuple[int | None, int | None]:
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker in (0xD9, 0xDA):
            break
        if marker in _SOF and i + 9 <= len(data):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    return None, None


def _webp_size(data: bytes) -> tuple[int | None, int | None]:
    chunk = data[12:16]
    if chunk == b"VP8X" and len(data) >= 30:
        return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
    if chunk == b"VP8 " and len(data) >= 30:
        width, height = struct.unpack("<HH", data[26:30])
        return width & 0x3FFF, height & 0x3FFF
    if chunk == b"VP8L" and len(data) >= 25:
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return None, None


def image_info(data: bytes) -> dict[str, Any]:
    """Format and pixel size from the file content, never from a client-supplied name or type."""
    if data.startswith(b"\xff\xd8\xff"):
        width, height = _jpeg_size(data)
        return {"format": "jpeg", "width": width, "height": height}
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24 and data[12:16] == b"IHDR":
        width, height = struct.unpack(">II", data[16:24])
        return {"format": "png", "width": width, "height": height}
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        width, height = struct.unpack("<HH", data[6:10])
        return {"format": "gif", "width": width, "height": height}
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        width, height = _webp_size(data)
        return {"format": "webp", "width": width, "height": height}
    if data[4:8] == b"ftyp":  # ISO BMFF: HEIC/HEIF/AVIF, which desktop Anki may not render
        raise UnsupportedImage(HEIF_HINT)
    raise UnsupportedImage()


def media_filename(data: bytes, image_format: str) -> str:
    """Anki's editor names pasted images paste-<SHA-1 of the bytes>.<ext> (aqt editor _pasted_image_filename)."""
    return f"paste-{hashlib.sha1(data, usedforsecurity=False).hexdigest()}.{EXTENSIONS[image_format]}"


def origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


def widget_html(upload_url: str, max_bytes: int) -> str:
    config = json.dumps({"uploadUrl": upload_url, "maxBytes": max_bytes, "resizeLongEdge": RESIZE_LONG_EDGE,
                         "jpegQuality": JPEG_QUALITY, "ticketTool": TICKET_TOOL})
    # Keep the JSON inert inside <script>: no "</script>" or "<!--" can end or change the block.
    config = config.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return _TEMPLATE.read_text(encoding="utf-8").replace("__UPLOAD_CONFIG__", config)


class UploadTickets:
    """One-time upload tickets kept in memory: valid for ttl seconds and consumed on first presentation."""

    def __init__(self, ttl: float, *, clock: Callable[[], float] = time.monotonic,
                 limit: int = MAX_OUTSTANDING_TICKETS) -> None:
        self.ttl = ttl
        self._clock, self._limit = clock, limit
        self._items: OrderedDict[str, float] = OrderedDict()

    def issue(self) -> str:
        now = self._clock()
        for key in [key for key, expires in self._items.items() if expires <= now]:
            del self._items[key]
        while len(self._items) >= self._limit:
            self._items.popitem(last=False)
        ticket = secrets.token_urlsafe(32)
        self._items[ticket] = now + self.ttl
        return ticket

    def consume(self, ticket: str) -> bool:
        expires = self._items.pop(ticket, None) if isinstance(ticket, str) and ticket else None
        return expires is not None and expires > self._clock()


class RedactTickets(logging.Filter):
    """uvicorn's access log records the request path with its query string; keep ticket values out of it."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(_TICKET_QUERY.sub(r"\1<redacted>", arg) if isinstance(arg, str) else arg
                                for arg in record.args)
        return True


class _Disconnected(Exception):
    pass


def _receipt(operation: dict[str, Any]) -> dict[str, Any]:
    summary = operation.get("summary") if isinstance(operation.get("summary"), dict) else {}
    out = {
        "state": operation.get("state"), "request_id": operation.get("request_id"),
        "operation_id": operation.get("operation_id"), "unchanged": summary.get("unchanged"),
        "sync": (operation.get("sync") or {}).get("state"),
        "notification": (operation.get("notification") or {}).get("state"),
    }
    for key in ("next_step", "error", "delivery_unconfirmed"):
        if operation.get(key):
            out[key] = operation[key]
    return out


class UploadGate:
    """Pure ASGI middleware for POST /upload on the public app, outside RequestGuard and OAuth.

    The ticket is checked before any body byte is read, so unauthenticated uploads cost nothing;
    an accepted upload gets its own longer read deadline for slow phone uploads.
    """

    def __init__(self, app: Any, *, tickets: UploadTickets, operations: Any, max_body_bytes: int,
                 media_max_bytes: int, read_timeout: float) -> None:
        self._app, self._tickets, self._operations = app, tickets, operations
        self._max_body, self._media_max, self._read_timeout = max_body_bytes, media_max_bytes, read_timeout

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope.get("path") != UPLOAD_PATH:
            await self._app(scope, receive, send)
            return
        method = scope.get("method")
        if method == "OPTIONS":
            await _respond(send, 204, None)
            return
        if method != "POST":
            await _respond(send, 405, {"error": "method-not-allowed"})
            return
        ticket = (parse_qs(scope.get("query_string", b"").decode("latin-1")).get("ticket") or [""])[0]
        if not self._tickets.consume(ticket):
            await _respond(send, 401, {"error": "invalid-or-expired-ticket"})
            return
        length = next((v for k, v in scope.get("headers", []) if k.lower() == b"content-length"), b"").decode("latin-1")
        if length.isdigit() and int(length) > self._max_body:
            await _respond(send, 413, {"error": "request-body-too-large"})
            return
        try:
            body = await asyncio.wait_for(self._read(receive), self._read_timeout)
        except asyncio.TimeoutError:
            await _respond(send, 408, {"error": "upload-read-timeout"})
            return
        except _Disconnected:
            return
        if body is None:
            await _respond(send, 413, {"error": "request-body-too-large"})
            return
        status, payload = await self._store(scope, body, ticket)
        log.info("upload %s state=%s format=%s bytes=%s", status, payload.get("state"), payload.get("format"),
                 payload.get("bytes"))
        await _respond(send, status, payload)

    async def _read(self, receive: Any) -> bytes | None:
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] != "http.request":
                raise _Disconnected
            body += message.get("body", b"")
            if len(body) > self._max_body:
                return None
            if not message.get("more_body", False):
                return bytes(body)

    async def _file(self, scope: dict[str, Any], body: bytes) -> bytes | None:
        replay = [{"type": "http.request", "body": body, "more_body": False}]

        async def replay_receive() -> dict[str, Any]:
            return replay.pop(0) if replay else {"type": "http.disconnect"}

        form = await Request(scope, replay_receive).form(max_files=1, max_fields=8)
        try:
            files = [value for value in form.getlist("file") if isinstance(value, UploadFile)]
            if len(files) != 1:
                return None
            return await files[0].read()
        finally:
            await form.close()

    async def _store(self, scope: dict[str, Any], body: bytes, ticket: str) -> tuple[int, dict[str, Any]]:
        try:
            data = await self._file(scope, body)
        except Exception:  # noqa: BLE001 — any multipart parser failure is a malformed request
            data = None
        if data is None:
            return 400, {"error": "bad-form"}
        if not data or len(data) > self._media_max:
            return 413, {"error": "media-too-large"}
        try:
            info = image_info(data)
        except UnsupportedImage as err:
            return 415, {"error": str(err), **({"hint": err.hint} if err.hint else {})}
        filename = media_filename(data, info["format"])
        request_id = "upload-" + hashlib.sha256(ticket.encode()).hexdigest()[:32]
        params = {"filename": filename, "data": base64.b64encode(data).decode("ascii")}
        try:
            operation = await self._operations.run("store_media", params, request_id=request_id)
        except HelperRejected as err:
            return 422, {"error": str(err)}
        except HelperBusy:
            return 503, {"error": "helper-busy"}
        except HelperUnavailable:
            return 503, {"error": "helper-unavailable"}
        except Exception:  # noqa: BLE001 — the write may have happened; never invite a blind retry
            log.exception("upload store failed")
            return 500, {"error": "upload-failed", "filename": filename,
                         "next_step": "The image may have been stored. Check anki_recent_operations before retrying."}
        return 200, {**_receipt(operation), "filename": filename, "bytes": len(data), **info}


async def _respond(send: Any, status: int, payload: dict[str, Any] | None) -> None:
    body = b"" if payload is None else json.dumps(payload).encode()
    headers = [*_CORS, (b"cache-control", b"no-store"), (b"content-length", str(len(body)).encode())]
    if payload is not None:
        headers.append((b"content-type", b"application/json"))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})
