"""Tests for the bounded in-flight-request drain on shutdown.

Before this drain existed, ThreadingHTTPServer's daemon connection threads
were simply cut off the instant the process exited: a request whose do_POST
was mid-flight (e.g. waiting on curl talking to Karakeep) got no response at
all, and any not-yet-sent Pushover failure notification was lost with it.

These tests drive the real do_POST path against a local stub standing in for
Karakeep (`fake_karakeep_upstream`), so "in flight" here means the bridge's
own request handler is actually running, not just that a connection is open.
All external calls stay on loopback; no request reaches api.pushover.net or
a real Karakeep instance.
"""
import http.client
import os
import signal
import socket
import time


def _build_singlefile_multipart_body(url: str, filename: str, html: bytes) -> tuple[bytes, str]:
    boundary = "----pytestsinglefileboundary"
    parts = [
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="url"\r\n\r\n'
            f"{url}\r\n"
        ).encode("utf-8"),
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            "Content-Type: text/html\r\n\r\n"
        ).encode("utf-8")
        + html
        + b"\r\n",
        f"--{boundary}--\r\n".encode("utf-8"),
    ]
    return b"".join(parts), boundary


def _post_singlefile(port: int, timeout: float) -> http.client.HTTPConnection:
    """Open a connection and send a complete, valid singlefile POST.

    Returns the still-open connection without reading a response, so the
    caller controls exactly when to call getresponse() (e.g. after sending a
    shutdown signal).
    """
    body, boundary = _build_singlefile_multipart_body(
        "https://example.com/drain-test", "archive.html", b"<html>drain test</html>"
    )
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    conn.request(
        "POST",
        "/api/v1/bookmarks/singlefile",
        body=body,
        headers={
            "Authorization": "Bearer test-token",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    return conn


def _fake_upstream_base_url(fake_karakeep_upstream) -> str:
    host, port = fake_karakeep_upstream.server_address
    return f"http://{host}:{port}"


def test_normal_post_round_trip_against_stub_upstream(spawn_bridge, fake_karakeep_upstream):
    """Regression: the happy-path request/response contract still works.

    Guards against the do_GET/do_POST -> _do_get/_do_post rename plus the
    SHUTDOWN_TRACKER.track() wrapper accidentally changing what a normal
    (non-shutdown) request returns.
    """
    fake_karakeep_upstream.RequestHandlerClass.delay_seconds = 0.0
    bridge = spawn_bridge({"KARAKEEP_BASE_URL": _fake_upstream_base_url(fake_karakeep_upstream)})

    conn = _post_singlefile(bridge.port, timeout=5)
    try:
        resp = conn.getresponse()
        assert resp.status == 201
        assert resp.read() == b'{"ok": true}'
    finally:
        conn.close()


def test_shutdown_waits_for_in_flight_request_to_finish(spawn_bridge, fake_karakeep_upstream, wait_or_fail):
    """An in-flight do_POST gets to finish and respond within the drain window,
    and shutdown proceeds promptly once it does — not just eventually.
    """
    fake_karakeep_upstream.RequestHandlerClass.delay_seconds = 1.0
    drain_timeout_sec = 5
    bridge = spawn_bridge(
        {
            "KARAKEEP_BASE_URL": _fake_upstream_base_url(fake_karakeep_upstream),
            "SINGLEFILE_BRIDGE_SHUTDOWN_DRAIN_SEC": str(drain_timeout_sec),
        }
    )

    conn = _post_singlefile(bridge.port, timeout=drain_timeout_sec + 10)
    try:
        # Give the request time to reach _do_post and start the curl call to
        # the (slow) stub before we signal shutdown, so it's genuinely
        # in-flight and not still sitting in the idle "waiting for a full
        # request" state that shutdown must NOT wait on.
        time.sleep(0.3)
        signal_sent_at = time.monotonic()
        bridge.proc.send_signal(signal.SIGTERM)

        resp = conn.getresponse()
        assert resp.status == 201
        assert resp.read() == b'{"ok": true}'
    finally:
        conn.close()

    rc = wait_or_fail(
        bridge.proc,
        drain_timeout_sec + 5,
        "bridge did not exit after its in-flight request finished within the drain window",
    )
    elapsed = time.monotonic() - signal_sent_at
    assert rc == 0

    out = bridge.proc.stdout.read() if bridge.proc.stdout else ""
    assert "in-flight requests drained before shutdown" in out

    # The stub only holds do_POST busy for ~1s; ShutdownTracker.wait_for_drain
    # must wake up as soon as that finishes (via _exit()'s notify_all()), not
    # merely by falling through to the (much larger) drain_timeout_sec once
    # its own internal polling happens to time out. 3s sits comfortably
    # between "the ~1s this should actually take" and "the 5s deadline it
    # would take without notify_all()" — a mutant that drops notify_all()
    # still eventually reports "drained" (Condition.wait_for's own timeout
    # elapsing re-checks the predicate), just ~5s later than it should.
    assert elapsed < 3.0, (
        f"took {elapsed:.2f}s to exit after signaling; ShutdownTracker._exit()'s notify_all() "
        "may be missing (fell through to the drain deadline instead of waking up promptly)"
    )


def test_shutdown_exits_after_drain_deadline_with_a_slow_request(spawn_bridge, fake_karakeep_upstream, wait_or_fail):
    """A request slower than the drain deadline does not extend shutdown past it.

    This is the guard against re-introducing the original problem by a
    different route: draining must be a bounded ceiling, not a wait that
    can itself run arbitrarily long.
    """
    fake_karakeep_upstream.RequestHandlerClass.delay_seconds = 5.0
    drain_timeout_sec = 1
    bridge = spawn_bridge(
        {
            "KARAKEEP_BASE_URL": _fake_upstream_base_url(fake_karakeep_upstream),
            "SINGLEFILE_BRIDGE_SHUTDOWN_DRAIN_SEC": str(drain_timeout_sec),
        }
    )

    conn = _post_singlefile(bridge.port, timeout=drain_timeout_sec + 10)
    try:
        time.sleep(0.3)
        bridge.proc.send_signal(signal.SIGTERM)

        rc = wait_or_fail(
            bridge.proc,
            drain_timeout_sec + 5,
            "bridge did not exit within the drain deadline despite a slower-than-deadline request",
        )
        assert rc == 0
    finally:
        conn.close()

    out = bridge.proc.stdout.read() if bridge.proc.stdout else ""
    assert f"shutdown drain deadline ({drain_timeout_sec}s) reached" in out
    assert "exiting anyway" in out


def test_shutdown_still_ignores_idle_connections_without_a_full_request(
    spawn_bridge, fake_karakeep_upstream, wait_or_fail
):
    """An open-but-idle connection (no full request sent) is never drained.

    This pins the boundary of the fix: only handler calls that are actually
    running are waited on. A connection that merely opened a socket and sent
    a partial request line must not be able to extend shutdown at all, let
    alone up to the drain deadline.
    """
    drain_timeout_sec = 10  # deliberately generous; the assertion is on speed
    bridge = spawn_bridge(
        {
            "KARAKEEP_BASE_URL": _fake_upstream_base_url(fake_karakeep_upstream),
            "SINGLEFILE_BRIDGE_SHUTDOWN_DRAIN_SEC": str(drain_timeout_sec),
        }
    )

    lingering = socket.create_connection(("127.0.0.1", bridge.port), timeout=5)
    try:
        lingering.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n")  # headers incomplete on purpose
        # Give the server's accept loop time to actually accept() this
        # connection and spawn its handler thread before we signal shutdown
        # — same margin the other drain tests use to make sure their
        # request is genuinely past the "not yet accepted" state.
        time.sleep(0.3)

        bridge.proc.send_signal(signal.SIGTERM)
        rc = wait_or_fail(
            bridge.proc,
            3,  # far below drain_timeout_sec: an idle connection must not eat into it
            "bridge waited on an idle connection instead of ignoring it",
        )
        assert rc == 0
    finally:
        lingering.close()

    out = bridge.proc.stdout.read() if bridge.proc.stdout else ""
    assert "in-flight requests drained before shutdown" in out


def test_group_wide_sigterm_kills_the_in_flight_curl_child_drain_relies_on(
    spawn_bridge, fake_karakeep_upstream, wait_or_fail
):
    """Pins the reasoning behind KillMode=mixed in karakeep-singlefile-bridge.nix.

    _do_post's drain window is meant to let an in-flight request finish and
    respond, but that only works if the curl child it spawns to talk to
    Karakeep survives the signal. A group-wide SIGTERM — what systemd's
    default KillMode=control-group sends on stop — reaches that curl child
    too (it inherits the bridge's process group), killing it mid-request.
    The client then gets curl's failure instead of the response the drain
    was supposed to let it wait for.

    Simulated here with os.killpg(bridge.proc.pid, ...), using the process
    group spawn_bridge's subprocess already gets from start_new_session=True
    — not by actually setting KillMode, which needs systemd and is out of
    reach for a subprocess test. Contrast with
    test_shutdown_waits_for_in_flight_request_to_finish above, which sends
    the signal with plain proc.send_signal (main process only, the shape
    KillMode=mixed keeps) and gets a normal 201 back. This test does not
    verify the KillMode setting itself — Test KB2 in tests/eval-tests.nix
    pins that — it only pins the behavioral gap between the two signal
    shapes that setting decides between.
    """
    fake_karakeep_upstream.RequestHandlerClass.delay_seconds = 2.0
    bridge = spawn_bridge({"KARAKEEP_BASE_URL": _fake_upstream_base_url(fake_karakeep_upstream)})

    conn = _post_singlefile(bridge.port, timeout=10)
    try:
        # Same margin as the other drain tests: give the request time to
        # reach _do_post and spawn its curl child before signaling.
        time.sleep(0.3)
        os.killpg(bridge.proc.pid, signal.SIGTERM)

        resp = conn.getresponse()
        assert resp.status == 502
        assert resp.read() == b'{"error": "curl failed: "}'
    finally:
        conn.close()

    rc = wait_or_fail(
        bridge.proc,
        5,
        "bridge did not exit after a group-wide SIGTERM killed its in-flight curl child",
    )
    assert rc == 0

    out = bridge.proc.stdout.read() if bridge.proc.stdout else ""
    assert "in-flight requests drained before shutdown" in out
