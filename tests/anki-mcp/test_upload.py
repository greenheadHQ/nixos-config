"""Device image upload: format checks, naming, one-time tickets and the /upload gate.

The store path runs the real OperationService and helper journal against a fake Anki adapter
with sync disabled, so no network, host service or systemctl is involved.
"""

import asyncio
import base64
import hashlib
import json
import struct

import httpx
import pytest
from mcp.server.fastmcp import FastMCP

from anki_mcp.helper import Helper, HelperBusy, HelperRejected, HelperUnavailable
from anki_mcp.operations import OperationService
from anki_mcp.syncstatus import SyncNow
from anki_mcp.tools import Deps, register_tools
from anki_mcp.upload import (HEIF_HINT, UPLOAD_PATH, WIDGET_MIME, WIDGET_URI, UnsupportedImage, UploadGate,
                             UploadTickets, image_info, media_filename, widget_html)
from anki_host_fixture.operations import OperationError, Operations

MEDIA_MAX = 4096
BODY_MAX = 8192


def jpeg(width=2400, height=1800, pad=0):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, height, width, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    sos = b"\xff\xda" + struct.pack(">H", 8) + b"\x01\x01\x00\x00\x3f\x00"
    return b"\xff\xd8" + app0 + sof0 + sos + b"\x00" * (16 + pad) + b"\xff\xd9"


def png(width=1200, height=900):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr + b"\x00" * 4 + b"\x00" * 12


def gif(width=320, height=240):
    return b"GIF89a" + struct.pack("<HH", width, height) + b"\x00" * 16


def webp(kind, width=800, height=600):
    if kind == "VP8X":
        payload = b"\x00" * 4 + (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
    elif kind == "VP8 ":
        payload = b"\x00\x00\x00" + b"\x9d\x01\x2a" + struct.pack("<HH", width, height)
    else:
        payload = b"\x2f" + ((width - 1) | ((height - 1) << 14)).to_bytes(4, "little")
    body = b"WEBP" + kind.encode() + struct.pack("<I", len(payload)) + payload
    return b"RIFF" + struct.pack("<I", len(body)) + body


HEIC = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic" + b"\x00" * 16


# --- format, size and naming -------------------------------------------------------------------------------

@pytest.mark.parametrize("data,expected", [
    (jpeg(), {"format": "jpeg", "width": 2400, "height": 1800}),
    (png(), {"format": "png", "width": 1200, "height": 900}),
    (gif(), {"format": "gif", "width": 320, "height": 240}),
    (webp("VP8X"), {"format": "webp", "width": 800, "height": 600}),
    (webp("VP8 "), {"format": "webp", "width": 800, "height": 600}),
    (webp("VP8L"), {"format": "webp", "width": 800, "height": 600}),
])
def test_image_info_reads_format_and_pixel_size_from_content(data, expected):
    assert image_info(data) == expected


def test_jpeg_without_frame_header_keeps_the_format_but_no_size():
    assert image_info(b"\xff\xd8\xff\xd9") == {"format": "jpeg", "width": None, "height": None}


def test_heif_family_is_refused_with_a_conversion_hint_and_other_bytes_without_one():
    with pytest.raises(UnsupportedImage) as heif:
        image_info(HEIC)
    assert heif.value.hint == HEIF_HINT and str(heif.value) == "unsupported-image-format"
    for data in (b"not an image at all", b"%PDF-1.7\n", b"<svg xmlns='http://www.w3.org/2000/svg'/>"):
        with pytest.raises(UnsupportedImage) as other:
            image_info(data)
        assert other.value.hint is None


def test_media_filename_follows_ankis_pasted_image_rule():
    data = jpeg()
    assert media_filename(data, "jpeg") == f"paste-{hashlib.sha1(data).hexdigest()}.jpg"
    assert media_filename(data, "webp").endswith(".webp")


def test_widget_html_embeds_inert_config_and_the_standard_protocol():
    html = widget_html("https://anki.example/upload</script><script>alert(1)</script>", 5242880)
    assert "__UPLOAD_CONFIG__" not in html
    assert "</script><script>alert(1)" not in html and "\\u003c/script\\u003e" in html
    assert '"maxBytes": 5242880' in html and '"resizeLongEdge": 3072' in html
    assert '"ticketTool": "anki_upload_ticket"' in html and '"2026-01-26"' in html
    assert "ui/update-model-context" in html and "ui/message" in html
    # Several files per pick, one summary listing every upload, and a note for the user before picking.
    assert 'type="file" multiple' in html and "ankiUploads" in html
    assert "AI는 여기서 올린 사진을 볼 수 없습니다. 내용을 보여 주려면 채팅에 첨부해 주세요." in html


# --- tickets -----------------------------------------------------------------------------------------------

def test_tickets_are_single_use_and_expire():
    now = [100.0]
    tickets = UploadTickets(120, clock=lambda: now[0])
    first, second = tickets.issue(), tickets.issue()
    assert first != second and len(first) >= 43
    assert tickets.consume(first) and not tickets.consume(first)
    now[0] += 121
    assert not tickets.consume(second)
    assert not tickets.consume("") and not tickets.consume("unknown") and not tickets.consume(None)


def test_outstanding_tickets_are_bounded_oldest_first():
    tickets = UploadTickets(120, limit=3)
    issued = [tickets.issue() for _ in range(4)]
    assert not tickets.consume(issued[0])
    assert all(tickets.consume(t) for t in issued[1:])


# --- /upload gate ------------------------------------------------------------------------------------------

class FakeOperations:
    def __init__(self, result=None, error=None):
        self.calls, self.result, self.error = [], result, error

    async def run(self, action, params, *, request_id=None):
        self.calls.append((action, params, request_id))
        if self.error:
            raise self.error
        return self.result or {"state": "applied", "request_id": request_id, "operation_id": "op",
                               "summary": {"unchanged": False}, "sync": {"state": "disabled"},
                               "notification": {"state": "disabled"}}


async def passthrough(scope, receive, send):
    await send({"type": "http.response.start", "status": 299, "headers": []})
    await send({"type": "http.response.body", "body": b"inner"})


def gate(operations=None, tickets=None, read_timeout=5):
    return UploadGate(passthrough, tickets=tickets or UploadTickets(120), operations=operations or FakeOperations(),
                      max_body_bytes=BODY_MAX, media_max_bytes=MEDIA_MAX, read_timeout=read_timeout)


def client(app):
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://anki.example")


@pytest.mark.anyio
async def test_preflight_and_method_limits_carry_cors_headers():
    async with client(gate()) as http:
        pre = await http.options(UPLOAD_PATH, headers={"origin": "https://sandbox.example",
                                                       "access-control-request-method": "POST"})
        assert pre.status_code == 204 and pre.headers["access-control-allow-origin"] == "*"
        assert pre.headers["access-control-allow-methods"] == "POST, OPTIONS"
        get = await http.get(UPLOAD_PATH)
        assert get.status_code == 405 and get.headers["access-control-allow-origin"] == "*"
        other = await http.post("/mcp", content=b"{}")
        assert other.status_code == 299 and other.text == "inner"


@pytest.mark.anyio
async def test_missing_or_unknown_ticket_is_refused_before_reading_the_body():
    sent = []

    async def never_read():
        raise AssertionError("the body must not be read without a valid ticket")

    async def send(message):
        sent.append(message)

    for query in (b"", b"ticket=", b"ticket=unknown"):
        sent.clear()
        scope = {"type": "http", "method": "POST", "path": UPLOAD_PATH, "query_string": query,
                 "headers": [(b"content-length", b"10")]}
        await gate()(scope, never_read, send)
        assert sent[0]["status"] == 401 and (b"access-control-allow-origin", b"*") in sent[0]["headers"]
        assert json.loads(sent[1]["body"]) == {"error": "invalid-or-expired-ticket"}


@pytest.mark.anyio
async def test_store_uses_the_journaled_media_path_with_a_content_name():
    tickets, operations = UploadTickets(120), FakeOperations()
    ticket, data = tickets.issue(), jpeg()
    async with client(gate(operations, tickets)) as http:
        r = await http.post(f"{UPLOAD_PATH}?ticket={ticket}", files={"file": ("IMG_1234.jpeg", data, "image/jpeg")})
        assert r.status_code == 200, r.text
        assert r.headers["access-control-allow-origin"] == "*"
        name = f"paste-{hashlib.sha1(data).hexdigest()}.jpg"
        assert r.json() == {"state": "applied", "request_id": "upload-" + hashlib.sha256(ticket.encode()).hexdigest()[:32],
                            "operation_id": "op", "unchanged": False, "sync": "disabled", "notification": "disabled",
                            "filename": name, "bytes": len(data), "format": "jpeg", "width": 2400, "height": 1800}
        action, params, request_id = operations.calls[0]
        assert action == "store_media" and params == {"filename": name, "data": base64.b64encode(data).decode()}
        assert request_id == r.json()["request_id"]
        again = await http.post(f"{UPLOAD_PATH}?ticket={ticket}", files={"file": ("x.jpg", data, "image/jpeg")})
        assert again.status_code == 401 and len(operations.calls) == 1


@pytest.mark.anyio
@pytest.mark.parametrize("files,status,payload", [
    ({"other": ("a.jpg", jpeg(), "image/jpeg")}, 400, {"error": "bad-form"}),
    ({"file": ("a.jpg", b"", "image/jpeg")}, 413, {"error": "media-too-large"}),
    ({"file": ("a.jpg", jpeg(pad=MEDIA_MAX), "image/jpeg")}, 413, {"error": "media-too-large"}),
    ({"file": ("a.heic", HEIC, "image/heic")}, 415, {"error": "unsupported-image-format", "hint": HEIF_HINT}),
    ({"file": ("a.txt", b"hello world", "text/plain")}, 415, {"error": "unsupported-image-format"}),
])
async def test_bad_uploads_are_refused_without_a_store(files, status, payload):
    tickets, operations = UploadTickets(120), FakeOperations()
    async with client(gate(operations, tickets)) as http:
        r = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}", files=files)
    assert (r.status_code, r.json()) == (status, payload) and operations.calls == []


@pytest.mark.anyio
async def test_two_file_parts_are_a_bad_form():
    tickets, operations = UploadTickets(120), FakeOperations()
    async with client(gate(operations, tickets)) as http:
        r = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}",
                            files=[("file", ("a.jpg", jpeg(), "image/jpeg")), ("file", ("b.jpg", jpeg(), "image/jpeg"))])
    assert (r.status_code, r.json()) == (400, {"error": "bad-form"}) and operations.calls == []


@pytest.mark.anyio
async def test_body_limits_apply_to_declared_and_streamed_lengths():
    tickets, sent = UploadTickets(120), []

    async def never_read():
        raise AssertionError("an oversized declared length must be refused before reading the body")

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "method": "POST", "path": UPLOAD_PATH,
             "query_string": f"ticket={tickets.issue()}".encode(),
             "headers": [(b"content-length", str(BODY_MAX + 1).encode())]}
    await gate(tickets=tickets)(scope, never_read, send)
    assert sent[0]["status"] == 413 and json.loads(sent[1]["body"]) == {"error": "request-body-too-large"}

    sent.clear()
    chunks = [{"type": "http.request", "body": b"x" * BODY_MAX, "more_body": True},
              {"type": "http.request", "body": b"x", "more_body": False}]

    async def receive():
        return chunks.pop(0)

    scope.update(query_string=f"ticket={tickets.issue()}".encode(), headers=[])
    await gate(tickets=tickets)(scope, receive, send)
    assert sent[0]["status"] == 413 and json.loads(sent[1]["body"]) == {"error": "request-body-too-large"}


@pytest.mark.anyio
async def test_slow_body_times_out_and_a_disconnect_sends_nothing():
    tickets = UploadTickets(120)
    sent = []

    async def send(message):
        sent.append(message)

    async def stall():
        await asyncio.sleep(10)

    scope = {"type": "http", "method": "POST", "path": UPLOAD_PATH,
             "query_string": f"ticket={tickets.issue()}".encode(), "headers": []}
    await gate(tickets=tickets, read_timeout=0.01)(scope, stall, send)
    assert sent[0]["status"] == 408 and json.loads(sent[1]["body"]) == {"error": "upload-read-timeout"}

    sent.clear()

    async def gone():
        return {"type": "http.disconnect"}

    scope["query_string"] = f"ticket={tickets.issue()}".encode()
    await gate(tickets=tickets)(scope, gone, send)
    assert sent == []


@pytest.mark.anyio
@pytest.mark.parametrize("error,status,payload", [
    (HelperRejected("media-exists-with-different-content"), 422, {"error": "media-exists-with-different-content"}),
    (HelperBusy("export"), 503, {"error": "helper-busy"}),
    (HelperUnavailable("down"), 503, {"error": "helper-unavailable"}),
])
async def test_helper_outcomes_map_to_http_errors(error, status, payload):
    tickets = UploadTickets(120)
    async with client(gate(FakeOperations(error=error), tickets)) as http:
        r = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}", files={"file": ("a.png", png(), "image/png")})
    assert (r.status_code, r.json()) == (status, payload)


@pytest.mark.anyio
async def test_unexpected_store_failure_never_invites_a_blind_retry():
    tickets = UploadTickets(120)
    async with client(gate(FakeOperations(error=RuntimeError("sync crashed")), tickets)) as http:
        r = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}", files={"file": ("a.gif", gif(), "image/gif")})
    assert r.status_code == 500 and r.json()["error"] == "upload-failed"
    assert r.json()["filename"].startswith("paste-") and "anki_recent_operations" in r.json()["next_step"]


# --- end to end through the real journal -------------------------------------------------------------------

class MediaAdapter:
    """Minimal helper adapter: remembers stored media and reports same-content stores as unchanged."""

    def __init__(self):
        self.media, self.applied = {}, []

    def inspect(self, spec):
        p = spec["params"]
        existing = self.media.get(p["filename"])
        return {"snapshot": {"media": p["filename"], "existing": existing},
                "summary": {"filename": p["filename"], "unchanged": existing == p["data"]}}

    def apply(self, spec):
        self.applied.append(spec)
        self.media[spec["params"]["filename"]] = spec["params"]["data"]
        return {"state": "applied"}


def journaled_operations(tmp_path, adapter):
    engine = Operations(tmp_path / "operations", adapter, lambda _: {"mirrored": True},
                        ttl=600, bulk_limit=20, media_limit=MEDIA_MAX)

    def handler(request):
        body = json.loads(request.content)
        path = request.url.path.rsplit("/", 1)[1]
        try:
            if path == "status":
                result = engine.status(body["operation_id"])
            elif path == "prepare":
                result = engine.prepare(body["action"], body["params"], body.get("request_id"))
            elif path == "apply":
                result = engine.apply(body["operation_id"], body["preview_token"], body.get("confirm", False))
            else:
                result = engine.record_delivery(body["operation_id"], body["kind"], body["receipt"])
            return httpx.Response(200, json={"ok": True, "result": result})
        except OperationError as err:
            return httpx.Response(400, json={"ok": False, "error": str(err)})

    helper = Helper("http://helper", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)), key="2" * 64)

    async def no_host_commands(argv):
        raise AssertionError("unit tests must never run systemctl")

    syncer = SyncNow(str(tmp_path / "main.json"), "u.service", 1, runner=no_host_commands)
    return OperationService(helper, syncer, None, sync_enabled=False)


@pytest.mark.anyio
async def test_upload_is_journaled_once_and_a_repeat_is_a_no_op(tmp_path):
    adapter = MediaAdapter()
    tickets, operations = UploadTickets(120), journaled_operations(tmp_path, adapter)
    data = png()
    async with client(gate(operations, tickets)) as http:
        first = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}", files={"file": ("IMG_1.png", data, "image/png")})
        second = await http.post(f"{UPLOAD_PATH}?ticket={tickets.issue()}", files={"file": ("image.png", data, "image/png")})
    assert first.status_code == second.status_code == 200, (first.text, second.text)
    name = f"paste-{hashlib.sha1(data).hexdigest()}.png"
    assert first.json()["state"] == "applied" and first.json()["filename"] == name
    assert first.json()["unchanged"] is False and second.json()["unchanged"] is True
    assert first.json()["sync"] == "disabled" and first.json()["notification"] == "disabled"
    assert first.json()["request_id"] != second.json()["request_id"]
    assert adapter.media == {name: base64.b64encode(data).decode()}


# --- tool registration -------------------------------------------------------------------------------------

def registered(tmp_path, tickets):
    mcp = FastMCP("t")
    register_tools(mcp, Deps(anki=None, helper=None, syncer=None, sync_status_file=str(tmp_path / "s.json"),
                             field_chars=10, page_max=10, operations=OperationService(None, None, None, sync_enabled=False),
                             media_max_bytes=5242880, public_url="https://anki.example", uploads=tickets))
    return mcp


@pytest.mark.anyio
async def test_upload_tools_and_resource_follow_mcp_apps_metadata(tmp_path):
    tickets = UploadTickets(120)
    mcp = registered(tmp_path, tickets)
    tools = {tool.name: tool for tool in await mcp.list_tools()}
    box, ticket_tool = tools["anki_upload_image"], tools["anki_upload_ticket"]
    assert box.meta == {"ui": {"resourceUri": WIDGET_URI}} and box.annotations.readOnlyHint is True
    assert ticket_tool.meta == {"ui": {"visibility": ["app"]}} and ticket_tool.annotations.readOnlyHint is True
    assert "chat attachments cannot be passed" in box.description and "paste-<SHA-1>" in box.description
    assert "one or more images" in box.description and "Open one box per request" in box.description
    assert "use anki_upload_image" in tools["anki_store_media"].description
    resources = await mcp.list_resources()
    assert [(str(r.uri), r.mimeType, r.meta) for r in resources] == [
        (WIDGET_URI, WIDGET_MIME, {"ui": {"csp": {"connectDomains": ["https://anki.example"]}, "prefersBorder": True}})]
    [content] = await mcp.read_resource(WIDGET_URI)
    assert content.mime_type == WIDGET_MIME and content.meta == resources[0].meta
    assert '"uploadUrl": "https://anki.example/upload"' in content.content

    shown = await mcp.call_tool("anki_upload_image", {})
    assert shown.structuredContent == {"maxBytes": 5242880, "formats": ["jpeg", "png", "gif", "webp"],
                                       "resizeLongEdge": 3072}
    assert "upload box is shown" in shown.content[0].text
    assert "You cannot see images uploaded through the box" in shown.content[0].text
    assert "Do not open another box" in shown.content[0].text
    issued = await mcp.call_tool("anki_upload_ticket", {})
    value = issued.structuredContent["ticket"]
    assert issued.structuredContent["expiresInSeconds"] == 120 and value not in issued.content[0].text
    assert tickets.consume(value)
