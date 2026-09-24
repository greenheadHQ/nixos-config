"""Confirmation gate for clients whose hidden parallel responses can run writes (#1359).

ChatGPT Pro builds several candidate responses to one user message and shows only one.
A single candidate receives the write tools, and it is not always the one shown, so a
write could land while the visible answer says nothing happened. For OAuth clients whose
redirect URI host is configured here, every collection write first returns a preview and
applies only when the confirmation arrives from a later user message.

ChatGPT sends one W3C trace id per user message, shared by every candidate of that message
(observed 2026-09-24; not a documented contract). A confirmation carrying the trace id that
produced the preview is rejected. A missing or malformed trace id blocks the confirmation
instead of waiving the check. Preview traces live only in memory: after a restart the first
confirmation records its own trace and asks for one more user message.

This is dialogue confirmation observed by the server, not independent human authentication.
"""

from __future__ import annotations

import re
import time
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

_TRACEPARENT = re.compile(r"00-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}")
# Used only when a prepared record lacks expires_at; journal previews always carry one.
_FALLBACK_TTL_SECS = 3600

GATE_POLICY = "separate-user-message"
PREVIEW_STEP = (
    "Nothing was applied. This client confirms writes in a separate user message: show this preview, "
    "wait for the user's reply, then repeat the same request_id and preview_token with confirm=true. "
    "A confirmation sent in the same turn as the preview is rejected. "
    "This dialogue confirmation is not independent human authentication.")
BLOCKED_STEPS = {
    "confirmation-requires-a-new-user-message": (
        "Nothing was applied. The confirmation came from the same user message that produced the preview. "
        "Show the preview and confirm only after the user replies."),
    "confirmation-preview-not-recorded": (
        "Nothing was applied. The server had no record of this preview (for example after a restart) and "
        "recorded it now. Show the preview and confirm again after the user's next message."),
    "confirmation-trace-unavailable": (
        "Nothing was applied. The request carried no message trace, so a separate confirmation cannot be "
        "verified. Report this to the operator instead of retrying with a new request_id."),
}


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

    def _expiry(self, expires_at: Any) -> float:
        return float(expires_at) if isinstance(expires_at, (int, float)) else self._clock() + _FALLBACK_TTL_SECS

    def _prune(self) -> None:
        now = self._clock()
        for key in [key for key, (_, until) in self._previews.items() if until < now]:
            del self._previews[key]

    def note_preview(self, key: str, origin: Origin, expires_at: Any) -> None:
        """Remember the message that first produced this preview; later previews keep the first trace."""
        self._prune()
        if origin.trace_id and key not in self._previews:
            self._previews[key] = (origin.trace_id, self._expiry(expires_at))

    def blocked(self, key: str, origin: Origin, expires_at: Any) -> str | None:
        """Return why a confirmation must not apply now, or None when it comes from a later message."""
        self._prune()
        if origin.trace_id is None:
            return "confirmation-trace-unavailable"
        seen = self._previews.get(key)
        if seen is None:
            self._previews[key] = (origin.trace_id, self._expiry(expires_at))
            return "confirmation-preview-not-recorded"
        if seen[0] == origin.trace_id:
            return "confirmation-requires-a-new-user-message"
        return None

    def forget(self, key: str) -> None:
        self._previews.pop(key, None)

    def preview(self, operation: dict[str, Any], key: str, origin: Origin) -> dict[str, Any]:
        self.note_preview(key, origin, operation.get("expires_at"))
        return {**operation, "confirmation_required": True, "confirmation_policy": GATE_POLICY,
                "next_step": PREVIEW_STEP}

    def refusal(self, operation: dict[str, Any], reason: str) -> dict[str, Any]:
        return {**operation, "confirmation_required": True, "confirmation_policy": GATE_POLICY,
                "confirmation_blocked": reason, "next_step": BLOCKED_STEPS[reason]}
