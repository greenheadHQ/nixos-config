#!/usr/bin/env python3
import json
import os
import re
import signal
import sqlite3
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MAX_ASSET_SIZE_MB = int(os.environ.get("MAX_ASSET_SIZE_MB", "50"))
MAX_ASSET_SIZE_BYTES = MAX_ASSET_SIZE_MB * 1024 * 1024
DEFAULT_MAX_REQUEST_BODY_MB = max(MAX_ASSET_SIZE_MB * 3, 200)
MAX_REQUEST_BODY_MB = int(
    os.environ.get("SINGLEFILE_BRIDGE_MAX_REQUEST_MB", str(DEFAULT_MAX_REQUEST_BODY_MB))
)
MAX_REQUEST_BODY_BYTES = MAX_REQUEST_BODY_MB * 1024 * 1024
KARAKEEP_BASE_URL = os.environ.get("KARAKEEP_BASE_URL", "http://127.0.0.1:3000").rstrip("/")
LISTEN_HOST = os.environ.get("SINGLEFILE_BRIDGE_LISTEN", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SINGLEFILE_BRIDGE_PORT", "3010"))
REQUEST_TIMEOUT_SEC = int(os.environ.get("SINGLEFILE_BRIDGE_TIMEOUT_SEC", "240"))
KARAKEEP_DB_PATH = os.environ.get("KARAKEEP_DB_PATH", "/mnt/data/karakeep/db.db")
KARAKEEP_QUEUE_DB_PATH = os.environ.get("KARAKEEP_QUEUE_DB_PATH", "/mnt/data/karakeep/queue.db")
SQLITE_BUSY_TIMEOUT_MS = int(os.environ.get("SINGLEFILE_BRIDGE_SQLITE_TIMEOUT_MS", "5000"))

PUSHOVER_TOKEN = os.environ.get("PUSHOVER_TOKEN", "")
PUSHOVER_USER = os.environ.get("PUSHOVER_USER", "")


def log(msg: str) -> None:
    print(msg, flush=True)


def shorten_url(url: str) -> str:
    short = re.sub(r"^https?://", "", url)
    short = short.split("?", 1)[0].rstrip("/")
    return short


def sanitize_filename(name: str) -> str:
    base = os.path.basename(name or "archive.html")
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("._")
    if not cleaned:
        cleaned = "archive"
    if not re.search(r"\.(html?|xhtml)$", cleaned, flags=re.IGNORECASE):
        cleaned = f"{cleaned}.html"
    return cleaned


def extract_boundary(content_type: str) -> str | None:
    match = re.search(r'boundary="?([^";]+)"?', content_type, flags=re.IGNORECASE)
    if not match:
        return None
    return match.group(1)


def parse_content_disposition(value: str) -> dict[str, str]:
    parts = [part.strip() for part in value.split(";")]
    attrs: dict[str, str] = {}
    if parts:
        attrs["type"] = parts[0].lower()
    for part in parts[1:]:
        if "=" not in part:
            continue
        key, raw = part.split("=", 1)
        attrs[key.strip().lower()] = raw.strip().strip('"')
    return attrs


def parse_multipart_body(body: bytes, boundary: str) -> tuple[list[tuple[str, str]], dict | None]:
    delimiter = f"--{boundary}".encode("utf-8")
    text_fields: list[tuple[str, str]] = []
    file_part = None

    for chunk in body.split(delimiter):
        if not chunk:
            continue
        if chunk.startswith(b"--"):
            continue
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        if chunk.endswith(b"\r\n"):
            chunk = chunk[:-2]
        if not chunk or b"\r\n\r\n" not in chunk:
            continue

        header_blob, content = chunk.split(b"\r\n\r\n", 1)
        headers = {}
        for raw_line in header_blob.split(b"\r\n"):
            if b":" not in raw_line:
                continue
            key, value = raw_line.split(b":", 1)
            headers[key.decode("latin1").strip().lower()] = value.decode("latin1").strip()

        disposition = parse_content_disposition(headers.get("content-disposition", ""))
        if disposition.get("type") != "form-data":
            continue

        field_name = disposition.get("name", "")
        if not field_name:
            continue

        filename = disposition.get("filename")
        if filename is not None:
            file_part = {
                "name": field_name,
                "filename": filename,
                "content": content,
                "content_type": headers.get("content-type", "application/octet-stream"),
            }
            continue

        text_fields.append((field_name, content.decode("utf-8", errors="replace")))

    return text_fields, file_part


def parse_response_headers(headers_path: str) -> str:
    content_type = "application/json"
    try:
        with open(headers_path, "r", encoding="utf-8", errors="ignore") as fp:
            for line in reversed(fp.readlines()):
                if line.lower().startswith("content-type:"):
                    content_type = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    return content_type


def run_curl(cmd: list[str]) -> tuple[int | None, bytes, str, str | None]:
    body_fd, body_path = tempfile.mkstemp(prefix="karakeep-bridge-body-")
    header_fd, header_path = tempfile.mkstemp(prefix="karakeep-bridge-header-")
    os.close(body_fd)
    os.close(header_fd)
    try:
        full_cmd = [
            *cmd,
            "-D",
            header_path,
            "-o",
            body_path,
            "-w",
            "%{http_code}",
        ]
        result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=REQUEST_TIMEOUT_SEC + 10)
        if result.returncode != 0:
            err = (result.stderr or result.stdout or "").strip()
            return None, b"", "application/json", f"curl failed: {err}"

        status_text = (result.stdout or "").strip()
        if not status_text.isdigit():
            return None, b"", "application/json", f"unexpected curl status output: {status_text}"

        status_code = int(status_text)
        with open(body_path, "rb") as fp:
            body = fp.read()
        content_type = parse_response_headers(header_path)
        return status_code, body, content_type, None
    except subprocess.TimeoutExpired:
        return None, b"", "application/json", "curl timeout"
    finally:
        for path in (body_path, header_path):
            try:
                os.unlink(path)
            except OSError:
                pass


def parse_json_body(body: bytes) -> dict:
    try:
        parsed = json.loads(body.decode("utf-8"))
        if isinstance(parsed, dict):
            return parsed
    except (UnicodeDecodeError, json.JSONDecodeError):
        pass
    return {}


def send_pushover(message: str, priority: int = 0) -> None:
    if not PUSHOVER_TOKEN or not PUSHOVER_USER:
        return
    cmd = [
        "curl",
        "-sf",
        "--proto",
        "=https",
        "--max-time",
        "10",
        "--form-string",
        f"token={PUSHOVER_TOKEN}",
        "--form-string",
        f"user={PUSHOVER_USER}",
        "--form-string",
        "title=Karakeep",
        "--form-string",
        f"message={message}",
        "--form-string",
        f"priority={priority}",
        "https://api.pushover.net/1/messages.json",
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def parse_ifexists_mode(query: str) -> str:
    raw = parse_qs(query).get("ifexists", ["skip"])[0].strip().lower()
    valid = {"skip", "overwrite", "overwrite-recrawl", "append", "append-recrawl"}
    return raw if raw in valid else "skip"


def create_link_bookmark(auth_header: str, source_url: str, title_value: str) -> tuple[int | None, bytes, str, str | None]:
    payload = {
        "type": "link",
        "url": source_url,
        "source": "singlefile",
    }
    if title_value:
        payload["title"] = title_value

    cmd = [
        "curl",
        "-sS",
        "--max-time",
        str(REQUEST_TIMEOUT_SEC),
        "-X",
        "POST",
        "-H",
        f"Authorization: {auth_header}",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Accept: application/json",
        "--data",
        json.dumps(payload, ensure_ascii=False),
        f"{KARAKEEP_BASE_URL}/api/v1/bookmarks",
    ]
    return run_curl(cmd)


def upload_asset(auth_header: str, temp_path: str, original_name: str) -> tuple[str | None, int | None, str | None]:
    upload_asset_cmd = [
        "curl",
        "-sS",
        "--max-time",
        str(REQUEST_TIMEOUT_SEC),
        "-X",
        "POST",
        "-H",
        f"Authorization: {auth_header}",
        "-H",
        "Accept: application/json",
        "-F",
        f"file=@{temp_path};filename={original_name};type=text/html",
        f"{KARAKEEP_BASE_URL}/api/v1/assets",
    ]
    status, body, _, err = run_curl(upload_asset_cmd)
    if err:
        return None, status, f"asset upload failed ({err})"
    if status is None or status < 200 or status >= 300:
        return None, status, f"asset upload HTTP {status or 'unknown'}"
    asset_id = parse_json_body(body).get("assetId")
    if not asset_id:
        return None, status, "asset upload response missing assetId"
    return str(asset_id), status, None


def with_sqlite_write(db_path: str, fn) -> int:
    conn = sqlite3.connect(db_path, timeout=max(SQLITE_BUSY_TIMEOUT_MS / 1000.0, 1.0))
    try:
        conn.execute(f"PRAGMA busy_timeout={SQLITE_BUSY_TIMEOUT_MS}")
        conn.execute("BEGIN IMMEDIATE")
        result = fn(conn)
        conn.execute("COMMIT")
        return result
    except Exception:
        try:
            conn.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        raise
    finally:
        conn.close()


def attach_fullpage_archive(bookmark_id: str, asset_id: str, detach_existing_full_archive: bool) -> None:
    def _write(conn: sqlite3.Connection) -> int:
        before_rows = conn.execute(
            "SELECT id, bookmarkId, assetType FROM assets WHERE bookmarkId=? OR id=? ORDER BY id LIMIT 50",
            (bookmark_id, asset_id),
        ).fetchall()
        log(
            f"attach_fullpage_archive(before): bookmarkId={bookmark_id} "
            f"assetId={asset_id} detachExisting={detach_existing_full_archive} rows={before_rows}"
        )

        # Prevent crawler OOM path: do not leave precrawledArchive attached.
        conn.execute(
            "UPDATE assets SET assetType='unknown', bookmarkId=NULL "
            "WHERE bookmarkId=? AND assetType='linkPrecrawledArchive'",
            (bookmark_id,),
        )
        if detach_existing_full_archive:
            conn.execute(
                "UPDATE assets SET assetType='unknown', bookmarkId=NULL "
                "WHERE bookmarkId=? AND assetType='linkFullPageArchive' AND id<>?",
                (bookmark_id, asset_id),
            )
        cur = conn.execute(
            "UPDATE assets SET bookmarkId=?, assetType='linkFullPageArchive' WHERE id=?",
            (bookmark_id, asset_id),
        )
        after_rows = conn.execute(
            "SELECT id, bookmarkId, assetType FROM assets WHERE bookmarkId=? OR id=? ORDER BY id LIMIT 50",
            (bookmark_id, asset_id),
        ).fetchall()
        log(
            f"attach_fullpage_archive(after): bookmarkId={bookmark_id} "
            f"assetId={asset_id} updated={cur.rowcount} rows={after_rows}"
        )
        if cur.rowcount != 1:
            raise RuntimeError("failed to link uploaded asset as fullPageArchive")
        return cur.rowcount

    with_sqlite_write(KARAKEEP_DB_PATH, _write)


def cleanup_stale_crawler_tasks(bookmark_id: str) -> int:
    if not os.path.exists(KARAKEEP_QUEUE_DB_PATH):
        return 0

    payload_match = f'%\"bookmarkId\":\"{bookmark_id}\"%'
    queue_filter = "queue IN ('link_crawler_queue', 'low_priority_crawler_queue', 'crawl_link')"

    def _write(conn: sqlite3.Connection) -> int:
        try:
            cur = conn.execute(
                f"DELETE FROM tasks WHERE {queue_filter} "
                "AND json_extract(payload, '$.bookmarkId') = ?",
                (bookmark_id,),
            )
            return max(cur.rowcount, 0)
        except sqlite3.Error as exc:
            log(f"cleanup_stale_crawler_tasks: json_extract query failed, fallback to LIKE ({exc})")
            cur = conn.execute(
                f"DELETE FROM tasks WHERE {queue_filter} "
                "AND payload LIKE ?",
                (payload_match,),
            )
            return max(cur.rowcount, 0)

    return with_sqlite_write(KARAKEEP_QUEUE_DB_PATH, _write)


class SingleFileBridgeHandler(BaseHTTPRequestHandler):
    server_version = "KarakeepSingleFileBridge/1.0"

    def log_message(self, fmt: str, *args) -> None:
        log(f"{self.client_address[0]} - {fmt % args}")

    def respond_bytes(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def respond_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.respond_bytes(status, body, "application/json; charset=utf-8")

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path in ("/healthz", "/health"):
            self.respond_json(
                200,
                {
                    "status": "ok",
                    "maxAssetSizeMb": MAX_ASSET_SIZE_MB,
                    "maxRequestBodyMb": MAX_REQUEST_BODY_MB,
                },
            )
            return
        self.respond_json(404, {"error": "Not Found"})

    def do_POST(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path not in ("/api/v1/bookmarks/singlefile", "/"):
            self.respond_json(404, {"error": "Not Found"})
            return

        ifexists_mode = parse_ifexists_mode(parsed.query)
        auth_header = (self.headers.get("Authorization") or "").strip()
        if not auth_header.lower().startswith("bearer "):
            self.respond_json(401, {"error": "Missing Bearer token"})
            return

        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("multipart/form-data"):
            self.respond_json(415, {"error": "Content-Type must be multipart/form-data"})
            return
        boundary = extract_boundary(content_type)
        if not boundary:
            self.respond_json(400, {"error": "Missing multipart boundary"})
            return

        content_length_raw = self.headers.get("Content-Length", "0")
        try:
            content_length = int(content_length_raw)
        except ValueError:
            self.respond_json(400, {"error": "Invalid Content-Length"})
            return
        if content_length <= 0:
            self.respond_json(400, {"error": "Empty request body"})
            return
        if content_length > MAX_REQUEST_BODY_BYTES:
            self.respond_json(
                413,
                {
                    "error": "Request too large",
                    "maxRequestBodyMb": MAX_REQUEST_BODY_MB,
                },
            )
            return

        temp_path = None
        try:
            request_body = self.rfile.read(content_length)
            if len(request_body) != content_length:
                self.respond_json(400, {"error": "Truncated multipart body"})
                return

            fields, file_part = parse_multipart_body(request_body, boundary)
            request_body = b""

            if file_part is None:
                self.respond_json(400, {"error": "Missing file field"})
                return
            if file_part.get("name") != "file":
                self.respond_json(400, {"error": "Unsupported file field name"})
                return

            source_url = ""
            for key, value in fields:
                if key == "url" and value.strip():
                    source_url = value.strip()
            if not source_url:
                self.respond_json(400, {"error": "Missing url field"})
                return

            original_name = sanitize_filename(str(file_part.get("filename") or "archive.html"))
            file_bytes = file_part.get("content")
            if not isinstance(file_bytes, bytes):
                self.respond_json(400, {"error": "Invalid file payload"})
                return
            suffix = os.path.splitext(original_name)[1] or ".html"
            with tempfile.NamedTemporaryFile(
                delete=False, prefix="karakeep-singlefile-", suffix=suffix
            ) as temp_file:
                temp_path = temp_file.name
                temp_file.write(file_bytes)

            file_size = len(file_bytes)

            if file_size <= MAX_ASSET_SIZE_BYTES:
                endpoint = f"{KARAKEEP_BASE_URL}/api/v1/bookmarks/singlefile"
                if parsed.query:
                    endpoint = f"{endpoint}?{parsed.query}"

                cmd = [
                    "curl",
                    "-sS",
                    "--max-time",
                    str(REQUEST_TIMEOUT_SEC),
                    "-X",
                    "POST",
                    "-H",
                    f"Authorization: {auth_header}",
                    "-H",
                    "Accept: application/json",
                ]
                for key, value in fields:
                    cmd.extend(["--form-string", f"{key}={value}"])
                cmd.extend(["-F", f"file=@{temp_path};filename={original_name};type=text/html", endpoint])

                status, body, content_type, err = run_curl(cmd)
                if err:
                    self.respond_json(502, {"error": err})
                    return
                self.respond_bytes(status or 502, body, content_type)
                return

            title_value = next((value.strip() for key, value in fields if key == "title" and value.strip()), "")
            status, body, content_type, err = create_link_bookmark(auth_header, source_url, title_value)
            if err:
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 실패: {shorten_url(source_url)}",
                            f"원인: 링크 북마크 API 호출 실패 ({err})",
                        ]
                    ),
                    0,
                )
                self.respond_json(502, {"error": err})
                return

            if status is None or status < 200 or status >= 300:
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 실패: {shorten_url(source_url)}",
                            "원인: 링크 북마크 생성 실패",
                        ]
                    ),
                    0,
                )
                self.respond_bytes(status or 502, body, content_type)
                return

            bookmark_payload = parse_json_body(body)
            bookmark_id = bookmark_payload.get("id")
            already_exists = bool(bookmark_payload.get("alreadyExists"))
            if not bookmark_id:
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 실패: {shorten_url(source_url)}",
                            "원인: 북마크 ID 파싱 실패",
                        ]
                    ),
                    0,
                )
                self.respond_json(502, {"error": "missing bookmark id"})
                return

            if already_exists and ifexists_mode == "skip":
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 건너뜀: {shorten_url(source_url)}",
                            "원인: 동일 URL 북마크가 이미 존재 (ifexists=skip)",
                        ]
                    ),
                    0,
                )
                self.respond_json(
                    200,
                    {
                        "status": "already_exists_skip",
                        "url": source_url,
                        "bookmarkId": bookmark_id,
                        "assetSizeBytes": file_size,
                        "ifexists": ifexists_mode,
                    },
                )
                return

            asset_id, asset_status, asset_error = upload_asset(auth_header, temp_path, original_name)
            if asset_error or not asset_id:
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 실패: {shorten_url(source_url)}",
                            f"원인: Karakeep asset 업로드 실패 ({asset_error or 'unknown'})",
                        ]
                    ),
                    0,
                )
                self.respond_json(
                    asset_status or 502,
                    {"error": "asset upload failed", "detail": asset_error},
                )
                return

            try:
                detach_existing_full_archive = ifexists_mode != "append" and ifexists_mode != "append-recrawl"
                attach_fullpage_archive(str(bookmark_id), asset_id, detach_existing_full_archive)
                removed_tasks = cleanup_stale_crawler_tasks(str(bookmark_id)) if already_exists else 0
            except Exception as sql_exc:  # noqa: BLE001
                send_pushover(
                    "\n".join(
                        [
                            f"대용량 분기 실패: {shorten_url(source_url)}",
                            f"원인: DB 자산 연결 실패 ({sql_exc})",
                        ]
                    ),
                    0,
                )
                self.respond_json(
                    502,
                    {
                        "error": "failed to link fullPageArchive",
                        "assetId": asset_id,
                        "bookmarkId": bookmark_id,
                    },
                )
                return

            send_pushover(
                "\n".join(
                    [
                        f"대용량 분기 저장: {shorten_url(source_url)}",
                        "북마크: 링크 + 보관(fullPageArchive) 연결 완료",
                        f"Asset ID: {asset_id}",
                    ]
                ),
                0,
            )

            response_payload = {
                "status": "fullpage_archive_attached",
                "url": source_url,
                "assetId": asset_id,
                "bookmarkId": bookmark_id,
                "alreadyExists": already_exists,
                "ifexists": ifexists_mode,
                "removedCrawlerTasks": removed_tasks,
                "assetSizeBytes": file_size,
                "maxAssetSizeBytes": MAX_ASSET_SIZE_BYTES,
            }
            self.respond_json(200 if already_exists else 201, response_payload)
        except Exception as exc:  # noqa: BLE001
            log(f"bridge handler error: {exc}")
            self.respond_json(500, {"error": "internal server error"})
        finally:
            if temp_path:
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass


def main() -> None:
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), SingleFileBridgeHandler)

    def _shutdown(signum, _frame) -> None:
        log(f"received signal {signum}, shutting down...")
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    log(
        f"karakeep-singlefile-bridge listening on {LISTEN_HOST}:{LISTEN_PORT} "
        f"(max={MAX_ASSET_SIZE_MB}MB, mode=karakeep-fullpage-archive-attach)"
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
        log("karakeep-singlefile-bridge stopped")


if __name__ == "__main__":
    main()
