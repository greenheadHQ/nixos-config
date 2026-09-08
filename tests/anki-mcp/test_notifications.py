from urllib.parse import parse_qs

import httpx
import pytest

from anki_mcp.notifications import Notifications


@pytest.mark.anyio
@pytest.mark.parametrize("http_status,body,result", [(200, {"status": 1}, "sent"),
                                                    (200, {"status": 0}, "failed"),
                                                    (400, {"status": 0}, "failed"), (200, None, "unknown")])
async def test_notification_requires_api_success_and_omits_note_body(tmp_path, http_status, body, result):
    credentials = tmp_path / "pushover"
    credentials.write_text("PUSHOVER_TOKEN=test-app\nPUSHOVER_USER=test-user\n")
    def handle(request):
        sent = parse_qs(request.content.decode())
        assert sent["token"] == ["test-app"] and sent["user"] == ["test-user"]
        assert "private-note-field" not in request.content.decode()
        assert "동기화 완료" in sent["message"][0]
        return httpx.Response(http_status, json=body)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        notification = Notifications(str(credentials), client)
        outcome = await notification.send({"operation_id": "1" * 32, "action": "add_tags", "state": "applied",
            "summary": {"notes": 1, "cards": 1}, "sync": {"state": "synced"}, "fields": "private-note-field"})
    assert outcome == result


@pytest.mark.anyio
async def test_notification_timeout_is_unknown_not_safe_to_resend(tmp_path):
    credentials = tmp_path / "pushover"
    credentials.write_text("PUSHOVER_TOKEN=test-app\nPUSHOVER_USER=test-user\n")
    def handle(request):
        raise httpx.ReadTimeout("response lost", request=request)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        outcome = await Notifications(str(credentials), client).send({"operation_id": "1" * 32,
            "action": "add_tags", "state": "applied", "summary": {}, "sync": {"state": "pending"}})
    assert outcome == "unknown"
