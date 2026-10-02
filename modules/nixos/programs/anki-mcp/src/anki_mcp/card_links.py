"""Card URLs and a public, read-only handoff to the local Anki app.

The relay only formats a validated ID. It never looks up a card, calls Anki or
the helper, or accepts a destination URL supplied by the caller.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import re
from datetime import datetime, timezone

from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import HTMLResponse, Response

log = logging.getLogger("anki_mcp.card_links")
MAX_CID = "9223372036854775807"


def valid_cid(cid: str) -> bool:
    """Accept only canonical positive signed-64-bit decimal IDs, without rounding."""
    return bool(re.fullmatch(r"[1-9][0-9]{0,18}", cid)) and (
        len(cid) < len(MAX_CID) or cid <= MAX_CID
    )


def card_url(card_id: object, public_url: str) -> str | None:
    """Use the configured public origin and an exact Anki integer; never coerce IDs."""
    if type(card_id) is not int or not 0 < card_id <= int(MAX_CID):
        return None
    return f"{public_url.rstrip('/')}/c/{card_id}"


STYLE = """
:root { color-scheme: light dark; font-family: system-ui, sans-serif; }
body { margin: 0; padding: 24px; background: light-dark(#f5f6f8, #17191d); }
main { max-width: 560px; margin: 8vh auto; line-height: 1.65; }
h1 { font-size: 1.7rem; line-height: 1.3; }
.actions { display: flex; flex-wrap: wrap; gap: 12px; margin: 24px 0; }
.actions a, button { border: 1px solid #77808c; border-radius: 10px; padding: 12px 18px;
  color: inherit; background: transparent; font: inherit; text-decoration: none; cursor: pointer; }
.actions .primary { color: white; background: #285cce; border-color: #285cce; }
code { overflow-wrap: anywhere; user-select: all; }
button:focus-visible, a:focus-visible { outline: 3px solid #83a8ff; outline-offset: 3px; }
li { margin-block: 8px; }
"""

SCRIPT = """
(() => {
  const page = document.getElementById("card-link");
  if (page.dataset.initialized === "yes") return;
  page.dataset.initialized = "yes";
  const cid = page.dataset.cid; // Keep the exact decimal string, including values above 2^53.
  const copyStatus = document.getElementById("copy-status");
  document.getElementById("copy").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText("cid:" + cid);
      copyStatus.textContent = "검색어를 복사했습니다.";
    } catch (_) {
      copyStatus.textContent = "자동 복사를 사용할 수 없습니다. 위 검색어를 직접 선택해 복사하세요.";
    }
  });
  const ua = navigator.userAgent || "";
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const mac = !ios && /Macintosh/.test(ua);
  const target = ios ? document.getElementById("ios") : mac ? document.getElementById("mac") : null;
  if (target) {
    target.classList.add("primary");
    document.getElementById("detected").textContent = ios ? "iPhone·iPad용 링크를 준비했습니다." : "Mac용 링크를 준비했습니다.";
    // One attempt only. A timer cannot tell whether an app or a confirmation dialog opened.
    try { window.location.replace(target.href); } catch (_) { /* The visible links remain usable. */ }
  }
})();
"""


def _hash(value: str) -> str:
    return base64.b64encode(hashlib.sha256(value.encode()).digest()).decode()


HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex",
    "Content-Security-Policy": (
        "default-src 'none'; "
        f"script-src 'sha256-{_hash(SCRIPT)}'; style-src 'sha256-{_hash(STYLE)}'; "
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
}


def render_page(cid: str) -> str:
    if not valid_cid(cid):
        raise ValueError("invalid card ID")
    return f"""<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Anki에서 카드 열기</title>
<style>{STYLE}</style></head><body>
<main id="card-link" data-cid="{cid}">
<h1>Anki에서 카드 열기</h1>
<p id="detected">이 기기에 맞는 앱을 선택하세요.</p>
<p>자동으로 열리지 않으면 아래 버튼을 누르세요.</p>
<div class="actions"><a id="ios" href="anki://x-callback-url/search?query=cid%3A{cid}">iPhone·iPad에서 열기</a>
<a id="mac" href="hammerspoon://anki-browse?cid={cid}">Mac에서 열기</a></div>
<p>카드 번호: <code>{cid}</code><br>검색어: <code>cid:{cid}</code></p>
<button id="copy" type="button">검색어 복사</button><p id="copy-status" role="status" aria-live="polite"></p>
<h2>열리지 않으면</h2><ul>
<li>iPhone·iPad에는 AnkiMobile이 필요합니다. Mac은 Hammerspoon이 실행 중이어야 하며 Anki 열기 기능이 설정되어 있어야 합니다.</li>
<li>Mac에서 반응이 없으면 Hammerspoon을 실행한 뒤 위 버튼을 다시 누르세요.</li>
<li>카드가 나오지 않으면 해당 기기의 동기화 상태를 확인하세요. 이 페이지는 동기화하지 않습니다.</li>
<li>앱 안 브라우저라면 이 페이지를 Safari나 기본 브라우저에서 다시 여세요.</li>
<li>검색어를 복사해 Anki에서 찾거나 <a href="https://ankiweb.net/search" rel="noreferrer">AnkiWeb 검색 페이지</a>에서 직접 검색하세요.</li>
</ul><noscript><p>자동 이동과 복사를 사용할 수 없습니다. 위 앱 링크를 누르거나 검색어를 직접 복사하세요.</p></noscript>
</main><script>{SCRIPT}</script></body></html>"""


def register_card_links(mcp: FastMCP) -> None:
    async def card_link(request: Request) -> Response:
        # Starlette adds HEAD automatically for GET routes; only GET is supported here.
        if request.method != "GET":
            return Response(status_code=405, headers={**HEADERS, "Allow": "GET"})
        cid = request.path_params.get("cid", "")
        if request.scope.get("query_string") or not valid_cid(cid) or request.scope["path"] != f"/c/{cid}":
            return Response(status_code=404, headers=HEADERS)
        # No IP, URL, card ID or card content. Escape a hostile UA to keep each visit on one line.
        log.info("card_link_visit %s", json.dumps({
            "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "user_agent": request.headers.get("user-agent", "")[:1024],
        }, ensure_ascii=True))
        return HTMLResponse(render_page(cid), headers=HEADERS)

    # Capture extra path segments so they fail validation without a redirect.
    mcp.custom_route("/c/{cid:path}", methods=["GET"], include_in_schema=False)(card_link)
    mcp.custom_route("/c", methods=["GET"], include_in_schema=False)(card_link)
