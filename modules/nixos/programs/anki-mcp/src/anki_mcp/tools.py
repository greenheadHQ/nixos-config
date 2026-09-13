"""Authenticated reads and journaled mutations for a personal Anki host.

Mutations use OperationService for fresh pre/post sync and durable outcomes.
Destructive, bulk, shared-preset and structural changes require previews; schema
changes are prepared here and executed only through root's approval workflow.
Client annotations supplement the server's own confirmation checks.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal
import base64
import binascii
import unicodedata

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import BaseModel, Field

from .ankiconnect import AnkiConnect
from .authoring import AUTHORING_GUIDANCE
from .helper import Helper
from .operations import OperationService
from .shaping import card_view, note_view, page, truncate
from .syncstatus import SyncNow, read_status, summarize

ADDED_TAG = "mcp::added"


def check_tags(tags: list[str]) -> list[str]:
    """Anki는 태그를 공백으로 구분한다 — 'foo bar'는 태그 두 개가 되고 빈 태그는 무시된다. 요청 전에 거부한다."""
    bad = [t for t in tags if not t or any(ch.isspace() for ch in t)]
    if bad:
        raise ToolError(f"tags must be non-empty and contain no whitespace: {bad!r}")
    return tags

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
ADDITIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
UPDATE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)
DESTRUCTIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False)
SYNC = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=True)


class NewNote(BaseModel):
    deck_name: str = Field(description="Target deck (existing; use anki_create_deck first if needed)")
    model_name: str = Field(description="Note type name, e.g. 'Basic' or 'Cloze' (see anki_models)")
    fields: dict[str, str] = Field(description="Field values by field name; HTML allowed")
    tags: list[str] = Field(default_factory=list, description="Tags to add; 'mcp::added' is always appended")


@dataclass
class Deps:
    anki: AnkiConnect
    helper: Helper
    syncer: SyncNow
    sync_status_file: str
    field_chars: int
    page_max: int
    operations: OperationService
    media_max_bytes: int


def register_tools(mcp: FastMCP, deps: Deps) -> None:  # noqa: C901 — 도구 정의 나열
    anki = deps.anki

    operations = deps.operations

    @mcp.tool(name="anki_status", annotations=READ_ONLY)
    async def anki_status() -> dict[str, Any]:
        """Host status: helper readiness/login/busy, last sync summary (result vocabulary of the sync script),
        and today's review count. Call this first when something looks off."""
        helper = await deps.helper.status()
        reviewed_today = await anki.invoke("getNumCardsReviewedToday")
        return {
            "helper": {k: helper.get(k) for k in ("collection_open", "login", "busy", "addon_version", "last_sync")},
            "sync": summarize(read_status(deps.sync_status_file)),
            "reviewed_today": reviewed_today,
        }

    @mcp.tool(name="anki_decks", annotations=READ_ONLY)
    async def anki_decks() -> dict[str, Any]:
        """List decks with ids and per-deck counts (new/learn/review due today, total cards)."""
        names: dict[str, int] = await anki.invoke("deckNamesAndIds")
        stats: dict[str, dict[str, Any]] = await anki.invoke("getDeckStats", decks=list(names))
        by_id = {str(v.get("deck_id")): v for v in stats.values()}
        decks = []
        for name, deck_id in sorted(names.items()):
            s = by_id.get(str(deck_id), {})
            decks.append({
                "name": name,
                "id": deck_id,
                "new": s.get("new_count"),
                "learn": s.get("learn_count"),
                "review": s.get("review_count"),
                "total": s.get("total_in_deck"),
            })
        return {"decks": decks}

    @mcp.tool(name="anki_models", annotations=READ_ONLY)
    async def anki_models(name: str | None = None) -> dict[str, Any]:
        """List note types. With `name`, return that type's field names (in order) and card template names."""
        if name is None:
            return {"models": await anki.invoke("modelNames")}
        fields = await anki.invoke("modelFieldNames", modelName=name)
        templates = await anki.invoke("modelTemplates", modelName=name)
        return {"model": name, "fields": fields, "templates": list(templates.keys())}

    @mcp.tool(name="anki_find_notes", annotations=READ_ONLY)
    async def anki_find_notes(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_field_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search notes with Anki search syntax passed through verbatim (e.g. 'deck:"CS 재활" tag:mcp::added',
        'added:7', 'is:due', 'front:*css*'). Paginated; field values are truncated to max_field_chars
        (0 = no truncation). Use anki_note_info for full fields of specific notes."""
        ids: list[int] = await anki.invoke("findNotes", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"query": query, "page": meta, "notes": [note_view(n, max_field_chars) for n in notes]}

    @mcp.tool(name="anki_note_info", annotations=READ_ONLY)
    async def anki_note_info(note_ids: list[int], max_field_chars: int = 0) -> dict[str, Any]:
        """Full note details for the given note ids (fields untruncated by default)."""
        chunk, meta = page(note_ids, deps.page_max, 0, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"page": meta, "notes": [note_view(n, max_field_chars) for n in notes]}

    @mcp.tool(name="anki_find_cards", annotations=READ_ONLY)
    async def anki_find_cards(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search cards (scheduling view: queue/type/due/interval/ease/reps/lapses) with Anki search syntax.
        Rendered question/answer are truncated to max_chars."""
        ids: list[int] = await anki.invoke("findCards", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        cards = await anki.invoke("cardsInfo", cards=chunk) if chunk else []
        return {"query": query, "page": meta, "cards": [card_view(c, max_chars) for c in cards]}

    @mcp.tool(name="anki_card_reviews", annotations=READ_ONLY)
    async def anki_card_reviews(card_ids: list[int]) -> dict[str, Any]:
        """Review history (revlog) keyed by card id. Each entry: {id: review time (epoch ms), usn, ease: button 1-4,
        ivl: new interval (days; negative = seconds), lastIvl, factor: ease factor (permille), time: ms spent,
        type: 0 learn / 1 review / 2 relearn / 3 filtered / 4 manual}."""
        chunk, meta = page(card_ids, deps.page_max, 0, deps.page_max)
        # AnkiConnect는 revlog.cid를 정수로 비교한다 — 문자열 id를 보내면 빈 결과가 온다
        reviews = await anki.invoke("getReviewsOfCards", cards=chunk) if chunk else {}
        return {"page": meta, "reviews": reviews}

    @mcp.tool(name="anki_tags", annotations=READ_ONLY)
    async def anki_tags() -> dict[str, Any]:
        """All tags in the collection."""
        return {"tags": await anki.invoke("getTags")}

    @mcp.tool(name="anki_add_notes", annotations=ADDITIVE, description=(
        "Add notes. Every note gets the 'mcp::added' tag so MCP-created cards stay identifiable. "
        "Duplicates (same first field in the deck) are rejected unless allow_duplicate. Returns an operation receipt "
        "with per-note outcomes in result.results (null noteId = unconfirmed/failed, see errors). "
        "Normal sync runs before and after writes. Reuse request_id "
        "for every retry. More than 20 affected notes/cards returns a preview requiring user confirmation.\n\n"
        + AUTHORING_GUIDANCE
    ))
    async def anki_add_notes(notes: list[NewNote], allow_duplicate: bool = False,
                             request_id: str | None = None, preview_token: str | None = None,
                             confirm: bool = False) -> dict[str, Any]:
        for n in notes:
            check_tags(n.tags)
        return await operations.run("add_notes", {"notes": [n.model_dump() for n in notes], "allow_duplicate": allow_duplicate},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_update_note_fields", annotations=UPDATE, description=(
        "Replace the given fields of a note (other fields unchanged). Card ids, scheduling and review "
        "history are preserved for existing cards. Changed templates/cloze fields may generate new cards. "
        "Returns an operation receipt; use anki_note_info for readback. Reuse request_id for retries.\n\n"
        + AUTHORING_GUIDANCE
    ))
    async def anki_update_note_fields(note_id: int, fields: dict[str, str], request_id: str | None = None,
                                     preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        return await operations.run("update_fields", {"note_id": note_id, "fields": fields},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_add_tags", annotations=UPDATE)
    async def anki_add_tags(note_ids: list[int], tags: list[str], request_id: str | None = None,
                            preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Add tags to notes (space-separated internally; each tag must not contain spaces)."""
        check_tags(tags)
        return await operations.run("add_tags", {"note_ids": note_ids, "tags": tags},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_remove_tags", annotations=UPDATE)
    async def anki_remove_tags(note_ids: list[int], tags: list[str], request_id: str | None = None,
                               preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Remove tags from notes (each tag must not contain spaces)."""
        check_tags(tags)
        return await operations.run("remove_tags", {"note_ids": note_ids, "tags": tags},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_create_deck", annotations=ADDITIVE)
    async def anki_create_deck(name: str, request_id: str | None = None,
                               preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Create a deck (use '::' for nesting). Existing decks are returned unchanged."""
        return await operations.run("create_deck", {"name": name},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_operation_status", annotations=READ_ONLY)
    async def anki_operation_status(operation_id: str) -> dict[str, Any]:
        """Read a durable operation receipt, including applied/partial/unknown and separate sync/notification states.
        Unknown is not a retry instruction. Never resubmit the mutation with a new request_id after a lost response."""
        return await operations.status(operation_id)

    @mcp.tool(name="anki_recent_operations", annotations=READ_ONLY)
    async def anki_recent_operations(limit: int = 20, offset: int = 0) -> dict[str, Any]:
        """List recent operation receipts (no note bodies). Use this to locate an operation after losing a
        response or its server-generated ID. Inspect the receipt before considering any retry."""
        return await deps.helper.post("/operations/history", {"limit": limit, "offset": offset})

    @mcp.tool(name="anki_move_cards", annotations=UPDATE)
    async def anki_move_cards(card_ids: list[int], deck_name: str, request_id: str | None = None,
                              preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Move cards into an existing ordinary deck. Preserve their scheduling/history; cards in filtered
        decks return to their original scheduling state first. More than 20 affected cards requires a preview."""
        return await operations.run("move_cards", {"card_ids": card_ids, "deck_name": deck_name},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_delete_notes", annotations=DESTRUCTIVE)
    async def anki_delete_notes(note_ids: list[int], request_id: str | None = None,
                                preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Preview deletion of notes, ALL their cards and review history. Always show the preview and get user
        confirmation, then repeat the same request_id/token with confirm=true. Requires a verified restore point."""
        return await operations.run("delete_notes", {"note_ids": note_ids},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_delete_decks", annotations=DESTRUCTIVE)
    async def anki_delete_decks(deck_names: list[str], request_id: str | None = None,
                                preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Preview deleting decks including subdecks and their affected cards. Filtered/Default deck behavior
        is explained in the preview. Always requires user confirmation and a verified restore point."""
        return await operations.run("delete_decks", {"deck_names": deck_names},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_suspend_cards", annotations=UPDATE)
    async def anki_suspend_cards(card_ids: list[int], suspended: bool = True, request_id: str | None = None,
                                 preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Suspend or unsuspend cards. More than 20 affected notes/cards requires confirmation and a restore point."""
        return await operations.run("suspend_cards", {"card_ids": card_ids, "suspended": suspended},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_set_due_date", annotations=DESTRUCTIVE)
    async def anki_set_due_date(card_ids: list[int], days: str, request_id: str | None = None,
                                preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Preview setting due dates: N or N-M days from today, optionally suffixed '!'. Ranges choose random
        dates; this can unsuspend cards and create manual review-log rows. Always requires confirmation/backup."""
        return await operations.run("set_due_date", {"card_ids": card_ids, "days": days},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_forget_cards", annotations=DESTRUCTIVE)
    async def anki_forget_cards(card_ids: list[int], request_id: str | None = None,
                                preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Preview resetting cards to new-card scheduling. Existing review history is retained; manual log
        rows may be added. Always requires user confirmation and a verified restore point."""
        return await operations.run("forget_cards", {"card_ids": card_ids},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_store_media", annotations=ADDITIVE)
    async def anki_store_media(filename: str, data: str, request_id: str | None = None) -> dict[str, Any]:
        """Add one new media file using a safe basename and base64 data (decoded limit 5 MiB). Same content is
        a no-op; different existing content is refused. No file paths, URLs, overwriting or deletion."""
        if (len(data) > 4 * ((deps.media_max_bytes + 2) // 3) or filename.startswith(".")
                or any(c in filename for c in "/\\:") or filename != filename.strip()
                or unicodedata.normalize("NFC", filename) != filename
                or any(unicodedata.category(c).startswith("C") for c in filename)):
            raise ToolError("invalid-media-filename-or-size")
        try:
            decoded = base64.b64decode(data, validate=True)
        except (ValueError, binascii.Error) as err:
            raise ToolError("invalid-base64") from err
        if not decoded or len(decoded) > deps.media_max_bytes:
            raise ToolError("media-empty-or-too-large")
        return await operations.run("store_media", {"filename": filename, "data": data}, request_id=request_id)

    @mcp.tool(name="anki_media", annotations=READ_ONLY)
    async def anki_media(filename: str | None = None, contains: str = "", limit: int = 20, offset: int = 0) -> dict[str, Any]:
        """List media by plain substring with pagination, or retrieve one safe filename as base64 (max 5 MiB)."""
        return await deps.helper.post("/media", {"filename": filename, "contains": contains, "limit": limit, "offset": offset})

    @mcp.tool(name="anki_deck_options", annotations=READ_ONLY)
    async def anki_deck_options(deck_name: str) -> dict[str, Any]:
        """Read the current preset, editable options and every deck sharing that preset."""
        return await deps.helper.post("/deck-options", {"deck_name": deck_name})

    @mcp.tool(name="anki_update_deck_options", annotations=UPDATE)
    async def anki_update_deck_options(deck_name: str, changes: dict[str, int | float], request_id: str | None = None,
                                       preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Patch only supported option keys returned by anki_deck_options (e.g. new.perDay, rev.perDay).
        Shared presets always require a preview, user confirmation and a verified restore point."""
        return await operations.run("update_deck_options", {"deck_name": deck_name, "changes": changes},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_model_info", annotations=READ_ONLY)
    async def anki_model_info(model_name: str) -> dict[str, Any]:
        """Read a note type's ordered fields, complete templates and CSS."""
        return await deps.helper.post("/model-info", {"model_name": model_name})

    @mcp.tool(name="anki_prepare_model_change", annotations=DESTRUCTIVE)
    async def anki_prepare_model_change(
        action: Literal["model_field_add", "model_field_remove", "model_field_rename", "model_field_reposition",
                        "model_template_add", "model_template_remove", "model_template_update"],
        params: dict[str, Any], request_id: str | None = None,
    ) -> dict[str, Any]:
        """Prepare (never apply) a note-type change requiring root approval and possibly full Upload. params:
        model_name plus field_name (add/remove), field_name+new_name (rename), field_name+index (reposition),
        template_name+front+back (add/update), or template_name (remove). Field add accepts optional index.
        Show the preview; the root anki-host-approve command verifies backup/counts and executes once."""
        return await operations.run(action, params, request_id=request_id)

    @mcp.tool(name="anki_update_model_css", annotations=UPDATE)
    async def anki_update_model_css(model_name: str, css: str, request_id: str | None = None,
                                    preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Replace note-type CSS (empty CSS is allowed). More than 20 affected cards requires confirmation/backup."""
        return await operations.run("model_css_update", {"model_name": model_name, "css": css},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_sync_now", annotations=SYNC)
    async def anki_sync_now() -> dict[str, Any]:
        """Sync the host collection with AnkiWeb now (normal merge only; never a full upload/download).
        Triggers the host's sync service and waits for that run's result. If a run is already in progress the
        request joins it and your latest changes ride the next run."""
        return await deps.syncer.run()

    # 절단 헬퍼를 명시적으로 노출하지는 않지만, 도구 설명이 참조하는 동작이 이 모듈에 있음을 표시
    _ = truncate
