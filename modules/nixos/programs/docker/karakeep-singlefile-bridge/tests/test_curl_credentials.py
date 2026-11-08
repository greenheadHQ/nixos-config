"""합성 자격만 사용하여 argv 비노출과 실제 curl 전송을 함께 검증한다."""

from email import policy
from email.parser import BytesParser
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import subprocess

import pytest


AUTH = "Bearer synthetic-auth-'quoted\"-back\\slash space\ttab"
TOKEN = "synthetic-token-'quoted\"-back\\slash space\ttab\nnext\rline"
USER = "synthetic-user-'quoted\"-back\\slash space\ttab\nnext\rline"
MESSAGE = '합성 알림\n두 번째 줄\r탭\t와 "인용" \\ 보존'
FILE_BYTES = b"<html>synthetic archive\x00bytes</html>"


def multipart_parts(headers, body):
    message = BytesParser(policy=policy.default).parsebytes(
        f"Content-Type: {headers['Content-Type']}\r\nMIME-Version: 1.0\r\n\r\n".encode()
        + body
    )
    return [
        (part.get_param("name", header="content-disposition"),
         part.get_filename(), part.get_payload(decode=True))
        for part in message.iter_parts()
    ]


def small_request(module, auth=AUTH):
    boundary = "synthetic-upload-boundary"
    fields = [("url", "https://example.test/item"), ("title", MESSAGE), ("tag", "first"), ("tag", "second")]
    body = b""
    for key, value in fields:
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n'
                 f"{value}\r\n").encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="archive.html"\r\n'
             "Content-Type: text/html\r\n\r\n").encode() + FILE_BYTES + f"\r\n--{boundary}--\r\n".encode()
    responses = []
    handler = SimpleNamespace(
        path="/api/v1/bookmarks/singlefile?ifexists=append", rfile=BytesIO(body),
        headers={"Authorization": auth, "Content-Type": f"multipart/form-data; boundary={boundary}",
                 "Content-Length": str(len(body))},
        respond_json=lambda *args: responses.append(args),
        respond_bytes=lambda *args: responses.append(args),
    )
    module.SingleFileBridgeHandler._do_post(handler)
    return responses, fields


@pytest.fixture
def curl_transport(bridge_module, fake_karakeep_upstream, monkeypatch):
    requests, calls = [], []
    server = fake_karakeep_upstream
    endpoint = f"http://127.0.0.1:{server.server_port}"

    def receive(handler):
        body = handler.rfile.read(int(handler.headers["Content-Length"]))
        requests.append((handler.path, handler.headers, body))
        response = b'{"assetId":"synthetic-asset","ok":true}'
        handler.send_response(201)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(response)))
        handler.end_headers()
        handler.wfile.write(response)

    monkeypatch.setattr(server.RequestHandlerClass, "do_POST", receive)
    monkeypatch.setattr(bridge_module, "KARAKEEP_BASE_URL", endpoint)
    monkeypatch.setattr(bridge_module, "PUSHOVER_TOKEN", TOKEN)
    monkeypatch.setattr(bridge_module, "PUSHOVER_USER", USER)
    original_run = subprocess.run

    def run(cmd, **kwargs):
        calls.append((list(cmd), dict(kwargs)))
        actual = list(cmd)
        if actual[-1] == "https://api.pushover.net/1/messages.json":
            # 운영 호출의 원래 argv를 먼저 기록하고, 테스트 전송만 loopback으로 제한한다.
            actual[-1] = endpoint + "/notification"
            actual[actual.index("--proto") + 1] = "=http"
        else:
            assert any(arg.startswith(endpoint + "/") for arg in actual)
        return original_run(actual, **kwargs)

    monkeypatch.setattr(bridge_module.subprocess, "run", run)
    return requests, calls


@pytest.mark.parametrize("route", ["notification", "link", "asset", "small"])
def test_credentials_are_absent_from_argv_and_preserved_on_wire(
    bridge_module, curl_transport, tmp_path, route,
):
    requests, calls = curl_transport
    if route == "notification":
        bridge_module.send_pushover(MESSAGE, 1)
    elif route == "link":
        status, _body, content_type, error = bridge_module.create_link_bookmark(
            AUTH, "https://example.test/item", MESSAGE)
        assert (status, content_type, error) == (201, "application/json; charset=utf-8", None)
    elif route == "asset":
        archive = tmp_path / "archive.html"
        archive.write_bytes(FILE_BYTES)
        assert bridge_module.upload_asset(AUTH, str(archive), "archive.html") == ("synthetic-asset", 201, None)
    else:
        responses, fields = small_request(bridge_module)
        assert responses[0][0] == 201

    assert len(requests) == len(calls) == 1
    cmd, kwargs = calls[0]
    for marker in ("synthetic-auth", "synthetic-token", "synthetic-user"):
        assert all(marker not in argument for argument in cmd)
    assert cmd[1] == "-q"
    assert cmd[cmd.index("--config") + 1] == "-"
    assert isinstance(kwargs.get("input"), str)
    path, headers, body = requests[0]
    assert headers.get("Injected") is None
    if route == "notification":
        assert cmd[cmd.index("--max-time") + 1] == "10"
        assert kwargs["check"] is False
        assert multipart_parts(headers, body) == [
            ("token", None, TOKEN.encode()), ("user", None, USER.encode()),
            ("title", None, b"Karakeep"), ("message", None, MESSAGE.encode()), ("priority", None, b"1"),
        ]
    else:
        assert headers["Authorization"] == AUTH
        assert cmd[cmd.index("--max-time") + 1] == str(bridge_module.REQUEST_TIMEOUT_SEC)
        assert kwargs["timeout"] == bridge_module.REQUEST_TIMEOUT_SEC + 10
        if route == "link":
            assert json.loads(body) == {"type": "link", "url": "https://example.test/item",
                                        "source": "singlefile", "title": MESSAGE}
        elif route == "asset":
            assert multipart_parts(headers, body) == [("file", "archive.html", FILE_BYTES)]
        else:
            assert path.endswith("?ifexists=append")
            assert multipart_parts(headers, body) == [
                (key, None, value.encode()) for key, value in fields
            ] + [("file", "archive.html", FILE_BYTES)]


@pytest.mark.parametrize("auth", ["Bearer synthetic\rInjected: value", "Bearer synthetic\nInjected: value",
                                  "Bearer synthetic\r\n", "Bearer synthetic\x00tail"])
@pytest.mark.parametrize("route", ["link", "asset", "small"])
def test_invalid_authorization_is_rejected_before_curl(bridge_module, monkeypatch, auth, route):
    def forbidden(*_args, **_kwargs):
        pytest.fail("유효하지 않은 헤더로 curl을 실행하면 안 된다")

    monkeypatch.setattr(bridge_module.subprocess, "run", forbidden)
    if route == "small":
        responses, _fields = small_request(bridge_module, auth)
        assert responses == [(400, {"error": "Invalid Authorization header"})]
    else:
        with pytest.raises(ValueError, match="Invalid Authorization header") as error:
            if route == "link":
                bridge_module.create_link_bookmark(auth, "https://example.test/item", "")
            else:
                bridge_module.upload_asset(auth, "unused", "archive.html")
        assert auth not in str(error.value)


@pytest.mark.parametrize("field", ["token", "user", "message"])
def test_notification_nul_is_rejected_without_disclosing_values(bridge_module, monkeypatch, field):
    def forbidden(*_args, **_kwargs):
        pytest.fail("NUL이 있는 폼을 curl에 넘기면 안 된다")

    invalid = "synthetic-invalid\x00tail"
    monkeypatch.setattr(bridge_module, "PUSHOVER_TOKEN", invalid if field == "token" else TOKEN)
    monkeypatch.setattr(bridge_module, "PUSHOVER_USER", invalid if field == "user" else USER)
    monkeypatch.setattr(bridge_module.subprocess, "run", forbidden)
    with pytest.raises(ValueError, match="Invalid curl config value") as error:
        bridge_module.send_pushover(invalid if field == "message" else MESSAGE)
    assert "synthetic-invalid" not in str(error.value)


@pytest.mark.parametrize("mode", ["failure", "status", "timeout", "http"])
def test_curl_errors_hide_config_and_preserve_response_contract(bridge_module, monkeypatch, mode):
    def run(cmd, **kwargs):
        config = kwargs["input"]
        if mode == "timeout":
            raise subprocess.TimeoutExpired(cmd, kwargs["timeout"], output=config, stderr=AUTH)
        if mode == "failure":
            return subprocess.CompletedProcess(cmd, 7, config, AUTH)
        if mode == "status":
            return subprocess.CompletedProcess(cmd, 0, config, "")
        Path(cmd[cmd.index("-o") + 1]).write_bytes(b"upstream failure")
        Path(cmd[cmd.index("-D") + 1]).write_text("Content-Type: text/plain\r\n")
        return subprocess.CompletedProcess(cmd, 0, "503", "")

    monkeypatch.setattr(bridge_module.subprocess, "run", run)
    result = bridge_module.create_link_bookmark(AUTH, "https://example.test/item", "")
    assert AUTH not in str(result)
    assert "header =" not in str(result)
    if mode == "http":
        assert result == (503, b"upstream failure", "text/plain", None)
    else:
        assert result[:3] == (None, b"", "application/json")
        assert result[3]
