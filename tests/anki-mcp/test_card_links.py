"""Offline relay checks: no native app or real network is opened."""

import base64
import hashlib
import json
import logging
import re
import subprocess
from html.parser import HTMLParser

import httpx
import pytest
from mcp.server.fastmcp import FastMCP

from anki_mcp.card_links import HEADERS, SCRIPT, register_card_links, card_url, render_page, valid_cid
from anki_mcp.server import build
from test_server import _settings


@pytest.mark.parametrize("cid", ["1", "9007199254740993", "9223372036854775807"])
def test_exact_decimal_ids(cid):
    assert valid_cid(cid)
    assert card_url(int(cid), "https://anki.example/") == f"https://anki.example/c/{cid}"
    html = render_page(cid)
    assert f'data-cid="{cid}"' in html
    assert f'anki://x-callback-url/search?query=cid%3A{cid}' in html
    assert f'hammerspoon://anki-browse?cid={cid}' in html


@pytest.mark.parametrize("cid", [
    "", "0", "01", "-1", "+1", " 1", "1 ", "1\n", "1.0", "1e3", "١", "１",
    "1/2", "1?query=deck:all", "9223372036854775808", "10000000000000000000",
])
def test_invalid_ids(cid):
    assert not valid_cid(cid)
    with pytest.raises(ValueError, match="invalid card ID"):
        render_page(cid)


@pytest.mark.parametrize("cid", [None, True, False, 0, -1, 1.0, "1", 9223372036854775808])
def test_url_builder_rejects_non_integer_or_out_of_range_ids(cid):
    assert card_url(cid, "https://anki.example") is None


class _Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.external = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids
            self.ids.add(attrs["id"])
        if tag == "a":
            self.links.append(attrs["href"])
        if "src" in attrs or (tag == "link" and "href" in attrs):
            self.external.append(attrs)


def test_static_fallback_and_exact_csp_hashes():
    html = render_page("9007199254740993")
    page = _Page()
    page.feed(html)
    assert page.links == [
        "anki://x-callback-url/search?query=cid%3A9007199254740993",
        "hammerspoon://anki-browse?cid=9007199254740993",
        "https://ankiweb.net/search",
    ]
    assert not page.external
    assert "<noscript>" in html and "Safari" in html and "동기화" in html
    for tag in ("script", "style"):
        content = re.search(fr"<{tag}>(.*?)</{tag}>", html, re.S).group(1)
        digest = base64.b64encode(hashlib.sha256(content.encode()).digest()).decode()
        assert f"{tag}-src 'sha256-{digest}'" in HEADERS["Content-Security-Policy"]
    assert "unsafe-inline" not in HEADERS["Content-Security-Policy"]


@pytest.mark.anyio
async def test_public_route_is_separate_from_approval_and_never_calls_services(tmp_path, monkeypatch, caplog):
    async def forbidden(*args, **kwargs):
        pytest.fail("the relay attempted an Anki/helper request")

    monkeypatch.setattr("anki_mcp.ankiconnect.AnkiConnect.invoke", forbidden)
    monkeypatch.setattr("anki_mcp.helper.Helper.post", forbidden)
    public, approval = build(_settings(tmp_path))
    cid = "9007199254740993"
    with caplog.at_level(logging.INFO, logger="anki_mcp.card_links"):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=public), base_url="https://test") as client:
            response = await client.get(f"/c/{cid}", headers={"User-Agent": "Card-Link-UA"})
            assert response.status_code == 200
            for name, value in HEADERS.items():
                assert response.headers[name] == value
            assert (await client.post("/mcp", json={})).status_code == 401
            for path in ("/c", "/c/", "/c/0", "/c/01", "/c/1/", "/c/1/more", "/c/9223372036854775808",
                         "/c/1?next=https://example.org", "/c/1?query=cid:2", "/c/%EF%BC%91", "/c/1%0A"):
                rejected = await client.get(path, follow_redirects=False)
                assert rejected.status_code == 404, path
                assert "location" not in rejected.headers
            for method in ("POST", "PUT", "DELETE", "HEAD"):
                assert (await client.request(method, "/c/1")).status_code == 405
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=approval), base_url="https://test") as client:
            assert (await client.get("/c/1")).status_code == 404
    events = [record.getMessage() for record in caplog.records if record.name == "anki_mcp.card_links"]
    assert len(events) == 1
    assert cid not in events[0] and "/c/" not in events[0]
    payload = json.loads(events[0].removeprefix("card_link_visit "))
    assert set(payload) == {"time", "user_agent"}
    assert payload["user_agent"] == "Card-Link-UA"


@pytest.mark.anyio
async def test_registering_relay_keeps_tool_catalog_unchanged():
    mcp = FastMCP("card-link-test")

    @mcp.tool()
    def example(value: str) -> str:
        """Unchanged example tool."""
        return value

    before = [tool.model_dump() for tool in await mcp.list_tools()]
    register_card_links(mcp)
    assert [tool.model_dump() for tool in await mcp.list_tools()] == before


@pytest.mark.parametrize("ua,touch,target", [
    ("iPhone", 5, "ios"), ("iPad", 5, "ios"), ("iPod", 5, "ios"),
    ("Macintosh", 5, "ios"), ("Macintosh", 0, "mac"), ("Android", 5, None), ("", 0, None),
])
def test_actual_page_script_attempts_only_once_and_keeps_manual_fallback(ua, touch, target):
    # Run the shipped script with a fake DOM/location. No browser or native scheme opens.
    harness = r"""
const vm = require('node:vm');
const assert = require('node:assert/strict');
const config = JSON.parse(process.argv[1]);
const nodes = {};
for (const id of ['card-link', 'copy', 'copy-status', 'ios', 'mac', 'detected']) {
  nodes[id] = { dataset: {}, textContent: '', events: {}, classes: [],
    classList: { add(value) { nodes[id].classes.push(value); } },
    addEventListener(name, fn) { this.events[name] = fn; } };
}
nodes['card-link'].dataset.cid = '9007199254740993';
nodes.ios.href = 'anki://x-callback-url/search?query=cid%3A9007199254740993';
nodes.mac.href = 'hammerspoon://anki-browse?cid=9007199254740993';
const destinations = [], copies = [];
const context = vm.createContext({
  document: { getElementById(id) { assert.ok(nodes[id]); return nodes[id]; } },
  navigator: { userAgent: config.ua, maxTouchPoints: config.touch,
    clipboard: { async writeText(text) { copies.push(text); } } },
  window: { location: { replace(url) { destinations.push(url); } } },
});
vm.runInContext(config.script, context);
vm.runInContext(config.script, context);
assert.deepEqual(destinations, config.target ? [nodes[config.target].href] : []);
assert.deepEqual(nodes.ios.classes, config.target === 'ios' ? ['primary'] : []);
assert.deepEqual(nodes.mac.classes, config.target === 'mac' ? ['primary'] : []);
(async () => {
  await nodes.copy.events.click();
  assert.deepEqual(copies, ['cid:9007199254740993']);
  assert.match(nodes['copy-status'].textContent, /복사했습니다/);
  context.navigator.clipboard = undefined;
  await nodes.copy.events.click();
  assert.match(nodes['copy-status'].textContent, /직접 선택/);
  assert.equal(destinations.length, config.target ? 1 : 0);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
    completed = subprocess.run(["node", "-e", harness, json.dumps({
        "ua": ua, "touch": touch, "target": target, "script": SCRIPT,
    })], capture_output=True, text=True, timeout=10)
    assert completed.returncode == 0, completed.stderr
