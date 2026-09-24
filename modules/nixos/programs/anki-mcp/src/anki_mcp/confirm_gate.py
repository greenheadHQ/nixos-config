"""Confirmation gate for clients whose hidden parallel responses can run writes (#1359).

ChatGPT Pro builds several candidate responses to one user message and shows only one.
A single candidate receives the write tools, and it is not always the one shown, so a
write could land while the visible answer says nothing happened. For OAuth clients whose
redirect URI host is configured here, every collection write first returns a preview and
applies only with an explicit confirmation.

One extra rule uses the W3C trace id: a confirmation carrying the trace id of the message
that produced the preview is refused, so a hidden response cannot preview and confirm on
its own. ChatGPT sends one trace id per user message, shared by every candidate of that
message (observed 2026-09-24; not a documented contract). Without a trace id, or without a
recorded preview (for example after a restart), the gate still requires the confirmation
but cannot tell messages apart; it says so in the preview and the log instead of blocking
writes. Preview traces live only in memory.

This is dialogue confirmation observed by the server, not independent human authentication.
"""

from __future__ import annotations

import logging
import re
import time
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

log = logging.getLogger("anki_mcp")

_TRACEPARENT = re.compile(r"00-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}")
# Used only when a prepared record lacks expires_at; journal previews always carry one.
_FALLBACK_TTL_SECS = 3600

GATE_POLICY = "separate-user-message"
UNTRACED_POLICY = "confirmation-required"
BLOCKED_REASON = "confirmation-requires-a-new-user-message"
_HUMAN = "This dialogue confirmation is not independent human authentication."
PREVIEW_STEP = (
    "Nothing was applied. This client confirms writes in a separate user message: show this preview, "
    "wait for the user's reply, then repeat the same request_id and preview_token with confirm=true. "
    "A confirmation sent in the same turn as the preview is rejected. " + _HUMAN)
UNTRACED_STEP = (
    "Nothing was applied. Show this preview and wait for the user's reply, then repeat the same "
    "request_id and preview_token with confirm=true. " + _HUMAN)
BLOCKED_STEP = (
    "Nothing was applied. The confirmation came from the same user message that produced the preview. "
    "Show the preview and confirm only after the user replies.")


@dataclass(frozen=True)
class Origin:
    """Whether the current request is gated, and its per-message trace id when known."""

    gated: bool
    trace_id: str | None


UNGATED = Origin(False, None)


def trace_id(traceparent: str | None) -> str | None:
    """Return the trace id of a version-00 W3C traceparent, or None if absent or invalid."""
    if not traceparent:
        return None
    match = _TRACEPARENT.fullmatch(traceparent.strip().lower())
    if match is None or set(match.group(1)) == {"0"}:
        return None
    return match.group(1)


def gated_client(redirect_uris: Iterable[Any] | None, hosts: Iterable[str]) -> bool:
    """True if any registered redirect URI points at a configured host."""
    wanted = {host.lower() for host in hosts}
    return any((urlsplit(str(uri)).hostname or "").lower() in wanted for uri in redirect_uris or ())


class ConfirmationGate:
    def __init__(self, resolve: Callable[[], Awaitable[Origin]], *, enabled: bool,
                 clock: Callable[[], float] = time.time) -> None:
        self._resolve, self.enabled, self._clock = resolve, enabled, clock
        self._previews: dict[str, tuple[str, float]] = {}

    async def origin(self) -> Origin:
        return await self._resolve() if self.enabled else UNGATED

    def _prune(self) -> None:
        now = self._clock()
        for key in [key for key, (_, until) in self._previews.items() if until < now]:
            del self._previews[key]

    def preview(self, operation: dict[str, Any], key: str, origin: Origin) -> dict[str, Any]:
        """Return the preview; remember the message that first produced it when its trace is known."""
        self._prune()
        if origin.trace_id is None:
            log.warning("write confirmation gate: request without a message trace; "
                        "same-message confirmations cannot be refused")
            return {**operation, "confirmation_required": True, "confirmation_policy": UNTRACED_POLICY,
                    "next_step": UNTRACED_STEP}
        if key not in self._previews:
            expires_at = operation.get("expires_at")
            until = (float(expires_at) if isinstance(expires_at, (int, float))
                     else self._clock() + _FALLBACK_TTL_SECS)
            self._previews[key] = (origin.trace_id, until)
        return {**operation, "confirmation_required": True, "confirmation_policy": GATE_POLICY,
                "next_step": PREVIEW_STEP}

    def refusal(self, operation: dict[str, Any], key: str, origin: Origin) -> dict[str, Any] | None:
        """Refuse a confirmation from the message that produced the preview; otherwise return None."""
        self._prune()
        seen = self._previews.get(key)
        if origin.trace_id is None:
            log.warning("write confirmation gate: confirmation without a message trace was allowed")
        if seen is None or origin.trace_id is None or seen[0] != origin.trace_id:
            return None
        return {**operation, "confirmation_required": True, "confirmation_policy": GATE_POLICY,
                "confirmation_blocked": BLOCKED_REASON, "next_step": BLOCKED_STEP}

    def forget(self, key: str) -> None:
        self._previews.pop(key, None)
