"""Authenticated reads and journaled mutations for a personal Anki host.

Mutations use OperationService for fresh pre/post sync and durable outcomes.
Destructive, bulk, shared-preset and structural changes require previews; schema
changes are prepared here and executed only through root's approval workflow.
Client annotations supplement the server's own confirmation checks.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated, Any, Literal
import base64
import binascii
import unicodedata

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import BaseModel, ConfigDict, Field

from .ankiconnect import AnkiConnect
from .authoring import AUTHORING_GUIDANCE
from .helper import Helper
from .managed import DEFAULT_MODEL, ManagedService
from .operations import OperationService
from .shaping import card_view, note_view, page, truncate
from .syncstatus import SyncNow, read_freshness, read_status, summarize
from .upload import (FORMATS, RESIZE_LONG_EDGE, TICKET_TOOL, UPLOAD_PATH, WIDGET_MIME, WIDGET_URI, UploadTickets,
                     origin, widget_html)

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
MANAGED_RESTORE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=True, openWorldHint=True)
# The upload box and its ticket write nothing themselves: storing happens only when the user picks a file.
UPLOAD_BOX = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=False, openWorldHint=False)

UPLOAD_IMAGE_DESCRIPTION = (
    "Show an upload box where the user picks one image on their device; the server stores it in Anki media as sent "
    "(JPEG, PNG, GIF or WebP up to 5 MiB; the box resizes larger JPEG/PNG/WebP photos to a 3072 px long edge). "
    "Use this for images on the user's device, including images already attached to the chat: chat attachments "
    "cannot be passed to this server, so ask the user to pick the same file in the box. The box reports the stored "
    "filename (paste-<SHA-1>.<ext>) in the conversation; reference it in a field as <img src=\"FILENAME\">. "
    "If the user sees no upload box, this app cannot show MCP Apps widgets."
)
UPLOAD_RESULT_TEXT = (
    "The upload box is shown to the user. Wait until the user picks an image; the box stores it and reports the "
    "stored filename in the conversation. If the user sees no upload box, this app cannot show MCP Apps widgets: "
    "use anki_store_media only for a small file, or the user can add the image in Anki directly."
)


class NewNote(BaseModel):
    deck_name: str = Field(description="Target deck (existing; use anki_create_deck first if needed)")
    model_name: str = Field(description="Note type name, e.g. 'Basic' or 'Cloze' (see anki_models)")
    fields: dict[str, str] = Field(description="Field values by field name; HTML allowed")
    tags: list[str] = Field(default_factory=list, description="Tags to add; 'mcp::added' is always appended")


class NoteFieldUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    note_id: Annotated[int, Field(strict=True, gt=0)]
    fields: dict[str, str] = Field(min_length=1, description="Only fields to replace; other fields remain unchanged")
    expected_fields: dict[str, str] | None = Field(
        default=None,
        description="Optional exact old values for the same field names; stale values reject the whole operation",
    )


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
    public_url: str  # the upload box posts to <public_url>/upload and declares this origin in its CSP
    uploads: UploadTickets


def register_tools(mcp: FastMCP, deps: Deps) -> None:  # noqa: C901 — 도구 정의 나열
    """Register Anki tools with their dependencies and client-facing usage guidance."""
    anki = deps.anki

    operations = deps.operations
    managed = ManagedService(deps.helper, deps.syncer, sync_enabled=operations.sync_enabled, lock=operations.lock)

    @mcp.tool(name="anki_status", annotations=READ_ONLY)
    async def anki_status() -> dict[str, Any]:
        """Host status: helper readiness/login/busy, last sync summary (result vocabulary of the sync script),
        and today's review-log count. reviewed_today and sync counts_after.today_reviews count log rows,
        including deleted cards and manual scheduling entries, not unique cards or only answered reviews.
        Call this first when something looks off."""
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
        freshness = read_freshness(deps.sync_status_file)
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
        return {"decks": decks, "freshness": freshness}

    @mcp.tool(name="anki_models", annotations=READ_ONLY)
    async def anki_models(name: str | None = None) -> dict[str, Any]:
        """List note types. With `name`, return that type's field names (in order) and card template names.
        Only CS 재활 Basic is initially managed; other types are unmanaged, not automatically registered.
        Use anki_managed_model_check for the applied baseline, observed drift and separate pending updates."""
        freshness = read_freshness(deps.sync_status_file)
        if name is None:
            return {"models": await anki.invoke("modelNames"), "freshness": freshness}
        fields = await anki.invoke("modelFieldNames", modelName=name)
        templates = await anki.invoke("modelTemplates", modelName=name)
        return {"model": name, "fields": fields, "templates": list(templates.keys()), "freshness": freshness}

    @mcp.tool(name="anki_managed_model_check", annotations=READ_ONLY)
    async def anki_managed_model_check(
        model_name: Annotated[str, Field(strict=True, min_length=1)] = DEFAULT_MODEL,
    ) -> dict[str, Any]:
        """Check a managed note type and registered JS/CSS against the host's last applied-and-verified bundle.
        Return normal, drift, unavailable or unmanaged, changed items, baseline version and observed/sync times.
        A Git update pending is separate from drift; GitHub being unavailable does not invalidate a locally
        stored baseline. Unuploaded Mac/iPhone edits may be absent: this is host evidence, not all-device proof.
        Drift/unavailable blocks MCP note creation and field writes for that type, including mixed batches;
        reads, other types and the user's app review/editing remain available. Show the differences and ask
        whether to restore the verified baseline or review app changes for Git adoption. Never automatically
        restore or adopt. Only CS 재활 Basic is initially managed. Detailed snapshots remain private."""
        return await deps.helper.post("/managed/check", {"model_name": model_name})

    @mcp.tool(name="anki_managed_model_history", annotations=READ_ONLY)
    async def anki_managed_model_history(
        model_name: Annotated[str, Field(strict=True, min_length=1)] = DEFAULT_MODEL,
        limit: Annotated[int, Field(strict=True, ge=1, le=100)] = 20,
        offset: Annotated[int, Field(strict=True, ge=0)] = 0,
    ) -> dict[str, Any]:
        """Read paginated private drift incidents, baseline/last-good/first-observed times, changed items,
        notification outcomes and resolution. First observed is not the edit time; do not infer an actor/device.
        Unresolved incidents remain retained; resolved detail is retained for 90 days after resolution.
        Do not automatically copy private original definitions or detailed differences into public issues."""
        return await deps.helper.post("/managed/history", {"model_name": model_name, "limit": limit, "offset": offset})

    @mcp.tool(name="anki_restore_managed_model", annotations=MANAGED_RESTORE)
    async def anki_restore_managed_model(
        model_name: Annotated[str, Field(strict=True, min_length=1)] = DEFAULT_MODEL,
        request_id: Annotated[str, Field(strict=True, pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{7,127}$")] | None = None,
        preview_token: Annotated[str, Field(strict=True, min_length=1)] | None = None,
        confirm: Annotated[bool, Field(strict=True)] = False,
    ) -> dict[str, Any]:
        """Preview restoring the host-selected, currently eligible applied-and-verified baseline, then apply
        only after showing that concrete preview and obtaining the user's confirmation. Repeat its original
        request_id/preview_token with confirm=true. This is dialogue approval submitted by the LLM, not an
        independent human authentication UI. Never invent approval or use this to apply a new Git version.
        Only permitted HTML/CSS and registered JS/CSS can be restored; structure/generation changes or
        uncertain card/note/schedule/review preservation stop remote restore. No raw bytes, digest, arbitrary
        file, schema action or root approval can be supplied. Expired/changed previews require a new preview.
        State applied means verified local restoration; sync.state=synced separately means verified AnkiWeb
        collection/media delivery, not reception or UI verification on every client. Partial/unknown must not
        be replayed. Read anki_managed_restore_status; a retry with the same request_id resumes only confirmed
        delivery. Normal sync runs before prepare/apply and after restoration. Full Upload needs fresh per-device
        sync/pause confirmation and explicit operation-specific operator approval; never auto-select Download
        or reuse old approval. New deployment and adopting app changes into Git remain operator workflows."""
        return await managed.restore(model_name=model_name, request_id=request_id,
                                     preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_managed_restore_status", annotations=READ_ONLY)
    async def anki_managed_restore_status(
        request_id: Annotated[str, Field(strict=True, pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{7,127}$")],
    ) -> dict[str, Any]:
        """Read a managed restore's durable receipt without retrying anything. Inspect component states,
        verified local restoration and separate AnkiWeb delivery. Unknown/partial requires diagnosis, not a
        new request or blind reapply. Client/device reception is not established by host delivery."""
        return await managed.status(request_id)

    # The pinned FastMCP SDK defaults to ignoring unknown top-level arguments.
    # Reject them for this narrow capability, including misleading raw payload,
    # target digest or root-approval fields, in both validation and public schema.
    for name in ("anki_managed_model_check", "anki_managed_model_history",
                 "anki_restore_managed_model", "anki_managed_restore_status"):
        tool = mcp._tool_manager.get_tool(name)
        tool.fn_metadata.arg_model.model_config["extra"] = "forbid"
        tool.fn_metadata.arg_model.model_rebuild(force=True)
        tool.parameters = tool.fn_metadata.arg_model.model_json_schema(by_alias=True)

    @mcp.tool(name="anki_find_notes", annotations=READ_ONLY)
    async def anki_find_notes(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_field_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search notes with Anki search syntax passed through verbatim (e.g. 'deck:"CS 재활" tag:mcp::added',
        'added:7', 'is:due', 'front:*css*'). Paginated; field values are truncated to max_field_chars
        (0 = no truncation). The user's review queue is starred notes: query 'tag:marked'. Collect all pages
        when reviewing the entire queue. Use anki_note_info for full fields and the review cleanup choices;
        never automatically unmark completed items. Check freshness for the host's
        recorded sync boundary; phone edits may still be absent even after a successful host sync."""
        freshness = read_freshness(deps.sync_status_file)
        ids: list[int] = await anki.invoke("findNotes", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"query": query, "page": meta, "notes": [note_view(n, max_field_chars) for n in notes], "freshness": freshness}

    @mcp.tool(name="anki_note_info", annotations=READ_ONLY)
    async def anki_note_info(note_ids: list[int], max_field_chars: int = 0) -> dict[str, Any]:
        """Full note details for the given note ids (fields untruncated by default).
        Before reviewing a note with a 검토 메모 field, read its complete memo here, including all paragraphs.
        The memo is shared by sibling cards. Do not clear or rewrite it merely because a review mark is removed.
        After completing the requested review work and necessary readback, report results and ask once for
        the completed notes: clear both star and memo, clear only the star, or keep both. Merely listing or
        reading notes is not completion. Keep both unchanged while awaiting the choice; do not ask again
        if the user already explicitly authorized that cleanup choice for those notes.
        Exclude notes with unfinished work or unresolved memo questions, including those about sibling cards.
        Before clearing, reread the current full memo; if it changed since the choice was offered, preserve it
        and reconfirm. For either field-update tool, clear a memo only with expected_fields containing its
        exact last-read full value (including HTML and newlines); include it for every note in a bulk edit.
        On expected-field-value-mismatch, keep memos and stars, reread and reconfirm; never omit the guard
        or substitute newly read values just to retry. Clear only the approved notes' existing 검토 메모 field
        to an empty string and/or their marked tag, according to the choice. Preserve other fields, tags,
        flags and scheduling. For both,
        clear the memo and verify it first, then remove marked. On partial/unknown results, inspect and
        report the remaining state instead of claiming cleanup complete or retrying with a new request_id.
        Check freshness for the host's recorded sync boundary; phone edits may still be absent even after
        a successful host sync."""
        freshness = read_freshness(deps.sync_status_file)
        chunk, meta = page(note_ids, deps.page_max, 0, deps.page_max)
        notes = await anki.invoke("notesInfo", notes=chunk) if chunk else []
        return {"page": meta, "notes": [note_view(n, max_field_chars) for n in notes], "freshness": freshness}

    @mcp.tool(name="anki_find_cards", annotations=READ_ONLY)
    async def anki_find_cards(
        query: str,
        limit: int = 20,
        offset: int = 0,
        max_chars: int = deps.field_chars,
    ) -> dict[str, Any]:
        """Search cards (scheduling view: queue/type/due/interval/ease/reps/lapses) with Anki search syntax.
        Use a supplied cid:<ID> as the exact query. The returned noteId identifies its parent note;
        use anki_note_info for full note fields.
        Search flags with flag:1 through flag:7 (flag:0 means no flag). The response's flag is 0–7,
        or null if unavailable. Rendered question/answer are truncated to max_chars.
        Check freshness for the host's recorded sync boundary; phone edits may still be absent even after
        a successful host sync."""
        freshness = read_freshness(deps.sync_status_file)
        ids: list[int] = await anki.invoke("findCards", query=query)
        chunk, meta = page(ids, limit, offset, deps.page_max)
        cards = await anki.invoke("cardsInfo", cards=chunk) if chunk else []
        return {"query": query, "page": meta, "cards": [card_view(c, max_chars) for c in cards], "freshness": freshness}

    @mcp.tool(name="anki_card_reviews", annotations=READ_ONLY)
    async def anki_card_reviews(card_ids: list[int]) -> dict[str, Any]:
        """Review history (revlog) keyed by card id. Each entry: {id: review time (epoch ms), usn, ease: button 1-4,
        ivl: new interval (days; negative = seconds), lastIvl, factor: ease factor (permille), time: ms spent,
        type: 0 learn / 1 review / 2 relearn / 3 filtered / 4 manual}."""
        freshness = read_freshness(deps.sync_status_file)
        chunk, meta = page(card_ids, deps.page_max, 0, deps.page_max)
        # AnkiConnect는 revlog.cid를 정수로 비교한다 — 문자열 id를 보내면 빈 결과가 온다
        reviews = await anki.invoke("getReviewsOfCards", cards=chunk) if chunk else {}
        return {"page": meta, "reviews": reviews, "freshness": freshness}

    @mcp.tool(name="anki_tags", annotations=READ_ONLY)
    async def anki_tags() -> dict[str, Any]:
        """All tags in the collection."""
        freshness = read_freshness(deps.sync_status_file)
        return {"tags": await anki.invoke("getTags"), "freshness": freshness}

    @mcp.tool(name="anki_add_notes", annotations=ADDITIVE, description=(
        "Add notes. Every note gets the 'mcp::added' tag so MCP-created cards stay identifiable. "
        "Duplicates (same first field in the deck) are rejected unless allow_duplicate. Returns an operation receipt "
        "with per-note outcomes in result.results (null noteId = unconfirmed/failed, see errors). "
        "Inspect the separate link_check for newly missing stored Note Linker references; never repeat a write to rerun it. "
        "Managed-type drift or unavailable checks block creation before any write; split mixed-type batches. "
        "Use anki_managed_model_check to inspect the applied baseline and available choices. "
        "Normal sync runs before and after writes. Reuse request_id "
        "for every retry. More than 20 affected notes/cards returns a preview requiring user confirmation. "
        "In 검토 메모, use plain-language cloze examples such as 'c1: answer', never literal cloze markup: "
        "it can generate cards even in a hidden memo field.\n\n"
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
        "Returns an operation receipt; use anki_note_info for readback. Reuse request_id for retries. "
        "Inspect link_check for newly missing stored Note Linker references; diagnostic failure does not undo the write. "
        "Managed-type drift or unavailable checks block field writes; inspect anki_managed_model_check. "
        "A verified media-free restore point is created before every field edit, including one note. "
        "For read-modify-write changes, pass expected_fields with exact old values for the same keys. "
        "검토 메모 can contain multiple paragraphs. Describe cloze examples as 'c1: answer', never literal "
        "cloze markup: it can generate cards even in a hidden memo field. Do not silently rewrite an existing memo.\n"
        "Clearing 검토 메모 requires the user's explicit cleanup choice and expected_fields with the exact "
        "last-read full memo. On expected-field-value-mismatch, preserve the memo and star, reread and "
        "reconfirm; do not drop the guard or automatically replace its value. Follow anki_note_info.\n\n"
        + AUTHORING_GUIDANCE
    ))
    async def anki_update_note_fields(note_id: int, fields: dict[str, str], expected_fields: dict[str, str] | None = None,
                                     request_id: str | None = None,
                                     preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        params = {"note_id": note_id, "fields": fields}
        if expected_fields is not None:
            params["expected_fields"] = expected_fields
        return await operations.run("update_fields", params,
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_update_notes_fields", annotations=UPDATE, description=(
        "Replace selected fields on multiple existing notes in one operation. Each note_id must occur\n"
        "once; read all original fields first with anki_note_info. Other fields and existing cards'\n"
        "scheduling/history remain unchanged; changed templates/cloze fields can generate new cards.\n"
        "Creates one verified media-free restore point and uses one pre/post sync pair and notification.\n"
        "More than 20 affected notes/cards, including anticipated new cards, requires preview/confirmation.\n"
        "For migrations, include expected_fields with each note's exact old values for the replaced keys;\n"
        "a mismatch after pre-sync rejects the whole operation before backup or writes.\n"
        "If a managed type has drift or an unavailable check, the entire mixed-type batch is rejected before writes; "
        "split the batch and inspect anki_managed_model_check.\n"
        "Inspect the separate link_check for newly missing stored Note Linker references, including partial writes.\n"
        "Results list each note as applied, unknown or not-attempted. An uncertain write stops the batch;\n"
        "no automatic rollback. Inspect partial/unknown receipts instead of repeating with a new request_id.\n"
        "Reuse the same request_id for retries. 검토 메모 supports multiple paragraphs: describe cloze\n"
        "examples as 'c1: answer', never literal cloze markup, and do not silently rewrite an existing memo.\n"
        "Clearing 검토 메모 requires the user's explicit cleanup choice and expected_fields with each note's "
        "exact last-read full memo. On expected-field-value-mismatch, preserve all memos and stars, reread "
        "and reconfirm; do not drop the guard or automatically replace its value. Follow anki_note_info.\n\n"
        + AUTHORING_GUIDANCE
    ))
    async def anki_update_notes_fields(
        notes: Annotated[list[NoteFieldUpdate], Field(min_length=1)],
        request_id: str | None = None, preview_token: str | None = None, confirm: bool = False,
    ) -> dict[str, Any]:
        payload = [n.model_dump(exclude_none=True) for n in notes]
        return await operations.run("update_fields_bulk", {"notes": payload},
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
        """Remove tags from notes (each tag must not contain spaces).
        For review cleanup, follow anki_note_info: ask once whether to clear both star and memo, only the star,
        or neither, unless that choice was already explicitly authorized. Without a choice, change neither.
        Remove only 'marked' from the approved, fully completed notes; preserve all other tags."""
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
        """Preview deletion of notes and ALL their cards. Existing review history is retained, including in
        today_reviews. affected_review_rows is the pre-deletion scope, not a deleted-row count;
        retained_review_rows in the result is measured after deletion. Always show the preview and get user
        confirmation, then repeat the same request_id/token with confirm=true. Requires a verified restore point.
        Inspect link_check for remaining notes whose stored Note Linker references became missing; do not automatically repair them."""
        return await operations.run("delete_notes", {"note_ids": note_ids},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_set_card_flags", annotations=UPDATE)
    async def anki_set_card_flags(
        card_ids: list[Annotated[int, Field(strict=True, gt=0)]],
        flag: Annotated[int, Field(strict=True, ge=0, le=7)],
        request_id: str | None = None, preview_token: str | None = None, confirm: bool = False,
    ) -> dict[str, Any]:
        """Set/change a card's colored flag (1–7), or clear it (0). Only the listed cards change;
        siblings, note fields, scheduling and review history are preserved. A card has one flag at a time.
        More than 20 cards requires preview/confirmation and a restore point. Reuse request_id for retries;
        inspect the operation receipt after a lost response. Read back with anki_find_cards using cid:<ID>."""
        return await operations.run("set_card_flags", {"card_ids": card_ids, "flag": flag},
                                    request_id=request_id, preview_token=preview_token, confirm=confirm)

    @mcp.tool(name="anki_delete_decks", annotations=DESTRUCTIVE)
    async def anki_delete_decks(deck_names: list[str], request_id: str | None = None,
                                preview_token: str | None = None, confirm: bool = False) -> dict[str, Any]:
        """Preview deleting decks including subdecks and their affected cards. Existing review history is
        retained, including in today_reviews. affected_review_rows is the pre-deletion scope, not a
        deleted-row count; retained_review_rows in the result is measured after deletion. Filtered/Default
        deck behavior is explained in the preview. Always requires user confirmation and a verified restore point.
        Inspect the separate link_check for remaining notes whose stored Note Linker references became missing."""
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
        a no-op; different existing content is refused. No file paths, URLs, overwriting or deletion.
        For images on the user's device use anki_upload_image; use base64 only for small files you created
        yourself or when the app cannot show the upload box."""
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

    @mcp.tool(name="anki_upload_image", title="Upload image from device", annotations=UPLOAD_BOX,
              meta={"ui": {"resourceUri": WIDGET_URI}}, description=UPLOAD_IMAGE_DESCRIPTION,
              structured_output=False)
    async def anki_upload_image() -> CallToolResult:
        return CallToolResult(content=[TextContent(type="text", text=UPLOAD_RESULT_TEXT)], structuredContent={
            "maxBytes": deps.media_max_bytes, "formats": list(FORMATS), "resizeLongEdge": RESIZE_LONG_EDGE})

    @mcp.tool(name=TICKET_TOOL, title="Upload ticket (upload box only)", annotations=UPLOAD_BOX,
              meta={"ui": {"visibility": ["app"]}}, structured_output=False,
              description="Used only by the upload box to get a one-time upload ticket (valid for 2 minutes).")
    async def anki_upload_ticket() -> CallToolResult:
        ticket = deps.uploads.issue()
        return CallToolResult(
            content=[TextContent(type="text", text="One-time upload ticket issued for the upload box.")],
            structuredContent={"ticket": ticket, "expiresInSeconds": int(deps.uploads.ttl)})

    @mcp.resource(WIDGET_URI, name="anki-upload-image", title="Anki image upload", mime_type=WIDGET_MIME,
                  description="Upload box that stores one image from the user's device in Anki media.",
                  meta={"ui": {"csp": {"connectDomains": [origin(deps.public_url)]}, "prefersBorder": True}})
    def anki_upload_page() -> str:
        return widget_html(deps.public_url + UPLOAD_PATH, deps.media_max_bytes)

    @mcp.tool(name="anki_media", annotations=READ_ONLY)
    async def anki_media(filename: str | None = None, contains: str = "", limit: int = 20, offset: int = 0) -> dict[str, Any]:
        """List media by plain substring with pagination, or retrieve one safe filename as base64 (max 5 MiB)."""
        freshness = read_freshness(deps.sync_status_file)
        result = await deps.helper.post("/media", {"filename": filename, "contains": contains, "limit": limit, "offset": offset})
        return {**result, "freshness": freshness}

    @mcp.tool(name="anki_deck_options", annotations=READ_ONLY)
    async def anki_deck_options(deck_name: str) -> dict[str, Any]:
        """Read the current preset, editable options and every deck sharing that preset."""
        freshness = read_freshness(deps.sync_status_file)
        result = await deps.helper.post("/deck-options", {"deck_name": deck_name})
        return {**result, "freshness": freshness}

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
        freshness = read_freshness(deps.sync_status_file)
        result = await deps.helper.post("/model-info", {"model_name": model_name})
        return {**result, "freshness": freshness}

    @mcp.tool(name="anki_prepare_model_change", annotations=DESTRUCTIVE)
    async def anki_prepare_model_change(
        action: Literal["model_field_add", "model_field_remove", "model_field_rename", "model_field_reposition",
                        "model_template_add", "model_template_remove", "model_template_update"],
        params: dict[str, Any], request_id: str | None = None,
    ) -> dict[str, Any]:
        """Prepare (never apply) a note-type change requiring root approval and possibly full Upload. params:
        model_name plus field_name (add/remove), field_name+new_name (rename), field_name+index (reposition),
        template_name+front+back (add/update), or template_name (remove). Field add accepts optional index.
        For template update, expected_model_id+expected_front+expected_back may bind the change to the exact
        pre-sync template; provide all three together for generated plans. Show the preview; the root
        anki-host-approve command verifies backup/counts and executes once."""
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
